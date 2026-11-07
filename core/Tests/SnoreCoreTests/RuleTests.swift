import Foundation
import Testing
@testable import SnoreCore

private struct ScriptClassifier: SnoreClassifier {
    var labels: [Int: FrameConfidence]
    func classify(samples: [Float], second: Int) throws -> FrameConfidence {
        labels[second] ?? FrameConfidence(snoring: 0, breathing: 0)
    }
}
private struct Script {
    var db: [Double]
    var labels: [Int: FrameConfidence] = [:]
    init(seconds: Int) { db = Array(repeating: 30, count: seconds) }
    mutating func snore(_ second: Int, db volume: Double = 60) {
        db[second] = volume; labels[second] = FrameConfidence(snoring: 0.9)
    }
    mutating func gasp(_ second: Int) { db[second] = 75 }
    func frame(_ second: Int) -> [Float] {
        // Equal positive/negative PCM has zero DC and the requested exact RMS.
        let amplitude = Float(pow(10, (db[second] - 90) / 20))
        return (0..<16_000).map { $0 % 2 == 0 ? amplitude : -amplitude }
    }
    func samples() -> [Float] { db.indices.flatMap(frame) }
    func analyzer(config: AnalyzerConfig = AnalyzerConfig()) -> NightAnalyzer {
        NightAnalyzer(config: config, startDate: Date(timeIntervalSince1970: 0), classifier: ScriptClassifier(labels: labels))
    }
    func report() throws -> NightReport {
        let analyzer = analyzer()
        for second in db.indices { try analyzer.append(frame(second)) }
        return analyzer.finish()
    }
}
private func eventScript(quietLength: Int = 15, recovery: Bool = true, seconds: Int = 250) -> Script {
    var script = Script(seconds: seconds)
    for t in stride(from: 10, through: 186, by: 4) { script.snore(t) }
    script.snore(189)
    if recovery {
        script.gasp(190 + quietLength)
        for t in stride(from: 191 + quietLength, to: min(seconds, 245), by: 4) { script.snore(t) }
    }
    return script
}

