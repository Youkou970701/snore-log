import Foundation
import XCTest
import SnoreCore
@testable import SnoreLog

final class PipelineResilienceTests: XCTestCase {
    private final class CountingClassifier: SnoreClassifier {
        var calls = 0
        func classify(samples: [Float], second: Int) throws -> FrameConfidence { calls += 1; return .init(snoring: 0) }
    }
    func testStorageFailureRecordsDiagnosticsWithoutRunningClassifier() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NightStore(root: root)
        let classifier = CountingClassifier()
        let pipeline = try RecordingPipeline(record: .init(id: "night", startDate: Date()), store: store, classifier: classifier, strictFileErrors: false)
        let tmp = store.directory("night").appendingPathComponent("tmp")
        try FileManager.default.removeItem(at: tmp)
        try Data([1]).write(to: tmp)
        try pipeline.append([Float](repeating: 0.001, count: 3 * 16_000))
        XCTAssertEqual(pipeline.recordedSec, 3)
        XCTAssertEqual(classifier.calls, 0)
        XCTAssertFalse(pipeline.record.diagnostics.clipErrors.isEmpty)
        XCTAssertNotNil(pipeline.latestDb)
        try FileManager.default.removeItem(at: tmp)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try pipeline.append([Float](repeating: 0.001, count: 16_000))
        XCTAssertEqual(pipeline.recordedSec, 4)
        XCTAssertEqual(classifier.calls, 0)
    }
    func testMissingSourceFailsAnalysisAndPreservesPendingNight() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NightStore(root: root)
        let pipeline = try RecordingPipeline(record: .init(id: "night", startDate: Date()), store: store)
        try pipeline.append([Float](repeating: 0.001, count: 122 * 16_000))
        let pending = try pipeline.finish()
        try FileManager.default.removeItem(at: store.directory("night").appendingPathComponent("tmp/seg-0.m4a"))
        let worker = try DeferredNightAnalysis(record: pending, store: store, classifier: CountingClassifier())
        XCTAssertThrowsError(try worker.step())
        XCTAssertEqual(store.loadAll().first?.pendingAnalysis, true)
        XCTAssertNil(store.loadAll().first?.report)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.directory("night").appendingPathComponent("tmp/seg-1.m4a").path))
    }
    func testWholeNightSourcesAreNeverTrimmedByOldFileBudget() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NightStore(root: root)
        let pipeline = try RecordingPipeline(record: .init(id: "night", startDate: Date()), store: store)
        for _ in 0..<20 { try pipeline.append([Float](repeating: 0.001, count: 120 * 16_000)) }
        _ = try pipeline.finish()
        let tmp = store.directory("night").appendingPathComponent("tmp")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: tmp.path).count, 20)
        XCTAssertEqual(pipeline.record.diagnostics.classifierAverageMs, 0)
        XCTAssertTrue(pipeline.record.clips.isEmpty)
    }
    func testUnexpectedStopPersistsPendingAudioAndChineseReasonWithDiagnostics() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NightStore(root: root)
        let start = Date(timeIntervalSince1970: 0)
        let pipeline = try RecordingPipeline(record: .init(id: "night", startDate: start), store: store)
        try pipeline.append([Float](repeating: 0.001, count: 32_000))
        pipeline.recordDrop(seconds: 1.5)
        pipeline.recordError("missing source")
        pipeline.recordInterruption(start: start, duration: 30, recovery: "retry")
        pipeline.recordLifecycle(state: "background", at: start)
        let result = try pipeline.stopUnexpectedly(reason: "microphone unavailable", at: start.addingTimeInterval(33), battery: 0.4)
        let saved = try XCTUnwrap(store.loadAll().first)
        XCTAssertTrue(saved.unexpectedStop)
        XCTAssertTrue(saved.unexpectedStopReason?.contains("录音") == true)
        XCTAssertTrue(saved.diagnostics.clipErrors.contains("microphone unavailable"))
        XCTAssertEqual(saved.pendingAnalysis, true)
        XCTAssertNil(saved.report)
        XCTAssertEqual(saved.endDate, start.addingTimeInterval(33))
        XCTAssertEqual(saved.diagnostics.droppedSec, 1.5)
        XCTAssertEqual(saved.diagnostics.interruptions.first?.recovery, "retry")
        XCTAssertEqual(saved.diagnostics.lifecycle.first?.state, "background")
        XCTAssertEqual(saved.diagnostics.finalBattery, 0.4)
        XCTAssertEqual(result.report, saved.report)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.directory("night").appendingPathComponent("tmp/seg-0.m4a").path))
    }
    func testRecordingNeverCallsEvenBrokenClassifier() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let classifier = CountingClassifier()
        let pipeline = try RecordingPipeline(record: .init(id: "night", startDate: Date()), store: NightStore(root: root), classifier: classifier)
        try pipeline.append([Float](repeating: 0.001, count: 35 * 16_000))
        let pending = try pipeline.finish()
        XCTAssertEqual(pipeline.recordedSec, 35)
        XCTAssertEqual(classifier.calls, 0)
        XCTAssertNil(pending.report)
        XCTAssertEqual(pending.pendingAnalysis, true)
    }
    func testUnwritableStoreStillReturnsPartialRecord() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NightStore(root: root)
        let pipeline = try RecordingPipeline(record: .init(id: "night", startDate: Date()), store: store, strictFileErrors: false)
        try pipeline.append([Float](repeating: 0.001, count: 16_000))
        try FileManager.default.removeItem(at: store.directory("night"))
        try Data([1]).write(to: store.directory("night"))
        let record = try pipeline.stopUnexpectedly(reason: "input unavailable", at: Date(), battery: nil)
        XCTAssertTrue(record.unexpectedStop)
        XCTAssertEqual(record.pendingAnalysis, true)
        XCTAssertNil(record.report)
        XCTAssertFalse(record.diagnostics.clipErrors.isEmpty)
    }
    func testOldNightWithoutDiagnosticsStillDecodes() throws {
        let record = NightRecord(id: "legacy", startDate: Date(timeIntervalSince1970: 0))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        object.removeValue(forKey: "diagnostics")
        let saved = try JSONDecoder().decode(NightRecord.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertTrue(saved.diagnostics.clipErrors.isEmpty)
        XCTAssertEqual(saved.diagnostics.droppedSec, 0)
        XCTAssertNil(saved.pendingAnalysis)
    }
}
