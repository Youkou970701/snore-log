import Foundation
import XCTest
import SnoreCore
@testable import SnoreLog

final class AppTests: XCTestCase {
    private func store() -> NightStore { NightStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)) }
    private func record(_ id: String = UUID().uuidString) -> NightRecord {
        NightRecord(id: id, startDate: Date(timeIntervalSince1970: 0))
    }
    private func silentReport() -> NightReport {
        NightAnalyzer(startDate: Date(), classifier: SilentClassifier()).finish()
    }
    func testInterruptionAndEndLimits() {
        var clock = InterruptionClock()
        let zero = Date(timeIntervalSince1970: 0)
        XCTAssertNil(clock.end(at: zero))
        clock.begin(at: zero); clock.begin(at: zero.addingTimeInterval(20))
        XCTAssertEqual(clock.end(at: zero.addingTimeInterval(60)), 60)
        XCTAssertNil(clock.end(at: zero))
        XCTAssertFalse(SessionTiming.shouldStop(start: zero, alarm: nil, now: zero.addingTimeInterval(14 * 3600 - 1)))
        XCTAssertTrue(SessionTiming.shouldStop(start: zero, alarm: nil, now: zero.addingTimeInterval(14 * 3600)))
        let alarm = zero.addingTimeInterval(3600)
        XCTAssertFalse(SessionTiming.shouldStop(start: zero, alarm: alarm, now: alarm.addingTimeInterval(7199)))
        XCTAssertTrue(SessionTiming.shouldStop(start: zero, alarm: alarm, now: alarm.addingTimeInterval(7200)))
    }
    func testCrashRecoveryUsesSnapshotAndPreservesOwnedClip() throws {
        let store = store(); defer { try? FileManager.default.removeItem(at: store.root) }
        var night = record(); night.report = silentReport(); night.snapshotDate = night.startDate.addingTimeInterval(240)
        night.clips = [.init(id: "0", segmentNumbers: [0], reason: .loud, fileName: "saved.m4a")]
        let clips = store.directory(night.id).appendingPathComponent("clips")
        let tmp = store.directory(night.id).appendingPathComponent("tmp")
        try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        for name in ["saved.m4a", "orphan.m4a"] { try Data([0]).write(to: clips.appendingPathComponent(name)) }
        try store.save(night)
        let recovered = try store.recoverIncomplete()
        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(recovered[0].endDate, night.snapshotDate)
        XCTAssertTrue(recovered[0].unexpectedStop)
        XCTAssertEqual(recovered[0].report, night.report)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: clips.path), ["saved.m4a"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.path))
        XCTAssertTrue(try store.recoverIncomplete().isEmpty)
    }
    func testCleanupOnlyRemovesExpiredUnfavoritedAudio() throws {
        let store = store(); defer { try? FileManager.default.removeItem(at: store.root) }
        var night = record(); night.endDate = night.startDate
        night.clips = [.init(id: "0", segmentNumbers: [0], reason: .loud, favorite: true, fileName: "keep.m4a"), .init(id: "1", segmentNumbers: [1], reason: .pause, fileName: "remove.m4a")]
        let dir = store.directory(night.id).appendingPathComponent("clips")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for clip in night.clips { try Data([0]).write(to: dir.appendingPathComponent(clip.fileName)) }
        try store.save(night)
        try store.cleanup(retentionDays: 14, now: night.startDate.addingTimeInterval(15 * 86400))
        let loaded = store.loadAll()
        XCTAssertEqual(loaded.count, 1); XCTAssertEqual(loaded[0].clips.map(\.fileName), ["keep.m4a"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["keep.m4a"])
    }
    func testFactorComparisonMeansAndSampleSize() {
        var records: [NightRecord] = []
        for i in 0..<6 {
            var night = record(String(i)); night.report = silentReport()
            if i < 3 { night.factors = ["喝酒"] }
            night.report?.snoreRatio = 0.01 // R4 must not drive the comparison.
            night.report?.analyzedSec = 100
            night.report?.snoreEpisodeSec = i < 3 ? 20 : 10
            night.report?.pausesPerHour = i < 3 ? 4 : 2
            night.report?.snoreP95Db = i < 3 ? 60 : 50
            records.append(night)
        }
        let enough = FactorComparison.compare(records: records, factor: "喝酒")
        XCTAssertEqual(enough.hasCount, 3); XCTAssertEqual(enough.withoutCount, 3)
        XCTAssertFalse(enough.insufficient)
        XCTAssertEqual(enough.hasRatio!, 0.2, accuracy: 1e-10)
        XCTAssertEqual(enough.withoutRatio!, 0.1, accuracy: 1e-10)
        XCTAssertEqual(enough.hasPauses, 4); XCTAssertEqual(enough.withoutPauses, 2)
        XCTAssertEqual(enough.hasP95, 60); XCTAssertEqual(enough.withoutP95, 50)
        XCTAssertTrue(FactorComparison.compare(records: Array(records.dropLast()), factor: "喝酒").insufficient)
    }
    func testDeferredStorageKeepsWholeNightThenArchivesExactFinalCandidates() throws {
        let store = store(); defer { try? FileManager.default.removeItem(at: store.root) }
        let pipeline = try RecordingPipeline(record: record(), store: store, classifier: PulseClassifier())
        let quiet = [Float](repeating: 0.001, count: 16_000)
        for second in 0..<(20 * 120) {
            let isPulse = second % 120 == 10
            let amplitude = Float(pow(10, (Double(55 + second / 120) - 90) / 20))
            try pipeline.append(isPulse ? [Float](repeating: amplitude, count: 16_000) : quiet)

        }
        let pending = try pipeline.finish()
        let worker = try DeferredNightAnalysis(record: pending, store: store, classifier: PulseClassifier())
        var result = pending
        while result.pendingAnalysis == true { result = try worker.step() }
        XCTAssertGreaterThanOrEqual(pipeline.peakFileCount, 20)
        XCTAssertEqual(result.clips.count, result.report?.retained.count)
        XCTAssertEqual(Set(result.clips.flatMap(\.segmentNumbers)), Set(result.report!.retained.flatMap(\.segmentNumbers)))
        XCTAssertEqual(result.clips.count, 12)
        let dir = store.directory(result.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("tmp").path))
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("clips").path)), Set(result.clips.map(\.fileName)))
        XCTAssertFalse(result.clips.flatMap(\.segmentNumbers).contains(0))
    }
    func testSourceAndResourceCopyGuard() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let codes: [[UInt32]] = [[21628,21560,26242,20572,32508,21512,24449],[65,72,73],[37325,24230],[20013,24230],[36731,24230],[30830,35786],[35786,26029,20026],[27835,30103],[27490,40766,20135,21697,25512,33616]]
        let banned = codes.map { String(String.UnicodeScalarView($0.compactMap(UnicodeScalar.init))) }
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]))
        var checked = 0
        for case let file as URL in enumerator {
            if file.pathComponents.contains("DerivedData") { enumerator.skipDescendants(); continue }
            guard ["swift", "strings", "stringsdict", "xcstrings"].contains(file.pathExtension) else { continue }
            let text = try String(contentsOf: file, encoding: .utf8)
            for term in banned { XCTAssertFalse(text.contains(term), "Prohibited copy in \(file.lastPathComponent)") }
            checked += 1
        }
        XCTAssertGreaterThan(checked, 0)
    }
    func testProvisioningEnvelopeExpirationAndAlarmGate() throws {
        let expiration = Date(timeIntervalSince1970: 1_800_000_000)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["ExpirationDate": expiration], format: .xml, options: 0)
        var envelope = Data([0x30, 0x82, 0xff, 0x00]); envelope.append(plist); envelope.append(Data([0xff, 0x00]))
        XCTAssertEqual(Provisioning.expirationDate(data: envelope), expiration)
        XCTAssertNil(Provisioning.expirationDate(data: Data([0, 1, 2])))
        XCTAssertTrue(Provisioning.expiresBeforeAlarm(expiration: expiration, alarm: expiration.addingTimeInterval(1)))
        XCTAssertFalse(Provisioning.expiresBeforeAlarm(expiration: expiration, alarm: expiration.addingTimeInterval(-1)))
        XCTAssertFalse(Provisioning.expiresBeforeAlarm(expiration: nil, alarm: expiration))
    }
    func testBoundaryEventArchivesAdjacentSegmentsAsOneClip() throws {
        let store = store(); defer { try? FileManager.default.removeItem(at: store.root) }
        let classifier = BoundaryClassifier()
        let pipeline = try RecordingPipeline(record: record(), store: store, classifier: classifier)
        for second in 0..<260 {
            let snore = try classifier.classify(samples: [], second: second).snoring > 0.5
            let amplitude: Float = second == 130 ? 0.15 : snore ? 0.03 : 0.001
            try pipeline.append([Float](repeating: amplitude, count: 16_000))
        }
        let pending = try pipeline.finish()
        let worker = try DeferredNightAnalysis(record: pending, store: store, classifier: classifier)
        var result = pending
        while result.pendingAnalysis == true { result = try worker.step() }
        XCTAssertEqual(result.report?.pauses.count, 1)
        XCTAssertTrue(result.clips.contains { $0.segmentNumbers == [0, 1] && $0.reason == .pause })
        XCTAssertEqual(result.clips.count, result.report?.retained.count)
        XCTAssertLessThanOrEqual(pipeline.peakFileCount, 15)
    }
    func testHealthNoticeExactCopy() {
        XCTAssertEqual(AppCopy.healthNotice, "这晚检测到较多疑似呼吸停顿。手机录音可能误判，如果连续多晚都这样，或白天特别困、早上头痛，建议去医院睡眠科做睡眠监测。")
    }
}
private struct SilentClassifier: SnoreClassifier {
    func classify(samples: [Float], second: Int) throws -> FrameConfidence { .init(snoring: 0) }
}

private struct PulseClassifier: SnoreClassifier {
    func classify(samples: [Float], second: Int) throws -> FrameConfidence { .init(snoring: second % 120 == 10 ? 0.9 : 0) }
}

private struct BoundaryClassifier: SnoreClassifier {
    func classify(samples: [Float], second: Int) throws -> FrameConfidence {
        let snore = (10...114).contains(second) && (second - 10) % 4 == 0 || (131...251).contains(second) && (second - 131) % 4 == 0
        return .init(snoring: snore ? 0.9 : 0)
    }
}
