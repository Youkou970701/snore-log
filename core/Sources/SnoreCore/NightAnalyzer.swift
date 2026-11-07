import Foundation

public enum AnalysisError: Error { case invalidConfiguration, nonFiniteSample, alreadyFinished }

public final class NightAnalyzer {
    public let config: AnalyzerConfig
    public let startDate: Date
    public private(set) var latestDb: Double?
    private var classifierCalls = 0
    private var classifierElapsedMs = 0.0
    public var classifierAverageMs: Double { classifierCalls == 0 ? 0 : classifierElapsedMs / Double(classifierCalls) }
    private let classifier: any SnoreClassifier
    private var buffer: [Float] = []
    private var elapsed = 0.0
    private var audioElapsed = 0.0
    private var gaps = 0.0
    private var analyzed = 0.0
    private var alarm = false
    private var cached: NightReport?
    private struct Frame: Codable { var time: Double; var db: Double; var snore: Bool }
    private var noise: [Frame] = []
    private var recent: [Frame] = []
    private var runFrames: [Frame] = []
    private var runs: [SnoreRun] = []
    private var episodes: [TimeSpan] = []
    private var episodeCut = false
    private var interruptions: [TimeSpan] = []
    private var longestRetainedRunSec = 0.0
    private var snoreVolumes: [Double] = []
    private var pauses: [SuspectedPause] = []
    private var envelope: [Float] = []
    private var minutes: [Int: MinuteCell] = [:]
    private struct Quiet: Codable { var start: Double; var count: Int; var baseline: Double?; var ended: Double? }
    private var quiet: Quiet?
    private var awaitingRecovery: [Quiet] = []
    private var pool: RetentionPool
    private var activeSegment: Int?
    private var activeVolumes: [Double] = []

