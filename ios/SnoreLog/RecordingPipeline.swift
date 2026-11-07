import Foundation
import AVFAudio
import SnoreCore

struct RecordingPart: Codable {
    var segment: Int?
    var offset: Int = 0
    var count: Int = 0
    var gap: Double?
    var alarm: Bool = false
}
struct RecordingJournal: Codable {
    var parts: [RecordingPart] = []
    var volumes: [Double] = []
}
/// Capture never instantiates or calls a sound classifier.
final class RecordingPipeline: @unchecked Sendable {
    let store: NightStore
    private(set) var record: NightRecord
    private let strictFileErrors: Bool
    private var writer: AVAudioFile?
    private var segment = 0
    private var segmentOffset = 0
    private var sampleCount = 0
    private var gapSeconds = 0.0
    private var meter: [Float] = []
    private var journal = RecordingJournal()
    private var ended = false
    private(set) var peakFileCount = 0
    private(set) var latestDb: Double?
    var classifierAverageMs: Double { 0 }
    var recordedSec: Double { Double(sampleCount) / 16_000 + gapSeconds }
    static var defaultStrictFileErrors: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }
    private let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    init(record: NightRecord, store: NightStore, classifier: (any SnoreClassifier)? = nil, strictFileErrors: Bool = RecordingPipeline.defaultStrictFileErrors) throws {
        self.record = record; self.store = store; self.strictFileErrors = strictFileErrors
        for name in ["tmp", "clips"] { try FileManager.default.createDirectory(at: store.directory(record.id).appendingPathComponent(name), withIntermediateDirectories: true) }
        try checkpoint()
    }
    /// Recover the final AAC tail written since the last two-minute checkpoint.
    static func recoverJournal(record: inout NightRecord, store: NightStore) throws {
        let url = store.directory(record.id).appendingPathComponent("recording.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var journal = try JSONDecoder().decode(RecordingJournal.self, from: Data(contentsOf: url))
        let tmp = store.directory(record.id).appendingPathComponent("tmp")
        let files = (try? FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)) ?? []
        for fileURL in files.sorted(by: {
            (Int($0.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "seg-", with: "")) ?? 0) <
            (Int($1.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "seg-", with: "")) ?? 0)
        }) {
            guard let n = Int(fileURL.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "seg-", with: "")),
                  let file = try? AVAudioFile(forReading: fileURL) else { continue }
            let committed = journal.parts.filter { $0.segment == n }.map { $0.offset + $0.count }.max() ?? 0
            let extra = Int(file.length) - committed
            if extra > 0 { journal.parts.append(.init(segment: n, offset: committed, count: extra)) }
        }
        var buffer: [Float] = [], frame = 0, duration = 0.0
        for part in journal.parts {
            if let gap = part.gap { buffer.removeAll(); duration += gap; continue }
            if part.alarm { buffer.removeAll(); continue }
            guard let n = part.segment else { continue }
            let file = try AVAudioFile(forReading: tmp.appendingPathComponent("seg-\(n).m4a"))
            file.framePosition = AVAudioFramePosition(part.offset)
            let pcm = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(part.count))!
            try file.read(into: pcm, frameCount: AVAudioFrameCount(part.count))
            buffer.append(contentsOf: UnsafeBufferPointer(start: pcm.floatChannelData![0], count: Int(pcm.frameLength)))
            duration += Double(pcm.frameLength) / 16_000
            var consumed = 0
            while buffer.count - consumed >= 16_000 {
                if frame >= journal.volumes.count {
                    let energy = buffer[consumed..<(consumed + 16_000)].reduce(0.0) { $0 + Double($1) * Double($1) } / 16_000
                    journal.volumes.append(10 * log10(max(energy, 1e-16)) + record.offsetDb)
                }
                frame += 1; consumed += 16_000
            }
            buffer.removeFirst(consumed)
        }
        record.snapshotDate = record.startDate.addingTimeInterval(duration)
        try JSONEncoder().encode(journal).write(to: url, options: .atomic)
    }
    func recordError(_ message: String) {
        record.diagnostics.errorCounts[message, default: 0] += 1
        let now = Date()
        var times = record.diagnostics.errorTimes ?? [:]
        times[message] = .init(first: times[message]?.first ?? now, last: now)
        record.diagnostics.errorTimes = times
        if !record.diagnostics.clipErrors.contains(message), record.diagnostics.clipErrors.count < 100 { record.diagnostics.clipErrors.append(message) }
    }
    private func fileOperation(_ action: () throws -> Void) throws {
        do { try action() } catch { recordError(String(describing: error)); if strictFileErrors { throw error } }
    }
    func recordInterruption(start: Date, duration: Double, recovery: String) { record.diagnostics.interruptions.append(.init(start: start, duration: duration, recovery: recovery)) }
    func recordDrop(seconds: Double) { record.diagnostics.droppedSec += seconds }
    func recordLifecycle(state: String, at: Date) { record.diagnostics.lifecycle.append(.init(state: state, at: at)); try? checkpoint() }
    private func temporary(_ number: Int) -> URL { store.directory(record.id).appendingPathComponent("tmp/seg-\(number).m4a") }
    private func makeWriter(_ url: URL) throws -> AVAudioFile {
        try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000], commonFormat: .pcmFormatFloat32, interleaved: false)
    }
    func append(_ samples: [Float]) throws {
        guard !ended else { return }
        var offset = 0
        while offset < samples.count {
            let number = Int(recordedSec / 120)
            if number != segment { writer = nil; segment = number; segmentOffset = 0 }
            let count = min(samples.count - offset, max(1, Int(((Double(segment + 1) * 120 - recordedSec) * 16_000).rounded())))
            let pcm = Array(samples[offset..<(offset + count)])
            try fileOperation {
                if writer == nil { writer = try makeWriter(temporary(segment)) }
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
                buffer.frameLength = AVAudioFrameCount(count)
                pcm.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: count) }
                try writer!.write(from: buffer)
            }
            if let last = journal.parts.last, last.segment == segment, last.offset + last.count == segmentOffset {
                journal.parts[journal.parts.count - 1].count += count
            } else { journal.parts.append(.init(segment: segment, offset: segmentOffset, count: count)) }
            meter.append(contentsOf: pcm)
            while meter.count >= 16_000 {
                let energy = meter.prefix(16_000).reduce(0.0) { $0 + Double($1) * Double($1) } / 16_000
                let db = 10 * log10(max(energy, 1e-16)) + record.offsetDb
                latestDb = db; journal.volumes.append(db); meter.removeFirst(16_000)
            }
            segmentOffset += count; sampleCount += count; offset += count
            if recordedSec >= Double(segment + 1) * 120 - 1e-8 {
                writer = nil; segment += 1; segmentOffset = 0; try checkpoint()
            }
        }
    }
    func markGap(seconds: Double) throws {
        guard seconds > 0 else { return }
        meter.removeAll()
        journal.parts.append(.init(gap: seconds))
        gapSeconds += seconds
        let next = Int(recordedSec / 120)
        if next != segment { writer = nil; segmentOffset = 0 }; segment = next
        try checkpoint()
    }
    func markAlarm() { meter.removeAll(); journal.parts.append(.init(alarm: true)); try? checkpoint() }
    private func checkpoint() throws {
        record.snapshotDate = record.startDate.addingTimeInterval(recordedSec)
        peakFileCount = max(peakFileCount, (try? FileManager.default.contentsOfDirectory(atPath: store.directory(record.id).appendingPathComponent("tmp").path).count) ?? 0)
        record.diagnostics.peakFileCount = peakFileCount
        try fileOperation {
            try JSONEncoder().encode(journal).write(to: store.directory(record.id).appendingPathComponent("recording.json"), options: .atomic)
            try store.save(record)
        }
    }
    func stopUnexpectedly(reason: String, at date: Date, battery: Double?) throws -> NightRecord {
        record.unexpectedStop = true
        record.unexpectedStopReason = "录音意外停止，请查看诊断详情。"
        recordError(reason)
        _ = try finish(battery: battery); record.endDate = date; try fileOperation { try store.save(record) }; return record
    }
    func finish(battery: Double? = nil) throws -> NightRecord {
        guard !ended else { return record }
        writer = nil; record.diagnostics.finalBattery = battery
        record.pendingAnalysis = true; record.analysisProgress = 0
        try checkpoint(); record.endDate = record.snapshotDate
        try fileOperation { try store.save(record) }; ended = true; return record
    }
}

