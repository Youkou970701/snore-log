import Foundation
import AVFAudio
import SnoreCore

final class DemoClassifier: SnoreClassifier {
    struct Label: Decodable { var second: Int?; var snoring: Double; var breathing: Double? }
    let labels: [Int: FrameConfidence]
    init(url: URL) throws {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        var result: [Int: FrameConfidence] = [:]
        if let array = try? decoder.decode([Label].self, from: data) {
            for (index, value) in array.enumerated() { result[value.second ?? index] = .init(snoring: value.snoring, breathing: value.breathing ?? 0) }
        } else {
            for (key,value) in try decoder.decode([String:Label].self, from: data) {
                guard let second = Int(key), second >= 0 else { throw CocoaError(.fileReadCorruptFile) }
                result[second] = .init(snoring: value.snoring, breathing: value.breathing ?? 0)
            }
        }
        guard result.allSatisfy({ $0.key >= 0 && (0...1).contains($0.value.snoring) && (0...1).contains($0.value.breathing) }) else { throw CocoaError(.fileReadCorruptFile) }
        labels = result
    }
    func classify(samples: [Float], second: Int) throws -> FrameConfidence { labels[second] ?? .init(snoring: 0) }
}

enum DemoRunner {
    static func startDate(calendar: Calendar = .current) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 23, minute: 30))!
    }
    static func run(wav: URL, labels: URL?, store: NightStore, gaps: [(Double, Double)] = [], alarmAt: Double? = nil, onProgress: ((Double, Double?) -> Void)? = nil) throws -> NightRecord {
        let start = startDate() // Fixed local calendar night, not a UTC instant.
        let record = NightRecord(id: "demo-" + UUID().uuidString, startDate: start, alarmDate: alarmAt.map { start.addingTimeInterval($0) })
        let classifier: any SnoreClassifier = try labels.map { try DemoClassifier(url: $0) } ?? AppleSnoreClassifier()
        let pipeline = try RecordingPipeline(record: record, store: store, classifier: classifier)
        var events = gaps.map { (sample: Int(($0.0 * 16_000).rounded()), gap: Optional($0.1)) }
        if let alarmAt { events.append((Int((alarmAt * 16_000).rounded()), nil)) }
        guard events.allSatisfy({ $0.sample >= 0 && ($0.gap == nil || ($0.gap!.isFinite && $0.gap! > 0)) }) else { throw CocoaError(.fileReadCorruptFile) }
        events.sort { $0.sample < $1.sample }
        var position = 0, event = 0
        var lastProgress = -120.0
        try AudioFilePCM.read(wav) { samples in
            var offset = 0
            while offset < samples.count || (event < events.count && events[event].sample == position) {
                if event < events.count, events[event].sample == position {
                    if let gap = events[event].gap { try pipeline.markGap(seconds: gap) } else { pipeline.markAlarm() }
                    event += 1; continue
                }
                let count = event < events.count ? min(samples.count - offset, events[event].sample - position) : samples.count - offset
                try pipeline.append(Array(samples[offset..<(offset + count)]))
                position += count; offset += count
                if Double(position) / 16_000 - lastProgress >= 120 {
                    lastProgress = Double(position) / 16_000
                    onProgress?(pipeline.recordedSec, pipeline.latestDb)
                }
            }
        }
        guard event == events.count else { throw CocoaError(.fileReadCorruptFile) }
        let pending = try pipeline.finish()
        let analysis = try DeferredNightAnalysis(record: pending, store: store, classifier: classifier)
        var result = pending
        while result.pendingAnalysis == true { result = try analysis.step() }
        return result
    }
}
/// Continuous conversion shared by local demo input. End-of-stream explicitly drains the converter.
enum AudioFilePCM {
    static func read(_ url: URL, consume: ([Float]) throws -> Void) throws {
        let file = try AVAudioFile(forReading: url)
        let target = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        guard let converter = AVAudioConverter(from: file.processingFormat, to: target),
              let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 8192) else { throw CocoaError(.fileReadUnknown) }
        while true {
            var failure: Error?
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { requested, input in
                if file.framePosition >= file.length { input.pointee = .endOfStream; return nil }
                do {
                    try file.read(into: source, frameCount: min(requested, source.frameCapacity, AVAudioFrameCount(min(Int64(source.frameCapacity), file.length - file.framePosition))))
                    input.pointee = source.frameLength == 0 ? .endOfStream : .haveData
                    return source.frameLength == 0 ? nil : source
                } catch { failure = error; input.pointee = .endOfStream; return nil }
            }
            if let failure { throw failure }; if let error { throw error }
            if output.frameLength > 0 {
                try consume(Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength))))
            }
            if status == .endOfStream { break }
            if status == .error { throw CocoaError(.fileReadUnknown) }
        }
    }
}

public enum HostDemoAPI {
    public static func run(wav: URL, labels: URL?, root: URL, gaps: [(Double, Double)] = [], alarmAt: Double? = nil) throws -> Data {
        let record = try DemoRunner.run(wav: wav, labels: labels, store: NightStore(root: root), gaps: gaps, alarmAt: alarmAt)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(record)
    }
}
