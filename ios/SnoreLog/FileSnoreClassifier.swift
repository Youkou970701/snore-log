import Foundation
import AVFAudio
import SoundAnalysis
import CoreMedia
import SnoreCore

/// Foreground lifetime token shared by the main actor and the analysis worker.
/// An analysis that crossed any background transition stays cancelled after resume.
enum AnalysisActivity {
    private static let lock = NSLock()
    private static var enabled = true
    private static var generation = 0
    static func setEnabled(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        if !value { generation += 1 }
        enabled = value
    }
    static func token() throws -> Int {
        lock.lock(); defer { lock.unlock() }
        guard enabled else { throw CancellationError() }
        return generation
    }
    static func check(_ token: Int) throws {
        lock.lock(); defer { lock.unlock() }
        guard enabled, token == generation else { throw CancellationError() }
    }
}

/// Uses the same one-second, non-overlapping model windows as AppleSnoreClassifier.
/// File analysis is synchronous and must only be called by the foreground analysis worker.
enum FileSnoreClassifier {
    private final class Observer: NSObject, SNResultsObserving {
        var frames: [Int: FrameConfidence] = [:]
        var failure: Error?
        let token: Int
        weak var analyzer: SNAudioFileAnalyzer?
        init(token: Int) { self.token = token }
        func request(_ request: any SNRequest, didProduce result: any SNResult) {
            do { try AnalysisActivity.check(token) }
            catch { failure = error; analyzer?.cancelAnalysis(); return }
            guard let result = result as? SNClassificationResult else { return }
            let index = Int(result.timeRange.start.seconds.rounded())
            frames[index] = FrameConfidence(
                snoring: result.classifications.first { $0.identifier == "snoring" }?.confidence ?? 0,
                breathing: result.classifications.first { $0.identifier == "breathing" }?.confidence ?? 0)
        }
        func request(_ request: any SNRequest, didFailWithError error: any Error) { failure = error }
    }
    /// Packs eligible complete frames into a short-lived lossless file. This also
    /// handles frames crossing AAC segment boundaries without changing model windows.
    static func analyze(samples: [Float]) throws -> [FrameConfidence] {
        let token = try AnalysisActivity.token()
        guard samples.count % 16_000 == 0 else { throw ClassificationError.invalidFrame }
        guard !samples.isEmpty else { return [] }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("snore-analysis-" + UUID().uuidString + ".caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        var file: AVAudioFile? = try AVAudioFile(forWriting: url, settings: format.settings)
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000) else { throw ClassificationError.bufferAllocation }
        pcm.frameLength = 16_000
        for offset in stride(from: 0, to: samples.count, by: 16_000) {
            try AnalysisActivity.check(token)
            samples.withUnsafeBufferPointer { pcm.floatChannelData![0].update(from: $0.baseAddress! + offset, count: 16_000) }
            try file!.write(from: pcm)
        }
        file = nil
        try AnalysisActivity.check(token)
        let result = try analyze(url)
        try AnalysisActivity.check(token)
        return result
    }
    static func analyze(_ url: URL) throws -> [FrameConfidence] {
        let token = try AnalysisActivity.token()
        let file = try AVAudioFile(forReading: url)
        let count = Int(Double(file.length) / file.processingFormat.sampleRate)
        guard count > 0 else { return [] }
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        request.windowDuration = CMTime(seconds: 1, preferredTimescale: 16_000)
        request.overlapFactor = 0
        let observer = Observer(token: token)
        let analyzer = try SNAudioFileAnalyzer(url: url)
        observer.analyzer = analyzer
        try analyzer.add(request, withObserver: observer)
        try AnalysisActivity.check(token)
        analyzer.analyze()
        try AnalysisActivity.check(token)
        if let failure = observer.failure { throw failure }
        return try (0..<count).map { index in
            guard let frame = observer.frames[index] else { throw ClassificationError.noResult }
            return frame
        }
    }
}