/// Each atomic checkpoint includes the rule engine and unfinished frame, never reclassifies old segments.
final class DeferredNightAnalysis: @unchecked Sendable {
    private(set) var record: NightRecord
    let store: NightStore
    private let analyzer: NightAnalyzer
    private let classifier: (any SnoreClassifier)?
    private var journal: RecordingJournal
    private var state = State()
    private struct State: Codable {
        var next = 0
        var volume = 0
        var elapsed = 0.0
        var audioElapsed = 0.0
        var alarm = false
        var buffer: [Float] = []
        var analyzer: Data?
    }
    private var segment = 0
    private var writer: AVAudioFile? { nil }
    private var emptyGapSegments: Set<Int> { Set((0...max(segment, 0)).filter { n in !journal.parts.contains { $0.segment == n } }) }
    private let strictFileErrors = true
    init(record: NightRecord, store: NightStore, classifier: (any SnoreClassifier)? = nil) throws {
        self.record = record; self.store = store; self.classifier = classifier
        journal = try JSONDecoder().decode(RecordingJournal.self, from: Data(contentsOf: store.directory(record.id).appendingPathComponent("recording.json")))
        var config = AnalyzerConfig(); config.startDelaySec = record.delaySec; config.calibrationOffsetDb = record.offsetDb
        analyzer = NightAnalyzer(config: config, startDate: record.startDate)
        let checkpoint = store.directory(record.id).appendingPathComponent("analysis.json")
        if FileManager.default.fileExists(atPath: checkpoint.path) {
            state = try JSONDecoder().decode(State.self, from: Data(contentsOf: checkpoint))
            if let data = state.analyzer { try analyzer.restoreCheckpoint(data) }
        }
        segment = journal.parts.compactMap(\.segment).max() ?? 0
        self.record.analysisProgress = journal.parts.isEmpty ? 0 : Double(state.next) / Double(journal.parts.count)
    }
    func step() throws -> NightRecord {
        guard record.pendingAnalysis == true else { return record }
        if state.next < journal.parts.count {
            let part = journal.parts[state.next]
            if let gap = part.gap { flushTail(); analyzer.markGap(seconds: gap); state.elapsed += gap }
            else if part.alarm { flushTail(); analyzer.markAlarm(); state.alarm = true }
            else if let number = part.segment {
                let file = try AVAudioFile(forReading: temporary(number))
                file.framePosition = AVAudioFramePosition(part.offset)
                let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(part.count))!
                try file.read(into: buffer, frameCount: AVAudioFrameCount(part.count))
                guard Int(buffer.frameLength) == part.count else { throw CocoaError(.fileReadCorruptFile) }
                state.buffer.append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![0], count: part.count))
                let frames = state.buffer.count / 16_000
                let eligible = (0..<frames).filter { !state.alarm && state.elapsed + Double($0) >= record.delaySec }
                var confidences: [FrameConfidence] = []
                if classifier == nil, let first = eligible.first {
                    confidences = try FileSnoreClassifier.analyze(samples: Array(state.buffer[(first * 16_000)..<(frames * 16_000)]))
                }
                var index = 0
                for frame in 0..<frames {
                    var confidence = FrameConfidence(snoring: 0)
                    if !state.alarm && state.elapsed >= record.delaySec {
                        if let classifier { confidence = try classifier.classify(samples: Array(state.buffer[(frame * 16_000)..<((frame + 1) * 16_000)]), second: Int(state.audioElapsed.rounded(.down))) }
                        else { confidence = confidences[index]; index += 1 }
                    }
                    guard state.volume < journal.volumes.count else { throw CocoaError(.fileReadCorruptFile) }
                    analyzer.appendFrame(db: journal.volumes[state.volume], confidence: confidence)
                    state.volume += 1; state.elapsed += 1; state.audioElapsed += 1
                }
                state.buffer.removeFirst(frames * 16_000)
            }
            state.next += 1
            state.analyzer = try analyzer.checkpoint()
            try JSONEncoder().encode(state).write(to: store.directory(record.id).appendingPathComponent("analysis.json"), options: .atomic)
            record.analysisProgress = Double(state.next) / Double(max(1, journal.parts.count))
            try store.save(record)
        }
        if state.next == journal.parts.count {
            flushTail()
            let report = analyzer.finish()
            try reconcileFiles(report.retained)
            record.report = report; record.pendingAnalysis = false; record.analysisProgress = 1
            try store.save(record)
            try FileManager.default.removeItem(at: store.directory(record.id).appendingPathComponent("tmp"))
            try? FileManager.default.removeItem(at: store.directory(record.id).appendingPathComponent("analysis.json"))
        }
        return record
    }
    private func flushTail() {
        let seconds = Double(state.buffer.count) / 16_000
        analyzer.appendTail(seconds: seconds); state.elapsed += seconds; state.audioElapsed += seconds; state.buffer.removeAll()
    }
    private func temporary(_ number: Int) -> URL { store.directory(record.id).appendingPathComponent("tmp/seg-\(number).m4a") }
    private func recordError(_ message: String) { record.diagnostics.clipErrors.append(message) }
    private func fileOperation(_ action: () throws -> Void) throws { try action() }
    private func makeWriter(_ url: URL) throws -> AVAudioFile {
        try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000], commonFormat: .pcmFormatFloat32, interleaved: false)
    }
    private func reconcileFiles(_ candidates: [RetainedSegment]) throws {
        let dir = store.directory(record.id)
        let desired = Set(candidates.map { $0.segmentNumbers.map(String.init).joined(separator: "-") })
        let old = record.clips
        // Evict first so producing a replacement cannot exceed the bound transiently.
        for clip in old where !desired.contains(clip.id) {
            let url = dir.appendingPathComponent("clips/\(clip.fileName)")
            if FileManager.default.fileExists(atPath: url.path) { try fileOperation { try FileManager.default.removeItem(at: url) } }
        }
        var clips: [ClipRecord] = []
        for candidate in candidates {
            do {
            let id = candidate.segmentNumbers.map(String.init).joined(separator: "-")
            if var existing = old.first(where: { $0.id == id }) {
                guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("clips/\(existing.fileName)").path) else { throw CocoaError(.fileReadNoSuchFile) }
                existing.reason = candidate.reason; clips.append(existing); continue
            }
            // The currently open source file is not complete. Archive on closure instead.
            if writer != nil && candidate.segmentNumbers.contains(segment) { continue }
            // A nominated tail pair may include a whole interrupted segment.
            // Such a segment has no audio; retain the available side without inventing PCM.
            let sources = candidate.segmentNumbers.filter { !emptyGapSegments.contains($0) }.map(temporary)
            guard sources.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else { throw CocoaError(.fileReadNoSuchFile) }
            let name = "clip-\(id).m4a"
            let destination = dir.appendingPathComponent("clips/\(name)")
            do {
                var archive: AVAudioFile? = try makeWriter(destination)
                for source in sources {
                    let file = try AVAudioFile(forReading: source)
                    guard let pcm = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192) else { throw CocoaError(.fileReadUnknown) }
                    while file.framePosition < file.length {
                        try file.read(into: pcm)
                        if pcm.frameLength > 0 { try archive!.write(from: pcm) }
                    }
                }
                archive = nil
            } catch {
                try? FileManager.default.removeItem(at: destination); throw error
            }
            clips.append(.init(id: id, segmentNumbers: candidate.segmentNumbers, reason: candidate.reason, fileName: name))
            } catch {
                recordError("candidate \(candidate.segmentNumbers): \(error)")
                if strictFileErrors { throw error }
            }
        }
        record.clips = clips
    }
}
