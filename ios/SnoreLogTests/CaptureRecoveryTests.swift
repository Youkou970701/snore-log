import XCTest
import AVFAudio
import SnoreCore
@testable import SnoreLog
final class CaptureRecoveryTests: XCTestCase {
    #if os(iOS)
    func testMixedSessionCanPlayDeferredRetainedAAC() throws {
        final class Classifier: SnoreClassifier {
            func classify(samples: [Float], second: Int) throws -> FrameConfidence { .init(snoring: 1) }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NightStore(root: root)
        let pipeline = try RecordingPipeline(record: NightRecord(id: "playback", startDate: Date()), store: store)
        // The retained section is effectively silent at -120 dBFS, avoiding test noise.
        try pipeline.append(Array(repeating: 0, count: 10 * 16_000))
        try pipeline.append(Array(repeating: 0.000001, count: 20 * 16_000))
        var record = try pipeline.finish()
        let analysis = try DeferredNightAnalysis(record: record, store: store, classifier: Classifier())
        while record.pendingAnalysis == true { record = try analysis.step() }
        let clip = try XCTUnwrap(record.clips.first)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .mixWithOthers])
        try session.setPrefersNoInterruptionsFromSystemAlerts(true)
        try session.setActive(true)
        defer { try? session.setActive(false) }
        XCTAssertTrue(session.categoryOptions.contains(.mixWithOthers))
        let player = try AVAudioPlayer(contentsOf: store.directory(record.id).appendingPathComponent("clips/\(clip.fileName)"))
        XCTAssertTrue(player.prepareToPlay())
        XCTAssertTrue(player.play())
        player.stop()
    }
    #endif
    func testBeganWithoutEndedRetriesEveryThirtySecondsAndForeground() throws {
        final class Session: RecoverySessionEngine {
            var attempts = 0
            var fails = true
            func activateAndRestart() throws { attempts += 1; if fails { throw CocoaError(.fileReadUnknown) } }
        }
        let session = Session(), zero = Date(timeIntervalSince1970: 0)
        var recovery = RecoveryController()
        recovery.begin(at: zero)
        XCTAssertNil(try recovery.attempt(at: zero.addingTimeInterval(29), method: "timer", session: session))
        XCTAssertThrowsError(try recovery.attempt(at: zero.addingTimeInterval(30), method: "timer", session: session))
        XCTAssertEqual(recovery.began, zero)
        XCTAssertNil(try recovery.attempt(at: zero.addingTimeInterval(59), method: "timer", session: session))
        XCTAssertThrowsError(try recovery.attempt(at: zero.addingTimeInterval(60), method: "timer", session: session))
        session.fails = false
        let event = try XCTUnwrap(recovery.attempt(at: zero.addingTimeInterval(65), method: "foreground", force: true, session: session))
        XCTAssertEqual(event.duration, 65); XCTAssertEqual(event.method, "foreground")
        XCTAssertEqual(session.attempts, 3); XCTAssertNil(recovery.began)
        XCTAssertNil(try recovery.attempt(at: zero.addingTimeInterval(95), method: "timer", session: session))
    }
    func testRingCapacityIsAtLeastThirtySecondsForAnyChunkSize() throws {
        for rate in [48_000.0, 96_000.0] {
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
            let ring = PCMQueue(format: format)
            XCTAssertGreaterThanOrEqual(ring.capacitySeconds, 30)
            let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
            input.frameLength = 1024
            input.floatChannelData![0].initialize(repeating: 0.1, count: 1024)
            let chunks = ring.capacityFrames / 1024
            for _ in 0..<chunks { ring.push(input) }
            let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192))
            var frames = 0
            while true {
                let (has, gap) = ring.pop(into: output)
                XCTAssertEqual(gap, 0)
                if !has { break }
                frames += Int(output.frameLength)
                XCTAssertEqual(output.floatChannelData![0][0], 0.1)
            }
            XCTAssertEqual(frames, chunks * 1024)
            // Refilling after wraparound must keep every sample in order.
            for _ in 0..<chunks { ring.push(input) }
            ring.push(input) // overflow tracked after queued data, once
            var missing = 0.0
            while true {
                let (has, gap) = ring.pop(into: output); missing += gap
                if !has { break }
            }
            XCTAssertEqual(missing, 1024 / rate, accuracy: 1e-12)
            XCTAssertEqual(ring.pop(into: output).1, 0)
        }
    }
}
