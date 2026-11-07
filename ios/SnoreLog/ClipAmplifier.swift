import Foundation
import AVFAudio

/// Playback/export copies only. Recording PCM and retained originals are never rewritten.
enum ClipAmplifier {
    struct Result: Sendable {
        let url: URL
        let gainDb: Double
    }
    struct Levels {
        let loudestSecondDbFS: Double
        let peakDbFS: Double
        let loudestSecondOffset: Double
    }
    enum Failure: Error { case invalidAudio, outputIsSource }

    static func prepare(source: URL, directory: URL) throws -> Result {
        let buffer = try decode(source)
        let levels = try measure(buffer)
        // Silence stays silent. Ordinary loud audio is not normalized down to -20,
        // but over-ceiling peaks must be attenuated to satisfy the hard peak limit.
        let gainDb: Double
        if levels.peakDbFS == -.infinity { gainDb = 0 }
        else {
            gainDb = min(45, max(0, -20 - levels.loudestSecondDbFS), -1 - levels.peakDbFS)
        }
        let scale = Float(pow(10, gainDb / 20))
        guard let channels = buffer.floatChannelData else { throw Failure.invalidAudio }
        for channel in 0..<Int(buffer.format.channelCount) {
            for frame in 0..<Int(buffer.frameLength) { channels[channel][frame] *= scale }
        }
        let output = directory.appendingPathComponent(source.deletingPathExtension().lastPathComponent + "-放大.wav")
        guard output.standardizedFileURL.resolvingSymlinksInPath() != source.standardizedFileURL.resolvingSymlinksInPath() else {
            throw Failure.outputIsSource
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // WAV float PCM avoids AAC re-encoding overshoots after the peak limiter.
        let file = try AVAudioFile(forWriting: output, settings: buffer.format.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
        return Result(url: output, gainDb: gainDb)
    }

    static func measure(url: URL) throws -> Levels { try measure(decode(url)) }

    private static func decode(_ url: URL) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.length > 0, file.length <= Int64(UInt32.max),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw Failure.invalidAudio
        }
        try file.read(into: buffer)
        guard buffer.frameLength > 0 else { throw Failure.invalidAudio }
        return buffer
    }

    private static func measure(_ buffer: AVAudioPCMBuffer) throws -> Levels {
        guard let channels = buffer.floatChannelData, buffer.format.sampleRate > 0 else { throw Failure.invalidAudio }
        let count = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard count > 0, channelCount > 0 else { throw Failure.invalidAudio }
        let window = min(count, max(1, Int(buffer.format.sampleRate.rounded())))
        var powers = [Double](repeating: 0, count: count)
        var peak = 0.0
        for channel in 0..<channelCount {
            for frame in 0..<count {
                let value = Double(channels[channel][frame])
                guard value.isFinite else { throw Failure.invalidAudio }
                peak = max(peak, abs(value))
                powers[frame] += value * value / Double(channelCount)
            }
        }
        // Sample-wise sliding windows also catch a loud second straddling two
        // integer seconds. Partial final windows must not inflate the level.
        var sum = powers.prefix(window).reduce(0, +)
        var maxSum = sum
        var loudestStart = 0
        if count > window {
            for frame in window..<count {
                sum += powers[frame] - powers[frame - window]
                if sum > maxSum { maxSum = sum; loudestStart = frame - window + 1 }
            }
        }
        return Levels(loudestSecondDbFS: maxSum > 0 ? 10 * log10(maxSum / Double(window)) : -.infinity,
                      peakDbFS: peak > 0 ? 20 * log10(peak) : -.infinity,
                      loudestSecondOffset: Double(loudestStart) / buffer.format.sampleRate)
    }
}
