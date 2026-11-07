import Foundation
import AVFAudio
import SoundAnalysis
import CoreMedia

public struct FrameConfidence: Sendable {
    public var snoring: Double
    public var breathing: Double
    public init(snoring: Double, breathing: Double = 0) {
        self.snoring = snoring
        self.breathing = breathing
    }
}

/// Called exactly once per complete one-second PCM frame, independently of append boundaries.
public protocol SnoreClassifier {
    func classify(samples: [Float], second: Int) throws -> FrameConfidence
}

public enum ClassificationError: Error {
    case invalidFrame, bufferAllocation, noResult, timedOut
}

final class ClassifierResultMailbox: @unchecked Sendable {
    private let condition = NSCondition()
    private var results: [Int: FrameConfidence] = [:]
    private var failure: Error?
    func record(index: Int, confidence: FrameConfidence) {
        condition.lock(); results[index] = confidence; condition.broadcast(); condition.unlock()
    }
    func fail(_ error: Error) {
        condition.lock(); failure = error; condition.broadcast(); condition.unlock()
    }
    func value(at index: Int, timeoutSec: Double = 30) throws -> FrameConfidence {
        condition.lock(); defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeoutSec)
        while results[index] == nil && failure == nil {
            guard condition.wait(until: deadline) else { throw ClassificationError.timedOut }
        }
        if let failure { throw failure }
        guard let result = results.removeValue(forKey: index) else { throw ClassificationError.noResult }
        return result
    }
}
private final class ResultObserver: NSObject, SNResultsObserving, @unchecked Sendable {
    let mailbox = ClassifierResultMailbox()
    func request(_ request: any SNRequest, didProduce result: any SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        let index = Int(result.timeRange.start.seconds.rounded())
        mailbox.record(index: index, confidence: FrameConfidence(
            snoring: result.classifications.first { $0.identifier == "snoring" }?.confidence ?? 0,
            breathing: result.classifications.first { $0.identifier == "breathing" }?.confidence ?? 0))
    }
    func request(_ request: any SNRequest, didFailWithError error: any Error) { mailbox.fail(error) }
}

/// One request, analyzer and PCM buffer per night. Calls are serialized by NightAnalyzer.
/// Internal model positions are consecutive invocation indices, independent of file/gap offsets.
public final class AppleSnoreClassifier: SnoreClassifier {
    private var analyzer: SNAudioStreamAnalyzer?
    private var request: SNClassifySoundRequest?
    private var buffer: AVAudioPCMBuffer?
    private var observer = ResultObserver()
    private var index = 0
    public init() {}
    private func prepare() throws {
        guard analyzer == nil else { return }
        observer = ResultObserver()
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        request.windowDuration = CMTime(seconds: 1, preferredTimescale: 16_000)
        request.overlapFactor = 0
        let analyzer = SNAudioStreamAnalyzer(format: format)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000) else { throw ClassificationError.bufferAllocation }
        try analyzer.add(request, withObserver: observer)
        self.request = request; self.buffer = buffer; self.analyzer = analyzer
    }
    public func classify(samples: [Float], second: Int) throws -> FrameConfidence {
        guard samples.count == 16_000 else { throw ClassificationError.invalidFrame }
        try prepare()
        guard let buffer, let analyzer, let channel = buffer.floatChannelData?[0] else { throw ClassificationError.bufferAllocation }
        buffer.frameLength = 16_000
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: $0.count) }
        analyzer.analyze(buffer, atAudioFramePosition: Int64(index) * 16_000)
        // Wait for this exact window, never reuse the previous callback's confidence.
        do {
            let result = try observer.mailbox.value(at: index)
            index += 1
            return result
        } catch {
            // A timed-out callback belongs to its old observer only. Reset the entire
            // failed session so delayed results and sticky errors cannot contaminate retries.
            analyzer.removeAllRequests()
            self.analyzer = nil; request = nil; self.buffer = nil
            observer = ResultObserver(); index = 0
            throw error
        }
    }
    deinit { analyzer?.removeAllRequests() }
}
