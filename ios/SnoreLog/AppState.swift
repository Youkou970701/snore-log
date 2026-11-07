import Foundation
import SwiftUI
import AVFAudio
import UserNotifications

@MainActor final class AppState: ObservableObject {
    @Published var records: [NightRecord] = []
    @Published var active = false
    @Published var interrupted = false
    @Published var analysisProgress: Double?
    private var foreground = false
    private var analysisRunning = false
    @Published var currentDb: Float = 0
    @Published var elapsed = 0.0
    @Published var selected: NightRecord?
    @Published var error: String?
    @Published var alarmWarning = false
    @Published var microphoneAllowed = AVAudioApplication.shared.recordPermission == .granted
    @Published var alarmTime: Date
    @Published var snooze: Bool { didSet { UserDefaults.standard.set(snooze, forKey: "snooze") } }
    @Published var delay = 600.0
    @Published var factors: Set<String> = []
    @Published var offset: Double { didSet { UserDefaults.standard.set(offset, forKey: "offset") } }
    @Published var retentionDays: Int { didSet { UserDefaults.standard.set(retentionDays, forKey: "retentionDays") } }
    @Published var onboarded: Bool { didSet { UserDefaults.standard.set(onboarded, forKey: "onboarded") } }
    let alarms = AlarmService()
    let store = NightStore.application
    private var capture: CaptureService?
    private var player: AVAudioPlayer?
    @Published private(set) var playingClipID: String?
    @Published private(set) var preparingClipID: String?
    @Published private(set) var lastPlayedClipID: String?
    @Published private(set) var playbackProgress = 0.0
    @Published private(set) var playbackElapsed = 0.0
    @Published private(set) var playbackDuration = 0.0
    @Published private(set) var playbackGainDb = 0.0
    private var scrub = ScrubPosition()
    private var selectedPositionID: String?
    private var selectedPosition = 0.0
    func selectPosition(id: String, seconds: Double) {
        selectedPositionID = id; selectedPosition = max(0, seconds)
    }
    func setScrubbing(_ editing: Bool) { scrub.editing = editing }
    func seekPlayback(_ seconds: Double) {
        scrub.seek(seconds, duration: playbackDuration)
        player?.currentTime = scrub.seconds
        playbackElapsed = scrub.seconds
        playbackProgress = playbackDuration > 0 ? scrub.seconds / playbackDuration : 0
    }
    private var playbackDirectory: URL?
    private var playbackTask: Task<Void, Never>?
    private var playbackToken = UUID()
    var expiration: Date? { Provisioning.installedExpiration }
    var nextAlarm: Date {
        let components = Calendar.current.dateComponents([.hour, .minute], from: alarmTime)
        return Calendar.current.nextDate(after: Date(), matching: components, matchingPolicy: .nextTime) ?? alarmTime
    }
    init() {
        let defaults = UserDefaults.standard
        alarmTime = Date(timeIntervalSince1970: defaults.double(forKey: "alarmTime") == 0 ? Date().addingTimeInterval(8*3600).timeIntervalSince1970 : defaults.double(forKey: "alarmTime"))
        snooze = defaults.object(forKey: "snooze") == nil ? true : defaults.bool(forKey: "snooze")
        offset = defaults.object(forKey: "offset") == nil ? 90 : defaults.double(forKey: "offset")
        retentionDays = defaults.object(forKey: "retentionDays") == nil ? 14 : defaults.integer(forKey: "retentionDays")
        onboarded = defaults.bool(forKey: "onboarded")
        UIDevice.current.isBatteryMonitoringEnabled = true
        do { try store.recoverIncomplete(); try store.cleanup(retentionDays: retentionDays) } catch { self.error = "读取或保存记录失败，请重试。"; NSLog("Night store: %@", String(describing: error)) }
        records = store.loadAll()
        Task { await alarms.scheduleExpirationReminder(expiration: expiration) }
    }
    func start(onlyRecording: Bool = false) async {
        guard !active, !analysisRunning else { return }
        stopPlayback()
        do {
            let capacity = try FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())[.systemFreeSize] as? NSNumber
            guard let capacity, capacity.int64Value >= 1_000_000_000 else {
                error = "剩余空间不足 1 GB，请先清理空间，再开始整夜录音。"; return
            }
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
            microphoneAllowed = await AVAudioApplication.requestRecordPermission()
            guard microphoneAllowed else { error = "麦克风未授权，请在系统设置中允许录音。"; return }
            let alarm = nextAlarm
            if !onlyRecording {
                do { alarmWarning = !(try await alarms.schedule(date: alarm, snooze: snooze)) }
                catch { alarmWarning = true; self.error = "闹钟设置失败，闹钟不会响；可选择只录音。"; recordDiagnostic(error) }
            } else { alarms.cancelAll(); alarmWarning = true }
            UserDefaults.standard.set(alarmTime.timeIntervalSince1970, forKey: "alarmTime")
            let date = Date()
            let formatter = DateFormatter(); formatter.dateFormat = "yyyyMMdd-HHmmss"
            let record = NightRecord(id: formatter.string(from: date), startDate: date, alarmDate: onlyRecording ? nil : alarm, factors: factors.sorted(), delaySec: delay, offsetDb: offset)
            let service = CaptureService()
            service.onUpdate = { [weak self] elapsed, db, interrupted in
                Task { @MainActor in self?.elapsed = elapsed; self?.currentDb = Float(db ?? 0); self?.interrupted = interrupted }
            }
            service.onFinish = { [weak self] result in Task { @MainActor in self?.complete(result) } }
            try service.start(record: record, store: store)
            capture = service; elapsed = 0; active = true; selected = nil
        } catch { alarms.cancelAll(); self.error = "录音启动失败，请检查麦克风权限和可用空间后重试。"; recordDiagnostic(error) }
    }
    func wake() { alarms.cancelAll(); capture?.finish() }
    private func complete(_ result: Result<NightRecord, Error>) {
        active = false; capture = nil; alarms.cancelAll()
        records = store.loadAll()
        switch result {
        case .success(let record):
            // A failed disk save must not hide the freshest in-memory partial report.
            records.removeAll { $0.id == record.id }; records.append(record)
            records.sort { $0.startDate > $1.startDate }; selected = record
        case .failure(let error): self.error = "录音已停止，保存记录失败，请重试。"; recordDiagnostic(error)
        }
        resumePendingAnalysis()
    }
    func favorite(record: NightRecord, clip: ClipRecord) {
        var edited = record
        if let index = edited.clips.firstIndex(where: { $0.id == clip.id }) { edited.clips[index].favorite.toggle() }
        do { try store.save(edited); records = store.loadAll(); if selected?.id == edited.id { selected = edited } } catch { self.error = "保存收藏失败，请重试。"; recordDiagnostic(error) }
    }
    func stopPlayback() {
        playbackToken = UUID()
        playbackTask?.cancel(); playbackTask = nil
        player?.stop(); player = nil
        playingClipID = nil; preparingClipID = nil
        if let playbackDirectory { try? FileManager.default.removeItem(at: playbackDirectory) }
        playbackDirectory = nil
        if !active { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
    }
    func play(_ record: NightRecord, _ clip: ClipRecord) {
        guard !active else { return }
        let id = "\(record.id)/\(clip.id)"
        let stopping = playingClipID == id || preparingClipID == id
        stopPlayback()
        if stopping { return }
        let initialPosition = selectedPositionID == id ? selectedPosition : 0
        selectedPositionID = nil; selectedPosition = 0
        let token = playbackToken
        let source = store.directory(record.id).appendingPathComponent("clips/\(clip.fileName)")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("snore-playback-" + UUID().uuidString)
        preparingClipID = id
        playbackTask = Task {
            do {
                let amplified = try await Task.detached(priority: .userInitiated) {
                    try ClipAmplifier.prepare(source: source, directory: directory)
                }.value
                guard !Task.isCancelled, token == playbackToken, !active else {
                    try? FileManager.default.removeItem(at: directory); return
                }
                playbackDirectory = directory
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
                try session.setActive(true)
                let audio = try AVAudioPlayer(contentsOf: amplified.url)
                player = audio
                audio.currentTime = min(max(0, audio.duration - 0.001), initialPosition)
                guard audio.prepareToPlay(), audio.play() else { throw CocoaError(.fileReadUnknown) }
                preparingClipID = nil; playingClipID = id; lastPlayedClipID = id
                playbackGainDb = amplified.gainDb; playbackDuration = audio.duration
                scrub = ScrubPosition(seconds: audio.currentTime)
                playbackElapsed = audio.currentTime; playbackProgress = audio.currentTime / max(0.001, audio.duration)
                while !Task.isCancelled, token == playbackToken, audio.isPlaying {
                    scrub.refresh(audio.currentTime)
                    if !scrub.editing {
                        playbackElapsed = scrub.seconds
                        playbackProgress = audio.duration > 0 ? scrub.seconds / audio.duration : 0
                    }
                    try await Task.sleep(for: .milliseconds(100))
                }
                if token == playbackToken {
                    playbackElapsed = audio.duration; playbackProgress = 1
                    stopPlayback()
                }
            } catch {
                try? FileManager.default.removeItem(at: directory)
                guard token == playbackToken else { return }
                stopPlayback()
                if !(error is CancellationError) { self.error = "片段播放失败，请稍后重试。"; recordDiagnostic(error) }
            }
        }
    }
    func setForeground(_ value: Bool) {
        AnalysisActivity.setEnabled(value)
        foreground = value
        if value { resumePendingAnalysis() }
    }
    func resumePendingAnalysis() {
        guard foreground, !active, !analysisRunning,
              let pending = records.first(where: { $0.pendingAnalysis == true }) else { return }
        analysisRunning = true
        analysisProgress = pending.analysisProgress ?? 0
        let store = self.store
        Task {
            var resumeAfterCancellation = false
            defer {
                analysisRunning = false; analysisProgress = nil
                if resumeAfterCancellation, foreground, !active { resumePendingAnalysis() }
            }
            do {
                let worker = try DeferredNightAnalysis(record: pending, store: store)
                while foreground, !active {
                    let record = try await Task.detached(priority: .userInitiated) { try worker.step() }.value
                    records.removeAll { $0.id == record.id }; records.append(record)
                    records.sort { $0.startDate > $1.startDate }
                    analysisProgress = record.analysisProgress ?? 0
                    if selected?.id == record.id { selected = record }
                    if record.pendingAnalysis != true {
                        selected = record
                        // The next pending night starts in a fresh task after this runner exits.
                        Task { @MainActor in
                            await Task.yield()
                            self.resumePendingAnalysis()
                        }
                        return
                    }
                }
            } catch is CancellationError {
                // A quick return can arrive before the cancelled segment exits.
                // Restart once from its committed checkpoint after releasing this runner.
                resumeAfterCancellation = true
            } catch {
                if foreground { self.error = "录音分析未完成，进度已保存，回到前台后可继续。" }
                recordDiagnostic(error)
            }
        }
    }
    private func recordDiagnostic(_ failure: Error) {
        let message = String(describing: failure)
        NSLog("SnoreLog: %@", message)
        guard var record = selected ?? records.first else { return }
        record.diagnostics.errorCounts[message, default: 0] += 1
        let now = Date()
        var times = record.diagnostics.errorTimes ?? [:]
        times[message] = ErrorTimes(first: times[message]?.first ?? now, last: now)
        record.diagnostics.errorTimes = times
        if !record.diagnostics.clipErrors.contains(message) { record.diagnostics.clipErrors.append(message) }
        try? store.save(record)
        records.removeAll { $0.id == record.id }; records.append(record)
        records.sort { $0.startDate > $1.startDate }
        if selected?.id == record.id { selected = record }
    }
    #if DEBUG
    func runDemoIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        func option(_ name: String) -> String? { args.firstIndex(of: name).flatMap { $0+1 < args.count ? args[$0+1] : nil } }
        guard let path = option("-demoNight"), !active else { return }
        onboarded = true; active = true; elapsed = 0
        let labels = option("-demoLabels").map { URL(fileURLWithPath: $0) }
        var gaps: [(Double, Double)] = []
        for i in args.indices where args[i] == "-demoGapAt" && i+1 < args.count {
            let values = args[i+1].split(separator: ":").compactMap { Double($0) }
            if values.count == 2 { gaps.append((values[0], values[1])) }
        }
        let alarm = option("-demoAlarmAt").flatMap(Double.init)
        let store = self.store
        Task.detached {
            let result = Result { try DemoRunner.run(wav: URL(fileURLWithPath: path), labels: labels, store: store, gaps: gaps, alarmAt: alarm) { elapsed, db in
                Task { @MainActor in self.elapsed = elapsed; self.currentDb = Float(db ?? 0) }
            } }
            await MainActor.run { self.complete(result) }
        }
    }
    #endif
}
