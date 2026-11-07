import Foundation
import XCTest
import SnoreCore
@testable import SnoreLog

final class DisplayFormatTests: XCTestCase {
    func testCompactDurations() {
        for (seconds, expected) in [(0.0,"0 秒"),(24,"24 秒"),(1610,"26 分 50 秒"),(60,"1 分"),(3600,"1 小时"),(5425,"1 小时 30 分"),(-5,"0 秒")] {
            XCTAssertEqual(DisplayFormat.duration(seconds), expected)
        }
    }
    func testHugeFiniteDurationDoesNotOverflow() {
        XCTAssertFalse(DisplayFormat.duration(Double.greatestFiniteMagnitude).isEmpty)
        XCTAssertTrue(DisplayFormat.duration(Double.greatestFiniteMagnitude).contains("小时"))
    }
    func testDemoIsLocal2330AcrossTimeZones() throws {
        for zone in ["Asia/Shanghai", "America/Los_Angeles", "UTC"] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try XCTUnwrap(TimeZone(identifier: zone))
            let date = DemoRunner.startDate(calendar: calendar)
            let parts = calendar.dateComponents([.year,.month,.day,.hour,.minute], from: date)
            XCTAssertEqual(parts.year,2026); XCTAssertEqual(parts.month,11); XCTAssertEqual(parts.day,5)
            XCTAssertEqual(parts.hour,23); XCTAssertEqual(parts.minute,30)
            XCTAssertEqual(DisplayFormat.clock(date,calendar: calendar), "23:30")
            XCTAssertEqual(DisplayFormat.nightDate(date,calendar: calendar), "11 月 5 日 周四")
        }
    }
    func testHalfHourTicksCrossMidnightUsingClockLabels() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let start = DemoRunner.startDate(calendar: calendar)
        let ticks = DisplayFormat.halfHourTicks(start: start, end: start.addingTimeInterval(5400), calendar: calendar)
        XCTAssertEqual(ticks.map { DisplayFormat.clock($0,calendar: calendar) },["23:30","00:00","00:30","01:00"])
        XCTAssertEqual(DisplayFormat.halfHourTicks(start: start.addingTimeInterval(60), end: start.addingTimeInterval(1800), calendar: calendar).count,1)
        XCTAssertTrue(DisplayFormat.halfHourTicks(start: start, end: start.addingTimeInterval(-1)).isEmpty)
    }
    func testClipsChronologicalAndReasonNumbersComeFromReport() throws {
        var report = NightAnalyzer(startDate: Date(), classifier: Silent()).finish()
        report.pauses = try JSONDecoder().decode([SuspectedPause].self, from: Data("""
        [{"start":61,"durationSec":22,"bucket":"20–30","recoveryType":"gasp"}]
        """.utf8))
        report.retained = [.init(segmentNumbers: [2], reason: .loud, score: 62)]
        let pause = ClipRecord(id:"pause",segmentNumbers:[0,1],reason:.pause,fileName:"pause.m4a")
        let loud = ClipRecord(id:"loud",segmentNumbers:[2],reason:.loud,fileName:"loud.m4a")
        let run = ClipRecord(id:"run",segmentNumbers:[4,3],reason:.longestRun,fileName:"run.m4a")
        let record = NightRecord(id:"night",startDate:DemoRunner.startDate(),report:report)
        XCTAssertEqual(DisplayFormat.sortedClips([run,loud,pause]).map(\.id),["pause","loud","run"])
        XCTAssertEqual(DisplayFormat.clipText(record:record,clip:pause),"23:31 · 疑似停顿 22 秒")
        XCTAssertEqual(DisplayFormat.clipText(record:record,clip:loud),"23:34 · 很响 约 62 dB")
        XCTAssertEqual(DisplayFormat.clipText(record:record,clip:run),"23:36 · 最长连续打呼的结尾")
        let legacy = NightRecord(id:"legacy",startDate:DemoRunner.startDate())
        XCTAssertEqual(DisplayFormat.clipText(record:legacy,clip:pause),"23:30 · 疑似停顿")
        XCTAssertEqual(DisplayFormat.clipText(record:legacy,clip:loud),"23:34 · 很响")
    }
    func testScrubRefreshAndBounds() {
        var position = ScrubPosition()
        position.seek(42, duration: 120)
        position.editing = true; position.refresh(1)
        XCTAssertEqual(position.seconds, 42)
        position.editing = false; position.refresh(43)
        XCTAssertEqual(position.seconds, 43)
        position.seek(-10, duration: 120); XCTAssertEqual(position.seconds, 0)
        position.seek(999, duration: 120); XCTAssertEqual(position.seconds, 120)
        XCTAssertEqual(ClipMarkers.time(42), "0:42")
        XCTAssertEqual(ClipMarkers.time(120), "2:00")
    }
    func testPauseMarkersAcrossMergedClipAndOutside() throws {
        var report = NightAnalyzer(startDate: Date(), classifier: Silent()).finish()
        report.pauses = try JSONDecoder().decode([SuspectedPause].self, from: Data("""
        [{"start":250,"durationSec":22,"bucket":"20–30","recoveryType":"gasp"}]
        """.utf8))
        let record = NightRecord(id: "markers", startDate: Date(), report: report)
        let merged = ClipRecord(id: "m", segmentNumbers: [1,2], reason: .pause, fileName: "m.m4a")
        XCTAssertEqual(ClipMarkers.pauseOffset(record: record, clip: merged, duration: 240), 130)
        XCTAssertNil(ClipMarkers.pauseOffset(record: record, clip: merged, duration: 120))
        let after = ClipRecord(id: "a", segmentNumbers: [3], reason: .pause, fileName: "a.m4a")
        XCTAssertNil(ClipMarkers.pauseOffset(record: record, clip: after, duration: 120))
    }
    private struct Silent: SnoreClassifier {
        func classify(samples:[Float],second:Int) throws -> FrameConfidence { .init(snoring:0) }
    }
}
