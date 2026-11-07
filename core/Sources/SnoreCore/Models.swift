import Foundation

public struct AnalyzerConfig: Codable, Sendable {
    public var sampleRate = 16_000
    public var frameSec = 1.0
    public var calibrationOffsetDb = 90.0
    public var startDelaySec = 0.0
    public var noiseWindowSec = 300.0
    public var noisePercentile = 0.10
    public var snoringConfidence = 0.5
    // R6 does not specify a separate confidence threshold; use the same class threshold.
    public var breathingConfidence = 0.5
    public var snoreAboveNoiseDb = 6.0
    public var runGapSec = 8.0
    public var pauseHistorySec = 60.0
    public var pauseMinimumSnoreFrames = 5
    public var quietAboveNoiseDb = 3.0
    public var pauseMinimumSec = 10.0
    public var pauseMaximumSec = 90.0
    public var recoveryWindowSec = 5.0
    public var gaspAboveMedianDb = 6.0
    public var pauseBucket20Sec = 20.0
    public var pauseBucket30Sec = 30.0
    public var volumeP95 = 0.95
    public var segmentSec = 120.0
    public var retentionLimit = 12
    public var noticePausesPerHour = 5.0
    public var noticeLongPauseSec = 30.0
    public init() {}
}

public struct SnoreRun: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var medianDb: Double
    public var p95Db: Double
}
public struct TimeSpan: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var durationSec: Double
}
public enum PauseBucket: String, Codable, Sendable { case tenToTwenty = "10–20", twentyToThirty = "20–30", thirtyOrMore = ">=30" }
public enum RecoveryType: String, Codable, Sendable { case gasp, resumeSnore }
public struct SuspectedPause: Codable, Equatable, Sendable {
    public var start: Double
    public var durationSec: Double
    public var bucket: PauseBucket
    public var recoveryType: RecoveryType
}
public struct MinuteCell: Codable, Equatable, Sendable {
    public var minute: Int
    public var snoreSec: Double
    public var maxDb: Double
    public var hasPause: Bool
    public var isGap: Bool
}
public enum RetentionReason: String, Codable, Sendable { case pause, loud, longestRun }
public struct RetainedSegment: Codable, Equatable, Sendable {
    public var segmentNumbers: [Int]
    public var reason: RetentionReason
    public var score: Double
    public init(segmentNumbers: [Int], reason: RetentionReason, score: Double) {
        self.segmentNumbers = segmentNumbers.sorted(); self.reason = reason; self.score = score
    }
}
public struct NightReport: Codable, Equatable, Sendable {
    public var recordedSec: Double
    public var gapSec: Double
    public var analyzedSec: Double
    public var snoreSec: Double
    public var snoreRatio: Double
    public var snoreRuns: [SnoreRun]
    public var longestSnoreRun: TimeSpan?
    public var longestQuietGap: TimeSpan?
    /// R11 endpoints are the inclusive first/last frame starts, as in the reference.
    public var snoreEpisodes: [TimeSpan]
    public var snoreEpisodeSec: Double
    public var longestSnoreEpisode: TimeSpan?
    public var longestEpisodeGap: TimeSpan?
    public var pauses: [SuspectedPause]
    public var pausesPerHour: Double
    public var longestPauseSec: Double
    public var snoreMedianDb: Double?
    public var snoreP95Db: Double?
    public var envelope: [Float]
    public var minuteGrid: [MinuteCell]
    public var healthNotice: Bool
    public var retained: [RetainedSegment]
}

func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let position = min(1, max(0, p)) * Double(sorted.count - 1)
    let low = Int(position), high = min(low + 1, sorted.count - 1)
    return sorted[low] + (sorted[high] - sorted[low]) * (position - Double(low))
}

/// Metadata only: the recording layer owns files and applies removals from this snapshot.
public struct RetentionPool: Codable {
    public let limit: Int
    public private(set) var segments: [RetainedSegment] = []
    public init(limit: Int = 12) { self.limit = max(0, limit) }
    public mutating func offer(_ candidate: RetainedSegment) {
        guard !candidate.segmentNumbers.isEmpty else { return }
        var item = candidate
        // A shared segment is owned by a single entry. Do not chain unrelated
        // boundary pairs into an unbounded clip covering the whole night.
        let matches = segments.filter { !Set($0.segmentNumbers).isDisjoint(with: candidate.segmentNumbers) }
        for old in matches {
            let union = Array(Set(item.segmentNumbers + old.segmentNumbers)).sorted()
            if union.count <= 2 {
                let stronger = Self.stronger(old, item) ? old : item
                item = .init(segmentNumbers: union, reason: stronger.reason, score: stronger.score)
            } else if Self.stronger(old, item) { item = old }
        }
        segments.removeAll { old in matches.contains(old) }
        segments.append(item)
        segments.sort(by: Self.stronger)
        if segments.count > limit { segments.removeLast(segments.count - limit) }
    }
    private static func priority(_ reason: RetentionReason) -> Int {
        switch reason { case .pause: 3; case .loud: 2; case .longestRun: 1 }
    }
    private static func stronger(_ a: RetainedSegment, _ b: RetainedSegment) -> Bool {
        if priority(a.reason) != priority(b.reason) { return priority(a.reason) > priority(b.reason) }
        if a.score != b.score { return a.score > b.score }
        return a.segmentNumbers.lexicographicallyPrecedes(b.segmentNumbers)
    }
}

