import Foundation
import AVFAudio
import SoundAnalysis
import CoreMedia
import Testing
@testable import SnoreCore

private final class LegacyObserver: NSObject, SNResultsObserving, @unchecked Sendable {
    let completed = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var confidence: FrameConfidence?
    private var failure: (any Error)?
    func request(_ request: any SNRequest, didProduce result: any SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        let value = FrameConfidence(
            snoring: result.classifications.first { $0.identifier == "snoring" }?.confidence ?? 0,
            breathing: result.classifications.first { $0.identifier == "breathing" }?.confidence ?? 0)
        lock.lock(); confidence = value; lock.unlock()
    }
    func request(_ request: any SNRequest, didFailWithError error: any Error) {
        lock.lock(); failure = error; lock.unlock()
        completed.signal()
    }
    func requestDidComplete(_ request: any SNRequest) { completed.signal() }
    func value() throws -> FrameConfidence {
        lock.lock(); defer { lock.unlock() }
        if let failure { throw failure }
        guard let confidence else { throw ClassificationError.noResult }
        return confidence
    }
}

/// An isolated one-second model invocation prevents external PCM chunk sizes from changing
/// classifier context. No microphone, downloads, or application audio session are used.
private final class LegacyClassifier: SnoreClassifier {
    public init() {}
    public func classify(samples: [Float], second: Int) throws -> FrameConfidence {
        guard samples.count == 16_000 else { throw ClassificationError.invalidFrame }
        return try autoreleasepool {
            let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
            request.windowDuration = CMTime(seconds: 1, preferredTimescale: 16_000)
            request.overlapFactor = 0
            let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000),
                  let channel = buffer.floatChannelData?[0] else { throw ClassificationError.bufferAllocation }
            buffer.frameLength = 16_000
            samples.withUnsafeBufferPointer { source in channel.update(from: source.baseAddress!, count: source.count) }
            let analyzer = SNAudioStreamAnalyzer(format: format)
            let observer = LegacyObserver()
            try analyzer.add(request, withObserver: observer)
            analyzer.analyze(buffer, atAudioFramePosition: 0)
            analyzer.completeAnalysis()
            guard observer.completed.wait(timeout: .now() + 30) == .success else {
                analyzer.removeAllRequests()
                throw ClassificationError.timedOut
            }
            return try observer.value()
        }
    }
}

@Test func reusedClassifierMatchesLegacyPerFrame() throws {
    let reused = AppleSnoreClassifier()
    let legacy = LegacyClassifier()
    var oldMs = 0.0, newMs = 0.0
    let count = 120
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures/out/06_tv_speech.wav")
    let audio = try AVAudioFile(forReading: fixture)
    let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 16_000)!
    for second in 0..<count {
        try audio.read(into: buffer, frameCount: 16_000)
        let pcm = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        var now = Date()
        let old = try legacy.classify(samples: pcm, second: second)
        oldMs += Date().timeIntervalSince(now) * 1000
        now = Date()
        let new = try reused.classify(samples: pcm, second: second)
        newMs += Date().timeIntervalSince(now) * 1000
        #expect(old.snoring == new.snoring)
        #expect(old.breathing == new.breathing)
    }
    print("02a classifier benchmark frames=\(count) legacyMsPerFrame=\(oldMs / Double(count)) reusedMsPerFrame=\(newMs / Double(count))")
}

@Test func classifierMailboxMatchesExactWindowAndIsolatesStaleCallbacks() throws {
    let old = ClassifierResultMailbox()
    old.record(index: 0, confidence: .init(snoring: 0.1))
    #expect(throws: ClassificationError.self) { try old.value(at: 1, timeoutSec: 0) }
    old.record(index: 1, confidence: .init(snoring: 0.2))
    #expect(try old.value(at: 1).snoring == 0.2)
    #expect(try old.value(at: 0).snoring == 0.1)
    old.fail(ClassificationError.noResult)
    let fresh = ClassifierResultMailbox()
    old.record(index: 0, confidence: .init(snoring: 0.9))
    fresh.record(index: 0, confidence: .init(snoring: 0.4))
    #expect(try fresh.value(at: 0).snoring == 0.4)
}