    public init(config: AnalyzerConfig = AnalyzerConfig(), startDate: Date, classifier: (any SnoreClassifier)? = nil) {
        self.config = config; self.startDate = startDate
        self.classifier = classifier ?? AppleSnoreClassifier()
        self.pool = RetentionPool(limit: config.retentionLimit)
    }
    public var retention: [RetainedSegment] { pool.segments }
    public func append(_ samples: [Float]) throws {
        guard cached == nil else { throw AnalysisError.alreadyFinished }
        guard config.sampleRate == 16_000, config.frameSec == 1, config.segmentSec > 0,
              config.noiseWindowSec > 0, config.startDelaySec.isFinite, config.startDelaySec >= 0,
              config.calibrationOffsetDb.isFinite else { throw AnalysisError.invalidConfiguration }
        guard samples.allSatisfy({ $0.isFinite }) else { throw AnalysisError.nonFiniteSample }
        // A fixed frame boundary, independent of append call boundaries.
        var offset = 0
        while offset < samples.count {
            let take = min(config.sampleRate - buffer.count, samples.count - offset)
            buffer.append(contentsOf: samples[offset..<(offset + take)])
            offset += take
            if buffer.count == config.sampleRate {
                try process(buffer, at: elapsed)
                elapsed += 1
                audioElapsed += 1
                buffer.removeAll(keepingCapacity: true)
            }
        }
    }
    /// A gap ends the current evidence chain; incomplete PCM cannot straddle missing audio.
    public func markGap(seconds: Double) {
        guard cached == nil, seconds.isFinite, seconds > 0 else { return }
        flushPartial()
        closeRun(); quiet = nil; awaitingRecovery.removeAll(); recent.removeAll()
        let end = elapsed + seconds
        interruptions.append(.init(start: elapsed, end: end, durationSec: seconds))
        episodeCut = true
        markTimeline(from: elapsed, to: end, gap: true)
        elapsed = end; gaps += seconds
    }
    public func markAlarm() {
        guard cached == nil else { return }
        flushPartial(); closeRun(); quiet = nil; awaitingRecovery.removeAll(); episodeCut = true; alarm = true
    }
    private func flushPartial() {
        // R1 uses complete one-second frames. Partial tails count as recorded time only.
        let duration = Double(buffer.count) / Double(config.sampleRate)
        elapsed += duration
        audioElapsed += duration
        buffer.removeAll(keepingCapacity: true)
    }
    private func process(_ samples: [Float], at time: Double) throws {
        let energy = samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count)
        let db = 10 * log10(max(energy, 1e-16)) + config.calibrationOffsetDb
        let confidence: FrameConfidence
        if !alarm, time >= config.startDelaySec {
            let started = DispatchTime.now().uptimeNanoseconds
            confidence = try classifier.classify(samples: samples, second: Int(audioElapsed.rounded(.down)))
            classifierElapsedMs += Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            classifierCalls += 1
        } else { confidence = .init(snoring: 0) }
        processFrame(db: db, confidence: confidence, at: time)
    }
    /// Replay recorded volume and offline confidence without changing rule thresholds.
    public func appendFrame(db: Double, confidence: FrameConfidence) {
        processFrame(db: db, confidence: confidence, at: elapsed)
        elapsed += 1; audioElapsed += 1
    }
    /// Account for a partial recording tail without creating a complete analysis frame.
    public func appendTail(seconds: Double) { elapsed += seconds; audioElapsed += seconds }
    private func processFrame(db: Double, confidence: FrameConfidence, at time: Double) {
        latestDb = db
        setEnvelope(at: time, db: db)
        updateMinute(at: time, db: db)
        noise.removeAll { $0.time <= time - config.noiseWindowSec }
        noise.append(Frame(time: time, db: db, snore: false))
        let floor = percentile(noise.map(\.db), config.noisePercentile)
        guard !alarm, time >= config.startDelaySec else { return }
        let isSnore = confidence.snoring >= config.snoringConfidence && db >= floor + config.snoreAboveNoiseDb
        let isQuiet = db < floor + config.quietAboveNoiseDb && confidence.snoring < config.snoringConfidence && confidence.breathing < config.breathingConfidence
        analyzed += 1
        recent.removeAll { $0.time < time - config.pauseHistorySec }
        let segment = Int(time / config.segmentSec)
        if segment != activeSegment {
            commitActive(); activeSegment = segment
        }
        if isQuiet {
            if quiet == nil {
                let prior = recent.filter(\.snore)
                quiet = Quiet(start: time, count: 0,
                              baseline: prior.count >= config.pauseMinimumSnoreFrames ? percentile(prior.map(\.db), 0.5) : nil)
            }
            quiet?.count += 1
        } else if var candidate = quiet {
            candidate.ended = time
            if candidate.baseline != nil, Double(candidate.count) >= config.pauseMinimumSec,
               Double(candidate.count) <= config.pauseMaximumSec {
                awaitingRecovery.append(candidate)
            }
            quiet = nil
        }
        var pending: [Quiet] = []
        for candidate in awaitingRecovery {
            guard let ended = candidate.ended, let baseline = candidate.baseline,
                  time - ended < config.recoveryWindowSec else { continue }
            if db >= baseline + config.gaspAboveMedianDb || isSnore {
                let duration = Double(candidate.count)
                let bucket: PauseBucket = duration >= config.pauseBucket30Sec ? .thirtyOrMore : duration >= config.pauseBucket20Sec ? .twentyToThirty : .tenToTwenty
                pauses.append(.init(start: candidate.start, durationSec: duration, bucket: bucket,
                                    recoveryType: db >= baseline + config.gaspAboveMedianDb ? .gasp : .resumeSnore))
                markPause(from: candidate.start, to: ended)
                let first = Int(candidate.start / config.segmentSec)
                let last = Int(time / config.segmentSec)
                pool.offer(.init(segmentNumbers: Array(first...last), reason: .pause, score: duration))
            } else { pending.append(candidate) }
        }
        awaitingRecovery = pending
        let frame = Frame(time: time, db: db, snore: isSnore)
        if isSnore {
            if let last = episodes.last, !episodeCut, time - last.end <= 30 {
                episodes[episodes.count - 1] = .init(start: last.start, end: time, durationSec: time - last.start + 1)
            } else {
                episodes.append(.init(start: time, end: time, durationSec: 1))
            }
            episodeCut = false
            if let last = runFrames.last, time - last.time > config.runGapSec { closeRun() }
            runFrames.append(frame); snoreVolumes.append(db); activeVolumes.append(db)
            // Commit rolling nominations so an evicted old file cannot reappear
            // when the next getter takes a different temporary snapshot.
            pool.offer(.init(segmentNumbers: [segment], reason: .loud,
                             score: percentile(activeVolumes, config.volumeP95)))
            var cell = minutes[Int(time / 60)]!; cell.snoreSec += 1; minutes[cell.minute] = cell
        } else if let last = runFrames.last, time - last.time > config.runGapSec { closeRun() }
        recent.append(frame)
    }
    private func commitActive() {
        if let segment = activeSegment, !activeVolumes.isEmpty {
            pool.offer(.init(segmentNumbers: [segment], reason: .loud, score: percentile(activeVolumes, config.volumeP95)))
        }
        activeVolumes.removeAll(keepingCapacity: true)
    }
    private func closeRun() {
        guard let first = runFrames.first, let last = runFrames.last else { return }
        runs.append(.init(start: first.time, end: last.time + 1,
                          medianDb: percentile(runFrames.map(\.db), 0.5), p95Db: percentile(runFrames.map(\.db), config.volumeP95)))
        let duration = last.time + 1 - first.time
        if duration > longestRetainedRunSec {
            longestRetainedRunSec = duration
            pool.offer(runCandidate(start: first.time, end: last.time + 1))
        }
        runFrames.removeAll(keepingCapacity: true)
    }
    private func runCandidate(start: Double, end: Double) -> RetainedSegment {
        let last = Int(end.nextDown / config.segmentSec)
        // Nominate only the tail, still available in the recorder's rolling window.
        return .init(segmentNumbers: last == 0 ? [last] : [last - 1, last],
                     reason: .longestRun, score: end - start)
    }
    private func setEnvelope(at time: Double, db: Double) {
        let i = Int(time)
        if envelope.count <= i { envelope.append(contentsOf: repeatElement(Float(config.calibrationOffsetDb - 160), count: i + 1 - envelope.count)) }
        envelope[i] = Float(db)
    }
    private func updateMinute(at time: Double, db: Double) {
        let index = Int(time / 60)
        var cell = minutes[index] ?? .init(minute: index, snoreSec: 0, maxDb: db, hasPause: false, isGap: false)
        cell.maxDb = max(cell.maxDb, db); minutes[index] = cell
    }
    private func markTimeline(from start: Double, to end: Double, gap: Bool) {
        guard end > start else { return }
        for i in Int(start / 60)...Int((end.nextDown) / 60) {
            var cell = minutes[i] ?? .init(minute: i, snoreSec: 0, maxDb: config.calibrationOffsetDb - 160, hasPause: false, isGap: false)
            cell.isGap = cell.isGap || gap; minutes[i] = cell
        }
        if gap { setEnvelope(at: end.nextDown, db: config.calibrationOffsetDb - 160) }
    }
    private func markPause(from start: Double, to end: Double) {
        guard end > start else { return }
        for i in Int(start / 60)...Int(end.nextDown / 60) {
            if var cell = minutes[i] { cell.hasPause = true; minutes[i] = cell }
        }
    }
    public func finish() -> NightReport {
        if let cached { return cached }
        flushPartial(); closeRun(); commitActive(); activeSegment = nil
        let report = buildReport(reportRuns: runs, recorded: elapsed, retained: pool.segments)
        cached = report; return report
    }
    /// A read-only snapshot: incomplete PCM remains buffered and no retention event is nominated.
    public func currentReport() -> NightReport {
        if let cached { return cached }
        var reportRuns = runs
        if let first = runFrames.first, let last = runFrames.last {
            reportRuns.append(.init(start: first.time, end: last.time + 1,
                                    medianDb: percentile(runFrames.map(\.db), 0.5),
                                    p95Db: percentile(runFrames.map(\.db), config.volumeP95)))
        }
        return buildReport(reportRuns: reportRuns,
                           recorded: elapsed + Double(buffer.count) / Double(config.sampleRate),
                           retained: retention)
    }
    private func buildReport(reportRuns: [SnoreRun], recorded: Double, retained: [RetainedSegment]) -> NightReport {
        let longest = reportRuns.max { ($0.end - $0.start) < ($1.end - $1.start) }
        let longestSpan = longest.map { TimeSpan(start: $0.start, end: $0.end, durationSec: $0.end - $0.start) }
        var longestGap: TimeSpan?
        for (a, b) in zip(reportRuns, reportRuns.dropFirst()) {
            let span = TimeSpan(start: a.end, end: b.start, durationSec: b.start - a.end)
            if span.durationSec > (longestGap?.durationSec ?? 0) { longestGap = span }
        }
        var longestEpisodeGap: TimeSpan?
        for (a, b) in zip(episodes, episodes.dropFirst()) {
            guard !interruptions.contains(where: { $0.start < b.start && $0.end > a.end }) else { continue }
            let span = TimeSpan(start: a.end + 1, end: b.start - 1, durationSec: b.start - a.end - 1)
            if span.durationSec > (longestEpisodeGap?.durationSec ?? 0) { longestEpisodeGap = span }
        }
        let perHour = analyzed > 0 ? Double(pauses.count) * 3600 / analyzed : 0
        let longestPause = pauses.map(\.durationSec).max() ?? 0
        let report = NightReport(recordedSec: recorded, gapSec: gaps, analyzedSec: analyzed,
                                 snoreSec: Double(snoreVolumes.count), snoreRatio: analyzed > 0 ? Double(snoreVolumes.count) / analyzed : 0,
                                 snoreRuns: reportRuns, longestSnoreRun: longestSpan, longestQuietGap: longestGap,
                                 snoreEpisodes: episodes, snoreEpisodeSec: episodes.reduce(0) { $0 + $1.durationSec },
                                 longestSnoreEpisode: episodes.max { $0.durationSec < $1.durationSec }, longestEpisodeGap: longestEpisodeGap,
                                 pauses: pauses, pausesPerHour: perHour, longestPauseSec: longestPause,
                                 snoreMedianDb: snoreVolumes.isEmpty ? nil : percentile(snoreVolumes, 0.5),
                                 snoreP95Db: snoreVolumes.isEmpty ? nil : percentile(snoreVolumes, config.volumeP95),
                                 envelope: envelope, minuteGrid: minutes.values.sorted { $0.minute < $1.minute },
                                 healthNotice: perHour >= config.noticePausesPerHour || longestPause >= config.noticeLongPauseSec,
                                 retained: retained)
        return report
    }

    private struct Checkpoint: Codable {
        var buffer: [Float]
        var elapsed: Double
        var audioElapsed: Double
        var gaps: Double
        var analyzed: Double
        var alarm: Bool
        var cached: NightReport?
        var noise: [Frame]
        var recent: [Frame]
        var runFrames: [Frame]
        var runs: [SnoreRun]
        var episodes: [TimeSpan]?
        var episodeCut: Bool?
        var interruptions: [TimeSpan]?
        var longestRetainedRunSec: Double
        var snoreVolumes: [Double]
        var pauses: [SuspectedPause]
        var envelope: [Float]
        var minutes: [Int: MinuteCell]
        var quiet: Quiet?
        var awaitingRecovery: [Quiet]
        var pool: RetentionPool
        var activeSegment: Int?
        var activeVolumes: [Double]
        var latestDb: Double?
        var classifierCalls: Int
        var classifierElapsedMs: Double
    }
    public func checkpoint() throws -> Data {
        try JSONEncoder().encode(Checkpoint(buffer: buffer, elapsed: elapsed, audioElapsed: audioElapsed, gaps: gaps, analyzed: analyzed, alarm: alarm, cached: cached, noise: noise, recent: recent, runFrames: runFrames, runs: runs, episodes: episodes, episodeCut: episodeCut, interruptions: interruptions, longestRetainedRunSec: longestRetainedRunSec, snoreVolumes: snoreVolumes, pauses: pauses, envelope: envelope, minutes: minutes, quiet: quiet, awaitingRecovery: awaitingRecovery, pool: pool, activeSegment: activeSegment, activeVolumes: activeVolumes, latestDb: latestDb, classifierCalls: classifierCalls, classifierElapsedMs: classifierElapsedMs))
    }
    public func restoreCheckpoint(_ data: Data) throws {
        let state = try JSONDecoder().decode(Checkpoint.self, from: data)
        buffer = state.buffer
        elapsed = state.elapsed
        audioElapsed = state.audioElapsed
        gaps = state.gaps
        analyzed = state.analyzed
        alarm = state.alarm
        cached = state.cached
        noise = state.noise
        recent = state.recent
        runFrames = state.runFrames
        runs = state.runs
        if let savedEpisodes = state.episodes {
            episodes = savedEpisodes
            episodeCut = state.episodeCut ?? true
            interruptions = state.interruptions ?? []
        } else {
            var oldRuns = state.runs
            if let first = state.runFrames.first, let last = state.runFrames.last {
                oldRuns.append(.init(start: first.time, end: last.time + 1, medianDb: 0, p95Db: 0))
            }
            episodes = legacyEpisodes(runs: oldRuns, minutes: Array(state.minutes.values))
            interruptions = state.interruptions ?? state.minutes.values.filter(\.isGap).map {
                .init(start: Double($0.minute * 60), end: Double(($0.minute + 1) * 60), durationSec: 60)
            }
            episodeCut = state.alarm || interruptions.contains { $0.start <= state.elapsed && $0.end >= (episodes.last?.end ?? 0) }
        }
        longestRetainedRunSec = state.longestRetainedRunSec
        snoreVolumes = state.snoreVolumes
        pauses = state.pauses
        envelope = state.envelope
        minutes = state.minutes
        quiet = state.quiet
        awaitingRecovery = state.awaitingRecovery
        pool = state.pool
        activeSegment = state.activeSegment
        activeVolumes = state.activeVolumes
        latestDb = state.latestDb
        classifierCalls = state.classifierCalls
        classifierElapsedMs = state.classifierElapsedMs
    }
}