@Suite(.serialized)
struct RuleTests {
    @Test func thirtySecondSpacingMergesAndThirtyOneSplits() {
        let analyzer = NightAnalyzer(startDate: .distantPast)
        for t in 0..<110 {
            let snore = [10, 40, 71, 101].contains(t)
            analyzer.appendFrame(db: snore ? 60 : 30, confidence: .init(snoring: snore ? 0.9 : 0))
        }
        let report = analyzer.finish()
        #expect(report.snoreRuns.count == 4)
        #expect(report.snoreSec == 4)
        #expect(report.snoreEpisodes == [.init(start: 10, end: 40, durationSec: 31), .init(start: 71, end: 101, durationSec: 31)])
        #expect(report.snoreEpisodeSec == 62)
        #expect(report.longestEpisodeGap == .init(start: 41, end: 70, durationSec: 30))
    }
    @Test func interruptionSplitsEpisodesAndCannotBeLongestGap() throws {
        let analyzer = NightAnalyzer(startDate: .distantPast)
        for t in 0..<12 { analyzer.appendFrame(db: t == 10 ? 60 : 30, confidence: .init(snoring: t == 10 ? 0.9 : 0)) }
        analyzer.markGap(seconds: 2.5)
        analyzer.appendFrame(db: 60, confidence: .init(snoring: 0.9))
        let snapshot = analyzer.currentReport()
        #expect(snapshot.snoreEpisodes.count == 2)
        #expect(snapshot.snoreEpisodeSec == 2)
        #expect(snapshot.longestEpisodeGap == nil)
        let restored = NightAnalyzer(startDate: .distantPast)
        try restored.restoreCheckpoint(analyzer.checkpoint())
        for t in 0..<35 {
            let snore = t == 34
            for instance in [analyzer, restored] {
                instance.appendFrame(db: snore ? 60 : 30, confidence: .init(snoring: snore ? 0.9 : 0))
            }
        }
        #expect(restored.finish() == analyzer.finish())
        #expect(analyzer.finish().longestEpisodeGap?.durationSec == 34)
    }
    @Test func legacyCheckpointRetainsProcessedEpisodeFrames() throws {
        let source = NightAnalyzer(startDate: .distantPast)
        for t in 0..<45 {
            let snore = [10, 40].contains(t)
            source.appendFrame(db: snore ? 60 : 30, confidence: .init(snoring: snore ? 0.9 : 0))
        }
        var json = try #require(JSONSerialization.jsonObject(with: source.checkpoint()) as? [String: Any])
        for key in ["episodes", "episodeCut", "interruptions"] { json.removeValue(forKey: key) }
        let restored = NightAnalyzer(startDate: .distantPast)
        try restored.restoreCheckpoint(JSONSerialization.data(withJSONObject: json))
        #expect(restored.currentReport().snoreEpisodes == source.currentReport().snoreEpisodes)
        for instance in [source, restored] {
            for t in 45..<75 {
                instance.appendFrame(db: t == 70 ? 60 : 30, confidence: .init(snoring: t == 70 ? 0.9 : 0))
            }
        }
        #expect(restored.finish() == source.finish())
    }
    @Test func episodesIncludeSuspectedPauseWithoutChangingR4() throws {
        let report = try eventScript().report()
        #expect(report.pauses.first?.durationSec == 15)
        #expect(report.snoreRuns.count == 2)
        #expect(report.snoreEpisodes.count == 1)
        #expect(report.snoreEpisodes.first?.start == 10)
        #expect(report.snoreEpisodes.first?.end == 242)
        #expect(report.snoreEpisodeSec == 233)
    }
    @Test func oldReportDecodesAndConservativelyRespectsGapMinutes() throws {
        let analyzer = NightAnalyzer(startDate: .distantPast)
        for t in 0..<110 {
            let snore = [10, 40, 71, 101].contains(t)
            analyzer.appendFrame(db: snore ? 60 : 30, confidence: .init(snoring: snore ? 0.9 : 0))
        }
        let report = analyzer.finish()
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        for key in ["snoreEpisodes", "snoreEpisodeSec", "longestSnoreEpisode", "longestEpisodeGap"] { json.removeValue(forKey: key) }
        let data = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(NightReport.self, from: data)
        #expect(decoded.snoreEpisodes == report.snoreEpisodes)
        #expect(decoded.snoreEpisodeSec == report.snoreEpisodeSec)
        #expect(decoded.longestEpisodeGap == report.longestEpisodeGap)
        var minutes = try #require(json["minuteGrid"] as? [[String: Any]])
        minutes[0]["isGap"] = true
        json["minuteGrid"] = minutes
        let interrupted = try JSONDecoder().decode(NightReport.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(interrupted.snoreEpisodes.count == 3)
        #expect(interrupted.longestEpisodeGap == nil)
    }
    @Test func threeMinuteSnoringThenFifteenSecondPauseAndGasp() throws {
        let report = try eventScript().report()
        #expect(report.pauses.count == 1)
        #expect(report.pauses.first?.start == 190)
        #expect(report.pauses.first?.durationSec == 15)
        #expect(report.pauses.first?.bucket == .tenToTwenty)
        #expect(report.pauses.first?.recoveryType == .gasp)
        #expect(report.longestSnoreRun?.start == 10)
        #expect(report.longestSnoreRun?.end == 190)
    }
    @Test func silenceWithoutRecoveryIsNotAPause() throws {
        let report = try eventScript(recovery: false).report()
        #expect(report.pauses.isEmpty)
    }
    @Test func nineSecondQuietIsTooShort() throws {
        #expect(try eventScript(quietLength: 9).report().pauses.isEmpty)
    }
    @Test func eightSecondFrameSpacingMergesNineSplits() throws {
        var script = Script(seconds: 50)
        for t in [10, 18, 27] { script.snore(t) }
        let report = try script.report()
        #expect(report.snoreRuns.count == 2)
        #expect(report.snoreRuns.first?.start == 10)
        #expect(report.snoreRuns.first?.end == 19)
        #expect(report.longestQuietGap?.durationSec == 8)
    }
    @Test func fanFloorAdaptsWithinFiveMinutes() throws {
        var script = Script(seconds: 620)
        for t in 300..<620 { script.db[t] = 45 }
        // The same classifier-positive 49 dB sample passes the old floor, but
        // fails the adapted floor; unlabeled fan samples never count as snores.
        script.snore(305, db: 49); script.snore(605, db: 49)
        let report = try script.report()
        #expect(report.snoreSec == 1)
        #expect(report.snoreRuns.first?.start == 305)
    }
    @Test func wholeNightQuietHasZeroStatistics() throws {
        let report = try Script(seconds: 600).report()
        #expect(report.snoreSec == 0)
        #expect(report.snoreRatio == 0)
        #expect(report.snoreEpisodes.isEmpty)
        #expect(report.snoreEpisodeSec == 0)
        #expect(report.longestSnoreEpisode == nil)
        #expect(report.longestEpisodeGap == nil)
        #expect(report.pauses.isEmpty)
        #expect(!report.healthNotice)
        #expect(report.snoreMedianDb == nil)
        #expect(report.snoreP95Db == nil)
        #expect(report.longestSnoreRun == nil)
        #expect(report.longestQuietGap == nil)
        #expect(report.retained.isEmpty)
    }
    @Test func boundaryPauseReportsAreIdenticalForWhole120SevenAndFractionalChunks() throws {
        var script = Script(seconds: 260)
        for t in stride(from: 10, through: 114, by: 4) { script.snore(t) }
        script.gasp(130)
        for t in stride(from: 131, through: 251, by: 4) { script.snore(t) }
        var samples = script.samples()
        // An incomplete tail must also have append-independent behavior.
        samples.append(contentsOf: Array(repeating: 0.001, count: 351))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var reference: NightReport?
        var referenceJSON: Data?
        for chunk in [samples.count, 120 * 16_000, 7 * 16_000, 20_003] {
            let analyzer = script.analyzer()
            for start in stride(from: 0, to: samples.count, by: chunk) {
                try analyzer.append(Array(samples[start..<min(start + chunk, samples.count)]))
                #expect(analyzer.retention.count <= 12)
            }
            let report = analyzer.finish()
            #expect(report.pauses.count == 1)
            #expect(report.pauses.first?.start == 115)
            #expect(report.pauses.first?.durationSec == 15)
            #expect(report.retained.contains { $0.reason == .pause && $0.segmentNumbers == [0, 1] })
            let json = try encoder.encode(report)
            if let reference { #expect(report == reference); #expect(json == referenceJSON) }
            else { reference = report; referenceJSON = json }
            #expect(analyzer.finish() == report)
        }
    }
    @Test func retentionAlwaysBoundedPrioritizesPausesAndMergesBoundary() {
        var pool = RetentionPool()
        for i in 0..<20 {
            pool.offer(.init(segmentNumbers: [i], reason: .loud, score: Double(i)))
            #expect(pool.segments.count <= 12)
        }
        pool.offer(.init(segmentNumbers: [0, 1], reason: .pause, score: 15))
        #expect(pool.segments.count == 12)
        #expect(pool.segments.first?.reason == .pause)
        #expect(pool.segments.first?.segmentNumbers == [0, 1])
        pool.offer(.init(segmentNumbers: [1], reason: .loud, score: 999))
        #expect(pool.segments.filter { $0.segmentNumbers.contains(1) }.count == 1)
        #expect(pool.segments.first?.reason == .pause)
    }
    @Test func analyzerRetentionStaysBoundedAcrossTwentySegments() throws {
        var script = Script(seconds: 20 * 120)
        for segment in 0..<20 {
            script.snore(segment * 120 + 10, db: Double(55 + segment))
        }
        let analyzer = script.analyzer()
        for t in script.db.indices {
            try analyzer.append(script.frame(t))
            #expect(analyzer.retention.count <= 12)
        }
        #expect(analyzer.finish().retained.count == 12)
    }
    @Test func healthNoticeAtFivePerHourAndNotAtFour() throws {
        let five = try eventScript(seconds: 720).report()
        #expect(five.pausesPerHour == 5)
        #expect(five.healthNotice)
        let four = try eventScript(seconds: 900).report()
        #expect(four.pausesPerHour == 4)
        #expect(!four.healthNotice)
    }
    @Test(arguments: [20, 30]) func pauseBucketsAndLongPauseNotice(length: Int) throws {
        let report = try eventScript(quietLength: length, seconds: 900).report()
        #expect(report.pauses.first?.bucket == (length == 20 ? .twentyToThirty : .thirtyOrMore))
        #expect(report.healthNotice == (length == 30))
    }
    @Test func resumedSnoreQualifiesWithoutGasp() throws {
        var script = eventScript(recovery: false)
        script.snore(205)
        let report = try script.report()
        #expect(report.pauses.first?.recoveryType == .resumeSnore)
        #expect(report.pauses.first?.durationSec == 15)
    }
    @Test func breathingDisqualifiesOtherwiseQuietFrames() throws {
        var script = eventScript()
        for t in 190..<205 { script.labels[t] = FrameConfidence(snoring: 0, breathing: 0.9) }
        #expect(try script.report().pauses.isEmpty)
    }
    @Test func alarmGapAndDelayExcludeTheirAudioFromDenominator() throws {
        var script = Script(seconds: 100)
        for t in [5, 25, 29, 33, 37, 41, 70, 74, 78] { script.snore(t) }
        var config = AnalyzerConfig(); config.startDelaySec = 20
        let analyzer = script.analyzer(config: config)
        for t in 0..<50 { try analyzer.append(script.frame(t)) }
        analyzer.markGap(seconds: 10)
        for t in 60..<70 { try analyzer.append(script.frame(t)) }
        analyzer.markAlarm()
        for t in 70..<100 { try analyzer.append(script.frame(t)) }
        let report = analyzer.finish()
        #expect(report.recordedSec == 100)
        #expect(report.gapSec == 10)
        #expect(report.analyzedSec == 40)
        #expect(report.snoreSec == 5)
        #expect(report.snoreRatio == 0.125)
        #expect(report.minuteGrid.contains { $0.isGap })
        #expect(report.snoreRuns.allSatisfy { $0.end <= 70 })
    }
    @Test func volumeStatisticsIgnoreUnclassifiedLoudImpulse() throws {
        var script = Script(seconds: 90)
        for t in [10, 14, 18, 22, 26] { script.snore(t, db: 60) }
        script.db[50] = 89
        let report = try script.report()
        #expect(abs((report.snoreMedianDb ?? 0) - 60) < 0.001)
        #expect(abs((report.snoreP95Db ?? 0) - 60) < 0.001)
        #expect(report.minuteGrid[0].maxDb > 88)
    }
    @Test(arguments: [90, 91]) func maximumQuietDuration(length: Int) throws {
        let report = try eventScript(quietLength: length, seconds: 400).report()
        #expect(report.pauses.count == (length == 90 ? 1 : 0))
        if length == 90 {
            #expect(report.pauses.first?.durationSec == 90)
            #expect(report.pauses.first?.recoveryType == .gasp)
        } else { #expect(!report.healthNotice) }
    }
    @Test func classifierSecondsExcludeGaps() throws {
        var script = Script(seconds: 40)
        script.snore(10); script.snore(20)
        let analyzer = script.analyzer()
        for t in 0..<15 { try analyzer.append(script.frame(t)) }
        analyzer.markGap(seconds: 60)
        for t in 15..<40 { try analyzer.append(script.frame(t)) }
        let report = analyzer.finish()
        #expect(report.snoreSec == 2)
        #expect(report.snoreRuns.map(\.start) == [10, 80])
        #expect(report.recordedSec == 100)
        #expect(report.analyzedSec == 40)
    }
    @Test func newlyNominatedSegmentsStayInRollingWindow() throws {
        var script = Script(seconds: 1600)
        for t in stride(from: 10, through: 1502, by: 4) { script.snore(t, db: 55 + Double(t) / 1000) }
        let analyzer = script.analyzer()
        var previous: Set<Int> = []
        for t in script.db.indices {
            try analyzer.append(script.frame(t))
            let current = Set(analyzer.retention.flatMap(\.segmentNumbers))
            #expect(current.subtracting(previous).allSatisfy { $0 >= t / 120 - 2 }, "t=\(t), new=\(current.subtracting(previous))")
            previous = current
        }
        let final = analyzer.finish()
        #expect(Set(final.retained.flatMap(\.segmentNumbers)).subtracting(previous).allSatisfy { $0 >= 1599 / 120 - 2 })
        #expect(final.retained.contains { $0.segmentNumbers == [11, 12] })
    }
    @Test func currentReportDoesNotMutateStreamingState() throws {
        let script = eventScript(seconds: 400)
        let observed = script.analyzer()
        let reference = script.analyzer()
        for t in script.db.indices {
            let frame = script.frame(t)
            // Leave a fractional PCM tail in the buffer while taking snapshots.
            try observed.append(Array(frame.prefix(351)))
            let before = observed.retention
            let first = observed.currentReport()
            #expect(first == observed.currentReport())
            #expect(observed.retention == before)
            try observed.append(Array(frame.dropFirst(351)))
            try reference.append(frame)
        }
        #expect(observed.finish() == reference.finish())
        #expect(observed.currentReport() == observed.finish())
    }
    @Test func incompleteFinishAndInvalidSamplesAreSafe() throws {
        let script = Script(seconds: 2)
        let analyzer = script.analyzer()
        try analyzer.append(Array(repeating: 0, count: 8000))
        #expect(throws: AnalysisError.self) { try analyzer.append([Float.nan]) }
        let report = analyzer.finish()
        #expect(report.recordedSec == 0.5)
        #expect(report.analyzedSec == 0)
        #expect(throws: AnalysisError.self) { try analyzer.append([0]) }
    }
}
