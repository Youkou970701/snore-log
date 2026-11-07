import Foundation
import SnoreCore

/// Presentation only: report values and retention ranking remain unchanged.
enum DisplayFormat {
    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0 秒" }
        let value = Int(min(seconds, Double(Int.max / 2)))
        let hours = value / 3600, minutes = value % 3600 / 60, remainder = value % 60
        if hours > 0 { return minutes > 0 ? "\(hours) 小时 \(minutes) 分" : "\(hours) 小时" }
        if minutes > 0 { return remainder > 0 ? "\(minutes) 分 \(remainder) 秒" : "\(minutes) 分" }
        return "\(remainder) 秒"
    }
    static func clock(_ date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
    static func nightDate(_ date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "M 月 d 日 EEE"
        return formatter.string(from: date)
    }
    static func halfHourTicks(start: Date, end: Date, calendar: Calendar = .current) -> [Date] {
        guard end >= start, var tick = calendar.dateInterval(of: .hour, for: start)?.start else { return [] }
        while tick < start {
            guard let next = calendar.date(byAdding: .minute, value: 30, to: tick), next > tick else { return [] }
            tick = next
        }
        var values: [Date] = []
        while tick <= end {
            values.append(tick)
            guard let next = calendar.date(byAdding: .minute, value: 30, to: tick), next > tick else { break }
            tick = next
        }
        return values
    }
    static func sortedClips(_ clips: [ClipRecord]) -> [ClipRecord] {
        clips.sorted {
            let a = $0.segmentNumbers.min() ?? Int.max, b = $1.segmentNumbers.min() ?? Int.max
            return a == b ? $0.id < $1.id : a < b
        }
    }
    static func clipText(record: NightRecord, clip: ClipRecord) -> String {
        let start = Double(clip.segmentNumbers.min() ?? 0) * 120
        var displayStart = start
        let detail: String
        switch clip.reason {
        case .pause:
            let events = record.report?.pauses.filter { pause in
                clip.segmentNumbers.contains { number in
                    pause.start < Double(number + 1) * 120 && pause.start + pause.durationSec >= Double(number) * 120
                }
            } ?? []
            if let event = events.max(by: { $0.durationSec < $1.durationSec }) {
                displayStart = event.start
                detail = "疑似停顿 \(Int(event.durationSec.rounded())) 秒"
            } else { detail = "疑似停顿" }
        case .loud:
            if let score = record.report?.retained.first(where: { $0.segmentNumbers.sorted() == clip.segmentNumbers.sorted() })?.score, score.isFinite {
                detail = String(format: "很响 约 %.0f dB", score)
            } else { detail = "很响" }
        case .longestRun:
            detail = "最长连续打呼的结尾"
        }
        return "\(clock(record.startDate.addingTimeInterval(displayStart))) · \(detail)"
    }
}


enum ClipMarkers {
    static func pauseOffset(record: NightRecord, clip: ClipRecord, duration: Double) -> Double? {
        let start = Double(clip.segmentNumbers.min() ?? 0) * 120
        return record.report?.pauses.filter { $0.start >= start && $0.start < start + duration }
            .max(by: { $0.durationSec < $1.durationSec }).map { $0.start - start }
    }
    static func time(_ seconds: Double) -> String {
        let value = Int(max(0, seconds.isFinite ? seconds : 0))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}
struct ScrubPosition {
    var seconds = 0.0
    var editing = false
    mutating func refresh(_ value: Double) { if !editing { seconds = value } }
    mutating func seek(_ value: Double, duration: Double) { seconds = min(max(0, duration), max(0, value)) }
}
