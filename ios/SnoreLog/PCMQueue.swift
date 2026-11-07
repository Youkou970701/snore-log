import Foundation
import AVFAudio

/// Capacity is measured in frames, independent of actual render callback chunk sizes.
final class PCMQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var channels: [[Float]]
    private var read = 0, write = 0, count = 0, dropped = 0
    let format: AVAudioFormat
    let capacityFrames: Int
    var capacitySeconds: Double { Double(capacityFrames) / format.sampleRate }
    init(format: AVAudioFormat, minimumSeconds: Double = 30) {
        self.format = format
        let capacity = Int(ceil(format.sampleRate * max(30, minimumSeconds)))
        capacityFrames = capacity
        channels = (0..<Int(format.channelCount)).map { _ in [Float](repeating: 0, count: capacity) }
    }
    func push(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        let n = Int(buffer.frameLength)
        guard dropped == 0, n <= capacityFrames - count else { dropped += n; return }
        let first = min(n, capacityFrames - write)
        for c in channels.indices {
            channels[c].withUnsafeMutableBufferPointer { dst in
                dst.baseAddress!.advanced(by: write).update(from: buffer.floatChannelData![c], count: first)
                if n > first { dst.baseAddress!.update(from: buffer.floatChannelData![c].advanced(by: first), count: n-first) }
            }
        }
        write = (write + n) % capacityFrames; count += n
    }
    func discardPendingSeconds() -> Double {
        lock.lock(); defer { lock.unlock() }
        let seconds = Double(count + dropped) / format.sampleRate
        count = 0; dropped = 0; read = write
        return seconds
    }
    func pop(into buffer: AVAudioPCMBuffer) -> (Bool, Double) {
        lock.lock(); defer { lock.unlock() }
        guard count > 0 else {
            let gap = Double(dropped) / format.sampleRate; dropped = 0
            return (false, gap)
        }
        let n = min(count, Int(buffer.frameCapacity)), first = min(n, capacityFrames-read)
        buffer.frameLength = AVAudioFrameCount(n)
        for c in channels.indices {
            channels[c].withUnsafeBufferPointer { src in
                buffer.floatChannelData![c].update(from: src.baseAddress!.advanced(by: read), count: first)
                if n > first { buffer.floatChannelData![c].advanced(by: first).update(from: src.baseAddress!, count: n-first) }
            }
        }
        read = (read+n) % capacityFrames; count -= n
        return (true, 0)
    }
}
