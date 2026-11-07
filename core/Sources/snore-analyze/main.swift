import Foundation
import AVFAudio
import SnoreCore

struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

struct Label: Decodable {
    var second: Int?
    var snoring: Double
    var breathing: Double?
}

final class ScriptClassifier: SnoreClassifier {
    let labels: [Int: FrameConfidence]
    init(url: URL) throws {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        var parsed: [Int: FrameConfidence] = [:]
        if let array = try? decoder.decode([Label].self, from: data) {
            for (index, label) in array.enumerated() {
                parsed[label.second ?? index] = FrameConfidence(snoring: label.snoring, breathing: label.breathing ?? 0)
            }
        } else if let dictionary = try? decoder.decode([String: Label].self, from: data) {
            for (key, label) in dictionary {
                guard let second = Int(key), second >= 0 else { throw CLIError("Label keys must be nonnegative seconds") }
                parsed[second] = FrameConfidence(snoring: label.snoring, breathing: label.breathing ?? 0)
            }
        } else { throw CLIError("Expected a label array or an object keyed by second") }
        for (second, value) in parsed {
            guard second >= 0, value.snoring.isFinite, value.breathing.isFinite,
                  (0...1).contains(value.snoring), (0...1).contains(value.breathing) else {
                throw CLIError("Invalid confidence at second \(second)")
            }
        }
        labels = parsed
    }
    func classify(samples: [Float], second: Int) throws -> FrameConfidence {
        labels[second] ?? FrameConfidence(snoring: 0)
    }
}

/// Bounded streaming decoding and sample-rate/channel conversion. The converter receives
/// one continuous source stream; --chunk controls only NightAnalyzer's PCM call boundaries.
func readAudio(_ url: URL, chunkSamples: Int, consume: ([Float]) throws -> Void) throws {
    let file = try AVAudioFile(forReading: url)
    let sourceFormat = file.processingFormat
    let target = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    guard let converter = AVAudioConverter(from: sourceFormat, to: target),
          let source = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: 8_192),
          let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 8_192) else {
        throw CLIError("Cannot initialize audio conversion")
    }
    var pending: [Float] = []
    var eof = false
    var readError: (any Error)?
    while true {
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { requested, inputStatus in
            if eof || file.framePosition >= file.length { inputStatus.pointee = .endOfStream; return nil }
            do {
                let available = AVAudioFrameCount(min(Int64(source.frameCapacity), file.length - file.framePosition))
                try file.read(into: source, frameCount: min(available, requested))
                if source.frameLength == 0 { eof = true; inputStatus.pointee = .endOfStream; return nil }
                inputStatus.pointee = .haveData
                return source
            } catch {
                readError = error; eof = true; inputStatus.pointee = .endOfStream; return nil
            }
        }
        if let readError { throw readError }
        if let error { throw error }
        if output.frameLength > 0, let channel = output.floatChannelData?[0] {
            pending.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
            var consumed = 0
            while pending.count - consumed >= chunkSamples {
                try consume(Array(pending[consumed..<(consumed + chunkSamples)]))
                consumed += chunkSamples
            }
            if consumed > 0 { pending.removeFirst(consumed) }
        }
        if status == .endOfStream { break }
        if status == .error { throw CLIError("Audio converter failed") }
    }
    if !pending.isEmpty { try consume(pending) }
}

func run() throws {
    let args = Array(CommandLine.arguments.dropFirst())
    let usage = "Usage: snore-analyze <file.wav|m4a> [--offset 90] [--delay 0] [--chunk 120] [--fake-classifier labels.json] [--gap-at SEC:DUR] [--alarm-at SEC]"
    if args == ["--help"] || args == ["-h"] { print(usage); return }
    guard let path = args.first, !path.hasPrefix("--") else { throw CLIError(usage) }
    var config = AnalyzerConfig()
    var chunkSec = 120.0
    var labelsPath: String?
    var events: [(sample: Int, gap: Double?, order: Int)] = []
    var hasAlarm = false
    func samplePosition(_ value: String) throws -> Int {
        guard let seconds = Double(value), seconds.isFinite, seconds >= 0,
              seconds < Double(Int.max / 16_000) else { throw CLIError("Invalid event time: \(value)") }
        return Int((seconds * 16_000).rounded())
    }
    var index = 1
    while index < args.count {
        guard index + 1 < args.count else { throw CLIError("Missing value for \(args[index])") }
        let option = args[index], value = args[index + 1]
        switch option {
        case "--offset", "--delay", "--chunk":
            guard let number = Double(value), number.isFinite else { throw CLIError("Invalid number for \(option)") }
            if option == "--offset" { config.calibrationOffsetDb = number }
            if option == "--delay" {
                guard number >= 0 else { throw CLIError("Delay must be nonnegative") }
                config.startDelaySec = number
            }
            if option == "--chunk" {
                guard number >= 1.0 / 16_000, number <= Double(Int.max / 16_000) else { throw CLIError("Chunk must be positive and representable") }
                chunkSec = number
            }
        case "--gap-at":
            let parts = value.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, let duration = Double(parts[1]), duration.isFinite, duration > 0 else {
                throw CLIError("Gap must be SEC:DUR with positive duration")
            }
            events.append((try samplePosition(String(parts[0])), duration, index))
        case "--alarm-at":
            guard !hasAlarm else { throw CLIError("--alarm-at may only be specified once") }
            hasAlarm = true
            events.append((try samplePosition(value), nil, index))
        case "--fake-classifier": labelsPath = value
        default: throw CLIError("Unknown option \(option)")
        }
        index += 2
    }
    let classifier: any SnoreClassifier
    if let labelsPath { classifier = try ScriptClassifier(url: URL(fileURLWithPath: labelsPath)) }
    else { classifier = AppleSnoreClassifier() }
    let analyzer = NightAnalyzer(config: config, startDate: Date(timeIntervalSince1970: 0), classifier: classifier)
    events.sort { $0.sample == $1.sample ? $0.order < $1.order : $0.sample < $1.sample }
    var position = 0
    var nextEvent = 0
    try readAudio(URL(fileURLWithPath: path), chunkSamples: Int(chunkSec * 16_000)) { samples in
        var offset = 0
        while offset < samples.count || (nextEvent < events.count && events[nextEvent].sample == position) {
            if nextEvent < events.count, events[nextEvent].sample == position {
                if let duration = events[nextEvent].gap { analyzer.markGap(seconds: duration) }
                else { analyzer.markAlarm() }
                nextEvent += 1
                continue
            }
            let remaining = samples.count - offset
            let count = nextEvent < events.count ? min(remaining, events[nextEvent].sample - position) : remaining
            try analyzer.append(Array(samples[offset..<(offset + count)]))
            offset += count; position += count
        }
    }
    guard nextEvent == events.count else { throw CLIError("Event time exceeds audio duration") }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(analyzer.finish())
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([10]))
}

do { try run() }
catch {
    FileHandle.standardError.write(Data("snore-analyze: \(error)\n".utf8))
    exit(1)
}