// Reports saved before R11 remain readable. Their R4 runs provide a provisional
// episode estimate; the app can rebuild exact episodes from persisted frames.
extension NightReport {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        recordedSec = try c.decode(Double.self, forKey: .recordedSec)
        gapSec = try c.decode(Double.self, forKey: .gapSec)
        analyzedSec = try c.decode(Double.self, forKey: .analyzedSec)
        snoreSec = try c.decode(Double.self, forKey: .snoreSec)
        snoreRatio = try c.decode(Double.self, forKey: .snoreRatio)
        snoreRuns = try c.decode([SnoreRun].self, forKey: .snoreRuns)
        longestSnoreRun = try c.decodeIfPresent(TimeSpan.self, forKey: .longestSnoreRun)
        longestQuietGap = try c.decodeIfPresent(TimeSpan.self, forKey: .longestQuietGap)
        pauses = try c.decode([SuspectedPause].self, forKey: .pauses)
        pausesPerHour = try c.decode(Double.self, forKey: .pausesPerHour)
        longestPauseSec = try c.decode(Double.self, forKey: .longestPauseSec)
        snoreMedianDb = try c.decodeIfPresent(Double.self, forKey: .snoreMedianDb)
        snoreP95Db = try c.decodeIfPresent(Double.self, forKey: .snoreP95Db)
        envelope = try c.decode([Float].self, forKey: .envelope)
        minuteGrid = try c.decode([MinuteCell].self, forKey: .minuteGrid)
        healthNotice = try c.decode(Bool.self, forKey: .healthNotice)
        retained = try c.decode([RetainedSegment].self, forKey: .retained)
        if let episodes = try c.decodeIfPresent([TimeSpan].self, forKey: .snoreEpisodes) {
            snoreEpisodes = episodes
        } else {
            snoreEpisodes = legacyEpisodes(runs: snoreRuns, minutes: minuteGrid)
        }
        snoreEpisodeSec = try c.decodeIfPresent(Double.self, forKey: .snoreEpisodeSec) ?? snoreEpisodes.reduce(0) { $0 + $1.durationSec }
        longestSnoreEpisode = try c.decodeIfPresent(TimeSpan.self, forKey: .longestSnoreEpisode) ?? snoreEpisodes.max { $0.durationSec < $1.durationSec }
        longestEpisodeGap = try c.decodeIfPresent(TimeSpan.self, forKey: .longestEpisodeGap)
        if !c.contains(.snoreEpisodes) {
            for (a, b) in zip(snoreEpisodes, snoreEpisodes.dropFirst()) {
                guard !minuteGrid.contains(where: { $0.isGap && Double($0.minute * 60) <= b.start && Double(($0.minute + 1) * 60) >= a.end }) else { continue }
                let gap = TimeSpan(start: a.end + 1, end: b.start - 1, durationSec: b.start - a.end - 1)
                if gap.durationSec > (longestEpisodeGap?.durationSec ?? 0) { longestEpisodeGap = gap }
            }
        }
    }
}

/// R4 retains every first/last snore frame, enough to merge into R11 in the
/// absence of interruptions. Old minute-level gaps deliberately err toward
/// splitting until an exact report can be rebuilt from source frames.
func legacyEpisodes(runs: [SnoreRun], minutes: [MinuteCell]) -> [TimeSpan] {
    var episodes: [TimeSpan] = []
    for run in runs {
        let lastStart = run.end - 1
        let crossesGap = minutes.contains {
            $0.isGap && Double($0.minute * 60) <= run.start && Double(($0.minute + 1) * 60) >= (episodes.last?.end ?? 0)
        }
        if let last = episodes.last, run.start - last.end <= 30, !crossesGap {
            episodes[episodes.count - 1] = .init(start: last.start, end: lastStart, durationSec: lastStart - last.start + 1)
        } else {
            episodes.append(.init(start: run.start, end: lastStart, durationSec: run.end - run.start))
        }
    }
    return episodes
}
