import Foundation
import XCTest
import SnoreCore
@testable import SnoreLog

final class DeferredAnalysisTests: XCTestCase {
    private final class Counter: SnoreClassifier {
        var seconds: [Int] = []
        func classify(samples: [Float], second: Int) throws -> FrameConfidence {
            seconds.append(second)
            return .init(snoring: second % 4 == 2 ? 0.9 : 0, breathing: second % 7 == 1 ? 0.8 : 0)
        }
    }
    private func store() -> NightStore { NightStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)) }
    private func audio(_ count: Int, offset: Int) -> [Float] {
        (0..<count).map { sample in (sample + offset) / 16_000 % 4 == 2 ? 0.03 : 0.001 }
    }
    private func finish(_ pending: NightRecord, store: NightStore, classifier: Counter) throws -> NightRecord {
        let worker = try DeferredNightAnalysis(record: pending, store: store, classifier: classifier)
        var result = pending
        while result.pendingAnalysis == true { result = try worker.step() }
        return result
    }
    func testCheckpointResumeEqualsOnePassAndOriginalPCMWithFractionalEvents() throws {
        let store = store(); defer { try? FileManager.default.removeItem(at: store.root) }
        let night = NightRecord(id: "night", startDate: Date(timeIntervalSince1970: 0), delaySec: 0.5)
        let pipeline = try RecordingPipeline(record: night, store: store)
        var config = AnalyzerConfig(); config.startDelaySec = night.delaySec
        let reference = NightAnalyzer(config: config, startDate: night.startDate, classifier: Counter())
        let first = audio(119 * 16_000 + 4_000, offset: 0)
        let second = audio(121 * 16_000 + 12_000, offset: first.count)
        let third = audio(17 * 16_000 + 8_000, offset: first.count + second.count)
        try pipeline.append(first); try reference.append(first)
        try pipeline.markGap(seconds: 2.5); reference.markGap(seconds: 2.5)
        try pipeline.append(second); try reference.append(second)
        pipeline.markAlarm(); reference.markAlarm()
        try pipeline.append(third); try reference.append(third)
        let pending = try pipeline.finish()
        let uninterruptedStore = self.store()
        defer { try? FileManager.default.removeItem(at: uninterruptedStore.root) }
        try FileManager.default.copyItem(at: store.root, to: uninterruptedStore.root)
        let uninterrupted = try finish(pending, store: uninterruptedStore, classifier: Counter())
        let classifier = Counter()
        var worker: DeferredNightAnalysis? = try DeferredNightAnalysis(record: pending, store: store, classifier: classifier)
        let partial = try worker!.step()
        XCTAssertGreaterThan(partial.analysisProgress ?? 0, 0)
        XCTAssertLessThan(partial.analysisProgress ?? 1, 1)
        XCTAssertEqual(partial.pendingAnalysis, true)
        let completedSeconds = classifier.seconds
        worker = nil
        let saved = try XCTUnwrap(store.loadAll().first)
        XCTAssertEqual(saved.analysisProgress, partial.analysisProgress)
        let result = try finish(saved, store: store, classifier: classifier)
        XCTAssertEqual(Array(classifier.seconds.prefix(completedSeconds.count)), completedSeconds)
        XCTAssertEqual(Set(classifier.seconds).count, classifier.seconds.count, "Completed frames must never be reclassified after restart")
        XCTAssertEqual(result.report, reference.finish())
        XCTAssertEqual(result.report, uninterrupted.report)
        XCTAssertEqual(result.pendingAnalysis, false)
        XCTAssertEqual(result.analysisProgress, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory(night.id).appendingPathComponent("tmp").path))
        XCTAssertLessThanOrEqual(result.clips.count, 12)
        XCTAssertEqual(result.report?.retained.map(\.segmentNumbers), result.clips.map(\.segmentNumbers))
    }
    func testSameSegmentFractionalGapDoesNotTruncateEarlierAudio() throws {
        let store = store(); defer { try? FileManager.default.removeItem(at: store.root) }
        let night = NightRecord(id: "gap", startDate: Date(timeIntervalSince1970: 0))
        let pipeline = try RecordingPipeline(record: night, store: store)
        let first = audio(10 * 16_000 + 8_000, offset: 0)
        let second = audio(11 * 16_000 + 4_000, offset: first.count)
        let reference = NightAnalyzer(startDate: night.startDate, classifier: Counter())
        try pipeline.append(first); try reference.append(first)
        try pipeline.markGap(seconds: 1.25); reference.markGap(seconds: 1.25)
        try pipeline.append(second); try reference.append(second)
        let result = try finish(pipeline.finish(), store: store, classifier: Counter())
        XCTAssertEqual(result.report, reference.finish())
        XCTAssertEqual(result.report?.recordedSec, 23)
        XCTAssertEqual(result.report?.gapSec, 1.25)
    }
    func testBackgroundAutoEndOnlyPersistsPendingAndNeverClassifies() throws {
        let store = store(); defer { try? FileManager.default.removeItem(at: store.root) }
        let start = Date(timeIntervalSince1970: 0)
        let classifier = Counter()
        let pipeline = try RecordingPipeline(record: .init(id: "background", startDate: start, alarmDate: start.addingTimeInterval(3600)), store: store, classifier: classifier)
        pipeline.recordLifecycle(state: "background", at: start)
        try pipeline.append(audio(32_000, offset: 0))
        XCTAssertTrue(SessionTiming.shouldStop(start: start, alarm: start.addingTimeInterval(3600), now: start.addingTimeInterval(10_800)))
        let pending = try pipeline.finish()
        XCTAssertTrue(classifier.seconds.isEmpty)
        XCTAssertNil(pending.report)
        XCTAssertEqual(pending.pendingAnalysis, true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.directory(pending.id).appendingPathComponent("tmp/seg-0.m4a").path))
    }
    func testCrashRecoveryKeepsSourcesAndProducesAnalysis() throws {
        let store = store(); defer { try? FileManager.default.removeItem(at: store.root) }
        let pipeline = try RecordingPipeline(record: .init(id: "crash", startDate: Date(timeIntervalSince1970: 0)), store: store)
        try pipeline.append(audio(120 * 16_000, offset: 0))
        let recovered = try XCTUnwrap(store.recoverIncomplete().first)
        XCTAssertEqual(recovered.pendingAnalysis, true)
        XCTAssertTrue(recovered.unexpectedStop)
        XCTAssertEqual(recovered.unexpectedStopReason, "App 在夜里被关闭了（可能被系统回收或被手动划掉）")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.directory(recovered.id).appendingPathComponent("tmp/seg-0.m4a").path))
        let result = try finish(recovered, store: store, classifier: Counter())
        XCTAssertEqual(result.report?.recordedSec, 120)
        XCTAssertTrue(result.unexpectedStop)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory(recovered.id).appendingPathComponent("tmp").path))
    }
    func testErrorFirstAndLastTimesSurvivePersistence() throws {
        let store = store(); defer { try? FileManager.default.removeItem(at: store.root) }
        let pipeline = try RecordingPipeline(record: .init(id: "diagnostics", startDate: Date()), store: store)
        let before = Date()
        pipeline.recordError("background retry failed")
        let first = try XCTUnwrap(pipeline.record.diagnostics.errorTimes?["background retry failed"]?.first)
        pipeline.recordError("background retry failed")
        let pending = try pipeline.finish()
        let saved = try XCTUnwrap(store.loadAll().first)
        let times = try XCTUnwrap(saved.diagnostics.errorTimes?["background retry failed"])
        XCTAssertGreaterThanOrEqual(first, before)
        XCTAssertEqual(times.first, first)
        XCTAssertGreaterThanOrEqual(times.last, times.first)
        XCTAssertEqual(saved.diagnostics.errorCounts["background retry failed"], 2)
        XCTAssertEqual(pending.pendingAnalysis, true)
    }

    func testCrashRecoversReadableTailAfterLastCheckpoint() throws {
        let store = store(); defer { try? FileManager.default.removeItem(at: store.root) }
        var pipeline: RecordingPipeline? = try RecordingPipeline(record: .init(id: "tail", startDate: Date(timeIntervalSince1970: 0)), store: store)
        try pipeline!.append(audio(15 * 16_000, offset: 0))
        // Close the AAC writer without finish/checkpoint, like a recoverable process exit.
        pipeline = nil
        let recovered = try XCTUnwrap(store.recoverIncomplete().first)
        XCTAssertEqual(recovered.snapshotDate?.timeIntervalSince1970, 15)
        let result = try finish(recovered, store: store, classifier: Counter())
        XCTAssertEqual(result.report?.recordedSec, 15)
        XCTAssertEqual(result.report?.envelope.count, 15)
        XCTAssertTrue(result.unexpectedStop)
        XCTAssertEqual(result.pendingAnalysis, false)
    }
}
