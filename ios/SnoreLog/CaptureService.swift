import Foundation
import AVFAudio
import SnoreCore
import UIKit
import UserNotifications

final class CaptureService: @unchecked Sendable {
    private let queue = DispatchQueue(label: "SnoreLog.analysis", qos: .userInitiated)
    private var engine = AVAudioEngine()
    private var ring: PCMQueue?
    private var converter: AVAudioConverter?
    private var input: AVAudioPCMBuffer?
    private var output: AVAudioPCMBuffer?
    private var timer: DispatchSourceTimer?
    private var observers: [NSObjectProtocol] = []
    private var interruption = RecoveryController()
    private var pipeline: RecordingPipeline?
    private var alarmMarked = false
    private var lastPublish = Date.distantPast
    private var running = false
    private var isBackground = false
    private var interruptionNotifications = 0
    private var notifiedInterruption = false
    var onUpdate: ((Double, Double?, Bool) -> Void)?
    var onFinish: ((Result<NightRecord, Error>) -> Void)?
    func start(record: NightRecord, store: NightStore) throws {
        try configureSession()
        pipeline = try RecordingPipeline(record: record, store: store)
        try buildEngine()
        running = true
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: .milliseconds(50))
        source.setEventHandler { [weak self] in self?.tick() }; source.resume(); timer = source
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak self] _ in
            let date = Date()
            self?.queue.async { self?.isBackground = true; self?.pipeline?.recordLifecycle(state: "background", at: date) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { [weak self] _ in
            let date = Date()
            self?.queue.async {
                self?.isBackground = false
                self?.pipeline?.recordLifecycle(state: "foreground", at: date)
                self?.attemptRecovery(method: "foreground", force: true)
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] note in
            let began = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue
            let date = Date()
            self?.queue.async { self?.handleInterruption(began: began, at: date) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.queue.async {
                guard let self, self.running, self.interruption.began == nil,
                      AVAudioSession.sharedInstance().currentRoute.inputs.first?.portType != .builtInMic else { return }
                do { try self.configureSession() } catch { self.degrade(error) }
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil) { [weak self] _ in
            self?.queue.async {
                guard let self else { return }
                self.handleInterruption(began: true)
                self.engine = AVAudioEngine()
                self.handleInterruption(began: false)
            }
        })
    }
    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .mixWithOthers])
        // Wake feedback fires before stopping input; recording otherwise suppresses haptics.
        try session.setAllowHapticsAndSystemSoundsDuringRecording(true)
        try session.setPrefersNoInterruptionsFromSystemAlerts(true)
        try session.setActive(true)
        if let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) { try session.setPreferredInput(builtIn) }
    }
    private func buildEngine() throws {
        let node = engine.inputNode
        let format = node.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.commonFormat == .pcmFormatFloat32 else { throw CocoaError(.coderInvalidValue) }
        let ring = PCMQueue(format: format); self.ring = ring
        let target = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        guard let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192),
              let converter = AVAudioConverter(from: format, to: target),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 8192) else { throw CocoaError(.coderInvalidValue) }
        self.input = input; self.converter = converter; self.output = output
        node.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in ring.push(buffer) }
        engine.prepare(); try engine.start()
    }
    private func drain(end: Bool = false) throws {
        guard let ring, let input, let output, let converter else { return }
        while true {
            let (hasInput, gap) = ring.pop(into: input)
            if gap > 0 {
                do { try flushConverter(converter, output: output) }
                catch { pipeline?.recordError("Dropped audio conversion tail: \(error.localizedDescription)") }
                converter.reset()
                pipeline?.recordDrop(seconds: gap); try pipeline?.markGap(seconds: gap)
            }
            if !hasInput { break }
            var supplied = false
            while true {
                var failure: NSError?
                let status = converter.convert(to: output, error: &failure) { _, result in
                    if supplied { result.pointee = .noDataNow; return nil }
                    supplied = true; result.pointee = .haveData; return input
                }
                if let failure { throw failure }
                if output.frameLength > 0 { try feed(Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))) }
                if status == .inputRanDry || status == .endOfStream { break }
                if status == .error { throw CocoaError(.fileReadUnknown) }
            }
        }
        if end { try flushConverter(converter, output: output) }
    }
    private func flushConverter(_ converter: AVAudioConverter, output: AVAudioPCMBuffer) throws {
        while true {
            var failure: NSError?
            let status = converter.convert(to: output, error: &failure) { _, result in result.pointee = .endOfStream; return nil }
            if let failure { throw failure }
            if output.frameLength > 0 { try feed(Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))) }
            if status == .endOfStream { break }
            if status == .error { throw CocoaError(.fileReadUnknown) }
        }
    }
    private func feed(_ samples: [Float]) throws {
        guard let pipeline else { return }
        if !alarmMarked, let alarm = pipeline.record.alarmDate {
            let elapsed = pipeline.recordedSec
            let until = alarm.timeIntervalSince(pipeline.record.startDate) - elapsed
            if until <= Double(samples.count) / 16_000 {
                let split = max(0, min(samples.count, Int((until * 16_000).rounded())))
                try pipeline.append(Array(samples.prefix(split)))
                pipeline.markAlarm(); alarmMarked = true
                try pipeline.append(Array(samples.dropFirst(split))); return
            }
        }
        try pipeline.append(samples)
    }
    private func tick() {
        guard running, let pipeline else { return }
        do {
            if interruption.began == nil && !engine.isRunning { notifiedInterruption = false; interruption.begin(at: Date()); pipeline.recordError("Input engine stopped without notification") }
            if interruption.began == nil { try drain() }
            else { attemptRecovery(method: "timer") }
            let now = Date()
            if !alarmMarked, let alarm = pipeline.record.alarmDate, now >= alarm { pipeline.markAlarm(); alarmMarked = true }
            if SessionTiming.shouldStop(start: pipeline.record.startDate, alarm: pipeline.record.alarmDate, now: now) { finishOnQueue(); return }
            if now.timeIntervalSince(lastPublish) >= 1 {
                lastPublish = now; onUpdate?(pipeline.recordedSec, pipeline.latestDb, interruption.began != nil)
            }
        } catch { degrade(error) }
    }
    private func handleInterruption(began: Bool, at date: Date = Date()) {
        guard running else { return }
        if began {
            if interruption.began == nil { notifiedInterruption = false }
            interruption.begin(at: date)
            engine.pause()
            do { try drain(end: true) } catch { pipeline?.recordError("Interrupted drain: \(error.localizedDescription)") }
        } else { attemptRecovery(method: "notification", force: true) }
    }
    private func attemptRecovery(method: String, force: Bool = false) {
        guard running else { return }
        if AVAudioApplication.shared.recordPermission == .denied { fail(CocoaError(.fileReadNoPermission)); return }
        let adapter = ClosureRecoverySession { [self] in
            try configureSession()
            engine.stop(); engine.inputNode.removeTap(onBus: 0)
            if let lost = ring?.discardPendingSeconds(), lost > 0 {
                pipeline?.recordDrop(seconds: lost)
                try pipeline?.markGap(seconds: lost)
            }
            engine = AVAudioEngine()
            try buildEngine()
        }
        do {
            if let event = try interruption.attempt(at: Date(), method: method, force: force, session: adapter) {
                let duration = max(event.duration, Date().timeIntervalSince(event.start))
                pipeline?.recordInterruption(start: event.start, duration: duration, recovery: event.method)
                try pipeline?.markGap(seconds: duration)
            }
        } catch {
            let context = isBackground ? "background retry failed" : (method == "foreground" ? "foreground recovery failed" : "foreground retry failed")
            pipeline?.recordError("\(context) (\(method)): \(error)")
            if isBackground, !notifiedInterruption, interruptionNotifications < 3 {
                notifiedInterruption = true; interruptionNotifications += 1
                let content = UNMutableNotificationContent()
                content.body = "呼噜记的录音被打断了，点这里回到 App 继续录"
                content.sound = nil
                let request = UNNotificationRequest(identifier: "recording-interrupted-\(pipeline?.record.id ?? "night")-\(interruptionNotifications)", content: content, trigger: nil)
                UNUserNotificationCenter.current().add(request) { [weak self] failure in
                    if let failure { self?.queue.async { self?.pipeline?.recordError("interruption notification: \(failure)") } }
                }
            }
        }
    }
    private func degrade(_ error: Error) {
        pipeline?.recordError(error.localizedDescription)
        if AVAudioApplication.shared.recordPermission == .denied { fail(error); return }
        interruption.begin(at: Date()); engine.pause()
    }
    func finish() { queue.async { self.finishOnQueue() } }
    private func finishOnQueue() {
        guard running else { return }; running = false
        engine.stop(); engine.inputNode.removeTap(onBus: 0)
        timer?.cancel(); timer = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }; observers.removeAll()
        do {
            try drain(end: true)
            if let event = interruption.stop(at: Date()) {
                pipeline?.recordInterruption(start: event.start, duration: event.duration, recovery: event.method)
                try pipeline?.markGap(seconds: event.duration)
            }
            if let pipeline { onFinish?(.success(try pipeline.finish(battery: finalBattery))) }
        } catch { savePartial(error) }
        try? AVAudioSession.sharedInstance().setActive(false)
    }
    private func savePartial(_ error: Error) {
        pipeline?.recordError(String(describing: error))
        do {
            if let pipeline { onFinish?(.success(try pipeline.stopUnexpectedly(reason: "录音意外停止，请检查权限和可用空间", at: Date(), battery: finalBattery))) }
            else { onFinish?(.failure(error)) }
        } catch { onFinish?(.failure(error)) }
    }
    private var finalBattery: Double? {
        let value = UIDevice.current.batteryLevel
        return value < 0 ? nil : Double(value)
    }
    private func fail(_ error: Error) {
        engine.stop()
        if let lost = ring?.discardPendingSeconds(), lost > 0 {
            pipeline?.recordDrop(seconds: lost)
            do { try pipeline?.markGap(seconds: lost) } catch { pipeline?.recordError("Final buffered audio: \(error.localizedDescription)") }
        }
        if let event = interruption.stop(at: Date()) {
            pipeline?.recordInterruption(start: event.start, duration: event.duration, recovery: "unavailable")
            do { try pipeline?.markGap(seconds: event.duration) } catch { pipeline?.recordError("Final interruption: \(error.localizedDescription)") }
        }
        running = false; engine.stop(); engine.inputNode.removeTap(onBus: 0); timer?.cancel(); timer = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }; observers.removeAll()
        try? AVAudioSession.sharedInstance().setActive(false)
        savePartial(error)
    }
}
