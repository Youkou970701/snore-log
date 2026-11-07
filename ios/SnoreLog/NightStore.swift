import Foundation
import SnoreCore

struct ClipRecord: Codable, Identifiable, Equatable {
    var id: String
    var segmentNumbers: [Int]
    var reason: RetentionReason
    var favorite = false
    var fileName: String
}
struct InterruptionEvent: Codable { var start: Date; var duration: Double; var recovery: String }
struct LifecycleEvent: Codable { var state: String; var at: Date }
struct ErrorTimes: Codable { var first: Date; var last: Date }
struct NightDiagnostics: Codable {
    var errorTimes: [String: ErrorTimes]? = [:]
    var interruptions: [InterruptionEvent] = []
    var droppedSec = 0.0
    var clipErrors: [String] = []
    var errorCounts: [String: Int] = [:]
    var peakFileCount = 0
    var classifierAverageMs = 0.0
    var lifecycle: [LifecycleEvent] = []
    var finalBattery: Double?
}
struct NightRecord: Codable, Identifiable {
    var id: String
    var startDate: Date
    var endDate: Date?
    var alarmDate: Date?
    var factors: [String] = []
    var delaySec: Double = 0
    var offsetDb: Double = 90
    var report: NightReport?
    var clips: [ClipRecord] = []
    var snapshotDate: Date?
    var unexpectedStop = false
    var unexpectedStopReason: String?
    var pendingAnalysis: Bool?
    var analysisProgress: Double?
    var diagnostics = NightDiagnostics()
}
extension NightRecord {
    enum CodingKeys: String, CodingKey { case pendingAnalysis, analysisProgress, id, startDate, endDate, alarmDate, factors, delaySec, offsetDb, report, clips, snapshotDate, unexpectedStop, unexpectedStopReason, diagnostics }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pendingAnalysis = try c.decodeIfPresent(Bool.self, forKey: .pendingAnalysis)
        analysisProgress = try c.decodeIfPresent(Double.self, forKey: .analysisProgress)
        id = try c.decode(String.self, forKey: .id); startDate = try c.decode(Date.self, forKey: .startDate)
        endDate = try c.decodeIfPresent(Date.self, forKey: .endDate); alarmDate = try c.decodeIfPresent(Date.self, forKey: .alarmDate)
        factors = try c.decodeIfPresent([String].self, forKey: .factors) ?? []
        delaySec = try c.decodeIfPresent(Double.self, forKey: .delaySec) ?? 0
        offsetDb = try c.decodeIfPresent(Double.self, forKey: .offsetDb) ?? 90
        report = try c.decodeIfPresent(NightReport.self, forKey: .report)
        clips = try c.decodeIfPresent([ClipRecord].self, forKey: .clips) ?? []
        snapshotDate = try c.decodeIfPresent(Date.self, forKey: .snapshotDate)
        unexpectedStop = try c.decodeIfPresent(Bool.self, forKey: .unexpectedStop) ?? false
        unexpectedStopReason = try c.decodeIfPresent(String.self, forKey: .unexpectedStopReason)
        if unexpectedStopReason == "App stopped before completing the night" {
            unexpectedStopReason = "App 在夜里被关闭了（可能被系统回收或被手动划掉）"
        }
        diagnostics = try c.decodeIfPresent(NightDiagnostics.self, forKey: .diagnostics) ?? NightDiagnostics()
    }
}
final class NightStore: @unchecked Sendable {
    let root: URL
    init(root: URL) { self.root = root }
    static var application: NightStore {
        NightStore(root: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("nights"))
    }
    func directory(_ id: String) -> URL { root.appendingPathComponent(id) }
    func save(_ record: NightRecord) throws {
        let dir = directory(record.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(record).write(to: dir.appendingPathComponent("night.json"), options: .atomic)
    }
    func loadAll() -> [NightRecord] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { try? JSONDecoder().decode(NightRecord.self, from: Data(contentsOf: $0.appendingPathComponent("night.json"))) }.sorted { $0.startDate > $1.startDate }
    }
    @discardableResult func recoverIncomplete() throws -> [NightRecord] {
        var recovered: [NightRecord] = []
        // A process kill bypasses the bulk classifier's defer; remove its private scratch PCM.
        for url in (try? FileManager.default.contentsOfDirectory(at: FileManager.default.temporaryDirectory, includingPropertiesForKeys: nil)) ?? []
        where url.lastPathComponent.hasPrefix("snore-analysis-") && url.pathExtension == "caf" {
            try FileManager.default.removeItem(at: url)
        }
        // Finish deletion after a crash between committing the final report and cleanup.
        for record in loadAll() where record.pendingAnalysis == false && record.report != nil {
            let tmp = directory(record.id).appendingPathComponent("tmp")
            if FileManager.default.fileExists(atPath: tmp.path) { try FileManager.default.removeItem(at: tmp) }
            let checkpoint = directory(record.id).appendingPathComponent("analysis.json")
            if FileManager.default.fileExists(atPath: checkpoint.path) { try FileManager.default.removeItem(at: checkpoint) }
        }
        for var record in loadAll() where record.endDate == nil {
            try RecordingPipeline.recoverJournal(record: &record, store: self)
            record.endDate = record.snapshotDate ?? record.startDate
            record.unexpectedStop = true
            record.unexpectedStopReason = record.unexpectedStopReason ?? "App 在夜里被关闭了（可能被系统回收或被手动划掉）"
            record.diagnostics.lifecycle.append(.init(state: "recovered", at: Date()))
            // A crash may leave unpublished clip files; only a committed snapshot owns files.
            let clipDir = directory(record.id).appendingPathComponent("clips")
            record.clips.removeAll { !FileManager.default.fileExists(atPath: clipDir.appendingPathComponent($0.fileName).path) }
            let ownedSegments = Set(record.clips.map { $0.segmentNumbers })
            record.report?.retained.removeAll { !ownedSegments.contains($0.segmentNumbers) }
            let owned = Set(record.clips.map(\.fileName))
            for url in (try? FileManager.default.contentsOfDirectory(at: clipDir, includingPropertiesForKeys: nil)) ?? [] where !owned.contains(url.lastPathComponent) {
                try FileManager.default.removeItem(at: url)
            }
            let tmp = directory(record.id).appendingPathComponent("tmp")
            if let files = try? FileManager.default.contentsOfDirectory(atPath: tmp.path), !files.isEmpty {
                record.pendingAnalysis = true
            } else if FileManager.default.fileExists(atPath: tmp.path) { try FileManager.default.removeItem(at: tmp) }
            try save(record); recovered.append(record)
        }
        return recovered
    }
    func cleanup(retentionDays: Int, now: Date = Date()) throws {
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86400)
        for var record in loadAll() where (record.endDate ?? record.startDate) < cutoff && record.endDate != nil && record.pendingAnalysis != true {
            for clip in record.clips where !clip.favorite {
                let url = directory(record.id).appendingPathComponent("clips").appendingPathComponent(clip.fileName)
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            }
            record.clips.removeAll { !$0.favorite }; try save(record)
        }
    }
}
struct InterruptionClock {
    private(set) var began: Date?
    mutating func begin(at date: Date) { if began == nil { began = date } }
    mutating func end(at date: Date) -> Double? {
        guard let began else { return nil }; self.began = nil
        return max(0, date.timeIntervalSince(began))
    }
}
enum SessionTiming {
    static func shouldStop(start: Date, alarm: Date?, now: Date) -> Bool {
        now.timeIntervalSince(start) >= 14 * 3600 || alarm.map { now.timeIntervalSince($0) >= 2 * 3600 } == true
    }
}
struct FactorStats {
    var hasCount: Int; var withoutCount: Int
    var hasRatio: Double?; var withoutRatio: Double?
    var hasPauses: Double?; var withoutPauses: Double?
    var hasP95: Double?; var withoutP95: Double?
    var insufficient: Bool { hasCount < 3 || withoutCount < 3 }
}
enum FactorComparison {
    static func compare(records: [NightRecord], factor: String) -> FactorStats {
        let a = records.filter { $0.factors.contains(factor) && $0.report != nil }
        let b = records.filter { !$0.factors.contains(factor) && $0.report != nil }
        func mean(_ list: [NightRecord], _ key: (NightReport) -> Double?) -> Double? {
            let values = list.compactMap { $0.report.flatMap(key) }
            return values.isEmpty ? nil : values.reduce(0,+) / Double(values.count)
        }
        return .init(hasCount: a.count, withoutCount: b.count, hasRatio: mean(a, { $0.episodeRatio }), withoutRatio: mean(b, { $0.episodeRatio }), hasPauses: mean(a, { $0.pausesPerHour }), withoutPauses: mean(b, { $0.pausesPerHour }), hasP95: mean(a, { $0.snoreP95Db }), withoutP95: mean(b, { $0.snoreP95Db }))
    }
}
enum AppCopy {
    static let healthNotice = "这晚检测到较多疑似呼吸停顿。手机录音可能误判，如果连续多晚都这样，或白天特别困、早上头痛，建议去医院睡眠科做睡眠监测。"
    static let factors = ["喝酒", "感冒鼻塞", "很累", "侧睡", "吃了宵夜", "戴了止鼾贴"]
}

// UI ratios use R11 episodes; R4 snoreRatio remains available in the core report.
extension NightReport {
    var episodeRatio: Double { analyzedSec > 0 ? snoreEpisodeSec / analyzedSec : 0 }
}
