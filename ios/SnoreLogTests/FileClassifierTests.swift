import Foundation
import AVFAudio
import XCTest
import SnoreCore
@testable import SnoreLog

final class FileClassifierTests: XCTestCase {
    private struct Table: SnoreClassifier {
        var frames: [FrameConfidence]
        func classify(samples: [Float], second: Int) throws -> FrameConfidence { frames[second] }
    }
    func testBackgroundGateCancelsAndOldTokenCannotResume() throws {
        defer { AnalysisActivity.setEnabled(true) }
        let token = try AnalysisActivity.token()
        AnalysisActivity.setEnabled(false)
        XCTAssertThrowsError(try FileSnoreClassifier.analyze(samples: [Float](repeating: 0, count: 16_000))) { error in
            XCTAssertTrue(error is CancellationError)
        }
        AnalysisActivity.setEnabled(true)
        XCTAssertThrowsError(try AnalysisActivity.check(token))
        XCTAssertNoThrow(try AnalysisActivity.check(AnalysisActivity.token()))
    }
    func testFileAndStreamWindowsAreIdentical() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        var file: AVAudioFile? = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
        buffer.frameLength = 16_000
        var frames: [[Float]] = []
        for second in 0..<120 {
            let samples = (0..<16_000).map { i in Float(sin(Double(i + second * 16_000) * 0.075) * (second % 4 == 0 ? 0.3 : 0.001)) }
            frames.append(samples)
            samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
            try file!.write(from: buffer)
        }
        file = nil
        let classifier = AppleSnoreClassifier()
        let streamStart = Date()
        let streamed = try frames.enumerated().map { try classifier.classify(samples: $0.element, second: $0.offset) }
        let streamElapsed = Date().timeIntervalSince(streamStart)
        let fileStart = Date()
        let analyzed = try FileSnoreClassifier.analyze(samples: frames.flatMap { $0 })
        let fileElapsed = Date().timeIntervalSince(fileStart)
        print("03a classifier benchmark: 120 seconds stream=\(streamElapsed)s file=\(fileElapsed)s")
        XCTAssertEqual(analyzed.count, streamed.count)
        let date = Date(timeIntervalSince1970: 0)
        let streamReport = NightAnalyzer(startDate: date, classifier: Table(frames: streamed))
        let fileReport = NightAnalyzer(startDate: date, classifier: Table(frames: analyzed))
        for samples in frames { try streamReport.append(samples); try fileReport.append(samples) }
        XCTAssertEqual(streamReport.finish(), fileReport.finish())
        // Restarting the bulk analyzer at a segment boundary must preserve model output.
        let first = try FileSnoreClassifier.analyze(samples: frames.prefix(60).flatMap { $0 })
        let second = try FileSnoreClassifier.analyze(samples: frames.suffix(60).flatMap { $0 })
        for (a, b) in zip(first + second, streamed) {
            XCTAssertEqual(a.snoring, b.snoring)
            XCTAssertEqual(a.breathing, b.breathing)
        }
        for (a, b) in zip(analyzed, streamed) {
            XCTAssertEqual(a.snoring, b.snoring)
            XCTAssertEqual(a.breathing, b.breathing)
        }
    }
}
