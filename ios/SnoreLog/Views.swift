import SwiftUI
import UIKit
import Charts
import SnoreCore
import AVFAudio

struct RootView: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        Group {
            if !state.onboarded { OnboardingView() }
            else if state.active { SleepView() }
            else if let progress = state.analysisProgress {
                VStack(spacing: 20) {
                    Text("正在分析昨晚的录音… \(Int(progress * 100))%")
                    ProgressView(value: progress)
                    Text("离开 App 会暂停，回来后继续分析。")
                }.padding()
            }
            else {
                TabView {
                    NavigationStack { BedtimeView() }.tabItem { Label("睡前", systemImage: "moon") }
                    NavigationStack { HistoryView() }.tabItem { Label("历史", systemImage: "clock") }
                    NavigationStack { SettingsView() }.tabItem { Label("设置", systemImage: "gear") }
                }
            }
        }
        .sheet(item: $state.selected) { record in NavigationStack { ReportView(night: record).toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { state.selected = nil } } } }.environmentObject(state) }
        .alert("提示", isPresented: Binding(get: { state.error != nil }, set: { if !$0 { state.error = nil } })) { Button("好") { state.error = nil } } message: { Text(state.error ?? "") }
    }
}
struct OnboardingView: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        NavigationStack {
            Form {
                Text("手机放床头柜，离头 30–50 厘米，插着充电，麦克风朝床。")
                Text("同床有人打呼时，结果也会包含对方。")
                Text("整夜录音只在分析前临时存在本机，分析完自动删除，只留几段代表片段。")
                Text("这不是医学诊断。")
                Button("开始使用") { state.onboarded = true }
            }.navigationTitle("呼噜记")
        }
    }
}
struct BedtimeView: View {
    @EnvironmentObject var state: AppState
    @State private var expiryAlert = false
    @State private var delayPicker = false
    var body: some View {
        Form {
            Section("闹钟") {
                DatePicker("时间", selection: $state.alarmTime, displayedComponents: .hourAndMinute)
                Toggle("贪睡 9 分钟", isOn: $state.snooze)
                if state.alarmWarning || !state.alarms.authorized { Text("闹钟未授权时，闹钟不会响；仍可只录音。") }
            }
            Section("今晚因素") {
                ForEach(AppCopy.factors, id: \.self) { factor in
                    Toggle(factor, isOn: Binding(get: { state.factors.contains(factor) }, set: { if $0 { state.factors.insert(factor) } else { state.factors.remove(factor) } }))
                }
            }
            Section {
                if UIDevice.current.batteryLevel >= 0 && UIDevice.current.batteryLevel < 0.5 && UIDevice.current.batteryState == .unplugged { Text("电量低于 50%，建议插着充电。") }
                if !state.microphoneAllowed { Text("麦克风未授权，开始时会请求权限。") }
                if let expiration = state.expiration { Text("本次安装 \(expiration.formatted()) 到期") }
                Button("只录音") { Task { await state.start(onlyRecording: true) } }
            }
        }.navigationTitle("呼噜记")
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                Button("\(Int(state.delay / 60)) 分钟后开始统计 · 修改") { delayPicker = true }
                    .font(.footnote).accessibilityIdentifier("statisticsDelay")
            Button {
                if Provisioning.expiresBeforeAlarm(expiration: state.expiration, alarm: state.nextAlarm) { expiryAlert = true }
                else { Task { await state.start() } }
            } label: { Text("睡觉").frame(maxWidth: .infinity) }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .frame(maxWidth: .infinity).accessibilityIdentifier("startSleep")
            }
            .padding().background(.bar)
        }
        .confirmationDialog("延迟开始统计", isPresented: $delayPicker, titleVisibility: .visible) {
            ForEach([0, 10, 20, 30], id: \.self) { minutes in
                Button("\(minutes) 分钟") { state.delay = Double(minutes * 60) }
            }
            Button("取消", role: .cancel) {}
        }
        .alert("今晚会过期，过期后闹钟不会响。先重新安装再睡。", isPresented: $expiryAlert) {
            Button("取消", role: .cancel) {}
            Button("仍然只录音") { Task { await state.start(onlyRecording: true) } }
        }
    }
}
struct SleepView: View {
    @EnvironmentObject var state: AppState
    @State private var pressing = false
    @State private var holdProgress = 0.0
    @State private var wakeFeedback = UIImpactFeedbackGenerator(style: .light)
    var body: some View {
        NavigationStack {
            Form {
                LabeledContent("已录时长", value: duration(state.elapsed))
                LabeledContent("当前音量", value: "约 \(Int(state.currentDb)) dB")
                Text(state.interrupted ? "中断中" : "录音中")
                if state.alarmWarning { Text("闹钟不会响，当前只录音。") }
                Text("可以锁屏。长按下方按钮 1 秒结束。")

            }.navigationTitle("睡眠中")
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    Text("长按 1 秒起床").frame(maxWidth: .infinity)
                    ProgressView(value: holdProgress).tint(.white).opacity(pressing ? 1 : 0)
                }
                .padding(.horizontal, 20).padding(.vertical, 14)
                .foregroundStyle(.white)
                .background(Color.accentColor, in: Capsule())
                .contentShape(Capsule())
                .onLongPressGesture(minimumDuration: 1, maximumDistance: 30, pressing: { down in
                    pressing = down
                    // Cancel the in-flight animation immediately on release or movement cancellation.
                    var reset = Transaction(); reset.disablesAnimations = true
                    withTransaction(reset) { holdProgress = 0 }
                    if down {
                        wakeFeedback.prepare()
                        withAnimation(.linear(duration: 1)) { holdProgress = 1 }
                    }
                }) {
                    wakeFeedback.impactOccurred()
                    state.wake()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("起床")
                .accessibilityAction { state.wake() }
                .accessibilityIdentifier("wakeUp")
                .padding().padding(.bottom, 16).background(.bar)
            }
        }.preferredColorScheme(.dark)
    }
}
func duration(_ seconds: Double) -> String { DisplayFormat.duration(seconds) }
func clock(_ record: NightRecord, _ sec: Double) -> String { DisplayFormat.clock(record.startDate.addingTimeInterval(sec)) }
func reasonLabel(_ reason: RetentionReason) -> String {
    switch reason { case .pause: "疑似停顿"; case .loud: "很响"; case .longestRun: "最长连续打呼" }
}
struct TimelineView: View {
    let record: NightRecord
    var body: some View {
        Chart {
            ForEach(record.report?.minuteGrid ?? [], id: \.minute) { cell in
                RectangleMark(xStart: .value("钟点", record.startDate.addingTimeInterval(Double(cell.minute) * 60)), xEnd: .value("钟点", record.startDate.addingTimeInterval(Double(cell.minute + 1) * 60)), yStart: .value("音量", 0), yEnd: .value("音量", 1))
                    .foregroundStyle(cell.isGap ? Color.gray : Color.accentColor.opacity(0.1 + 0.9 * min(1, cell.snoreSec / 60)))
                if cell.hasPause { PointMark(x: .value("钟点", record.startDate.addingTimeInterval(Double(cell.minute) * 60 + 30)), y: .value("停顿", 1.15)).foregroundStyle(.red) }
            }
            if let alarm = record.alarmDate { RuleMark(x: .value("闹钟", alarm)).foregroundStyle(.primary).lineStyle(StrokeStyle(lineWidth: 1, dash: [4])) }
        }
        .chartXAxis {
            AxisMarks(values: DisplayFormat.halfHourTicks(start: record.startDate, end: record.startDate.addingTimeInterval(max(60, record.report?.recordedSec ?? 60)))) { value in
                AxisGridLine(); AxisTick()
                AxisValueLabel { if let date = value.as(Date.self) { Text(DisplayFormat.clock(date)) } }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                if let alarm = record.alarmDate, let x = proxy.position(forX: alarm), let anchor = proxy.plotFrame {
                    let frame = geometry[anchor]
                    Text("闹钟").position(x: min(frame.maxX - 24, max(frame.minX + 24, frame.minX + x + 24)), y: frame.minY + 12)
                }
            }
        }
        .chartXScale(range: .plotDimension(startPadding: 24, endPadding: 24))
        .chartYScale(domain: 0...1.3).chartYAxis(.hidden).frame(height: 170)
        .accessibilityLabel("整夜时间轴，横轴为本地钟点，红点为疑似停顿，灰色为中断")
    }
}
struct ReportSummary: View {
    let record: NightRecord
    var body: some View {
        if let report = record.report {
            LabeledContent("录了多久", value: duration(report.recordedSec))
                .accessibilityElement(children: .combine).accessibilityIdentifier("recordedDuration")
            LabeledContent("有效分析", value: duration(report.analyzedSec))
            LabeledContent("打呼时长", value: "\(duration(report.snoreEpisodeSec))，占 \(report.episodeRatio.formatted(.percent.precision(.fractionLength(1))))")
                .accessibilityElement(children: .combine).accessibilityIdentifier("episodeDuration")
            Text("鼾声发声时间 \(duration(report.snoreSec)) · 打呼时段按相邻鼾声不超过 30 秒合并")
                .font(.footnote).foregroundStyle(.secondary)
            if report.healthNotice { Text(AppCopy.healthNotice) }
            if let run = report.longestSnoreEpisode { LabeledContent("最长连续打呼", value: "\(duration(run.durationSec))（\(clock(record, run.start))–\(clock(record, run.end))）") }
            if let gap = report.longestEpisodeGap { LabeledContent("最长不打呼间隔", value: duration(gap.durationSec)) }
            LabeledContent("疑似停顿", value: "\(report.pauses.count) 次")
            ForEach([PauseBucket.tenToTwenty,.twentyToThirty,.thirtyOrMore], id: \.rawValue) { bucket in LabeledContent(bucket == .thirtyOrMore ? "≥30 秒" : "\(bucket.rawValue) 秒", value: "\(report.pauses.filter { $0.bucket == bucket }.count) 次") }
            LabeledContent("每小时疑似停顿", value: String(format: "%.2f 次", report.pausesPerHour))
            LabeledContent("最长一次", value: duration(report.longestPauseSec))
            LabeledContent("打呼音量中位数", value: report.snoreMedianDb.map { String(format: "约 %.0f dB", $0) } ?? "无打呼")
            LabeledContent("打呼音量 P95", value: report.snoreP95Db.map { String(format: "约 %.0f dB", $0) } ?? "无打呼")
        } else { Text("还没有完整的统计快照。") }
    }
}
struct ReportView: View {
    @EnvironmentObject var state: AppState
    let night: NightRecord
    @State private var share: [URL] = []
    @State private var showShare = false
    @State private var exporting = false
    @State private var exportDirectory: URL?
    @AppStorage("clipsPrivacySeen") private var privacySeen = false
    @State private var showPrivacy = false
    var record: NightRecord { state.records.first { $0.id == night.id } ?? night }
    var body: some View {
        List {
            if record.unexpectedStop { Text("录音在 \((record.snapshotDate ?? record.startDate).formatted(date: .omitted, time: .shortened)) 停止：\(record.unexpectedStopReason ?? "原因未记录")") }
            if record.pendingAnalysis == true {
                Section("当晚报告") {
                    Text("打开后分析")
                    Text("正在分析昨晚的录音… \(Int((record.analysisProgress ?? 0) * 100))%")
                    if let progress = record.analysisProgress { ProgressView(value: progress) }
                    Button("继续分析") { state.resumePendingAnalysis() }
                }
            } else {
            Section("当晚报告") { ReportSummary(record: record) }
            Section("时间轴") {
                TimelineView(record: record)
                Text("颜色深浅表示每分钟鼾声发声秒数；红点为疑似停顿，灰色为中断。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("留存片段") {
                ForEach(DisplayFormat.sortedClips(record.clips)) { clip in
                    ClipPlaybackRow(record: record, clip: clip)
                }
            }
            }
            Section("当晚因素") { Text(record.factors.isEmpty ? "未选择" : record.factors.joined(separator: "、")) }
            Section {
                DisclosureGroup("诊断信息") {
                    LabeledContent("丢帧秒数", value: String(format: "%.3f", record.diagnostics.droppedSec))
                    LabeledContent("峰值文件数", value: "\(record.diagnostics.peakFileCount)")
                    LabeledContent("分类器平均耗时", value: String(format: "%.3f ms", record.diagnostics.classifierAverageMs))
                    LabeledContent("最终电量", value: record.diagnostics.finalBattery.map { "\(Int($0 * 100))%" } ?? "未提供")
                    ForEach(Array(record.diagnostics.interruptions.enumerated()), id: \.offset) { _, event in
                        Text("\(event.start.formatted()) · \(String(format: "%.3f", event.duration)) 秒 · \(event.recovery)")
                    }
                    ForEach(Array(record.diagnostics.clipErrors.enumerated()), id: \.offset) { _, error in Text(error) }
                    ForEach(record.diagnostics.errorCounts.keys.sorted(), id: \.self) { key in
                        Text("\(key) · \(record.diagnostics.errorCounts[key] ?? 0) 次")
                        if let times = record.diagnostics.errorTimes?[key] {
                            Text("首次 \(times.first.formatted()) · 末次 \(times.last.formatted())")
                        }
                    }
                    ForEach(Array(record.diagnostics.lifecycle.enumerated()), id: \.offset) { _, event in Text("\(event.at.formatted()) · \(event.state)") }
                }
            }
        }.navigationTitle(record.startDate.formatted(date: .abbreviated, time: .omitted))
        .toolbar { Button("导出") { Task { await export() } }.disabled(record.pendingAnalysis == true || exporting || state.active) }
        .onDisappear { state.stopPlayback() }
        .onAppear { if !privacySeen { showPrivacy = true; privacySeen = true } }
        .alert("片段只存在本机", isPresented: $showPrivacy) { Button("知道了") {} }
        .sheet(isPresented: $showShare, onDismiss: {
            if let exportDirectory { try? FileManager.default.removeItem(at: exportDirectory) }
            exportDirectory = nil; share = []
        }) { ShareSheet(urls: share) }
    }
    @MainActor private func export() async {
        guard !exporting, !state.active else { return }
        exporting = true
        defer { exporting = false }
        let content = VStack(alignment: .leading, spacing: 12) { Text("呼噜记 · \(record.startDate.formatted())"); ReportSummary(record: record); TimelineView(record: record) }.padding().frame(width: 420).background(.background)
        let renderer = ImageRenderer(content: content); renderer.scale = 2
        guard let data = renderer.uiImage?.pngData() else { state.error = "报告图片生成失败"; return }
        do {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("report-\(record.id).png")
            try data.write(to: url)
            let originals = record.clips.map { state.store.directory(record.id).appendingPathComponent("clips/\($0.fileName)") }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("snore-export-" + UUID().uuidString)
            exportDirectory = directory
            let amplified = try await Task.detached(priority: .userInitiated) {
                try originals.map { try ClipAmplifier.prepare(source: $0, directory: directory).url }
            }.value
            share = [url] + originals + amplified; showShare = true
        } catch {
            if let exportDirectory { try? FileManager.default.removeItem(at: exportDirectory) }; exportDirectory = nil
            state.error = "报告导出失败，请稍后重试。"; NSLog("Report export: %@", String(describing: error)) }
    }
}
struct HistoryView: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        List {
            Section("每晚记录") {
                ForEach(state.records) { record in Button { state.selected = record } label: { VStack(alignment: .leading) { Text(DisplayFormat.nightDate(record.startDate)); if record.pendingAnalysis == true { Text("打开后分析") } else { Text("打呼 \(((record.report?.episodeRatio ?? 0) * 100).formatted(.number.precision(.fractionLength(1))))% · \(duration(record.report?.snoreEpisodeSec ?? 0))"); Text(String(format: "每小时疑似停顿 %.2f 次", record.report?.pausesPerHour ?? 0)) } } } }
            }
            Section("因素对比") {
                ForEach(AppCopy.factors, id: \.self) { factor in
                    let stats = FactorComparison.compare(records: state.records, factor: factor)
                    VStack(alignment: .leading) {
                        Text("\(factor)：有 \(stats.hasCount) 晚 / 无 \(stats.withoutCount) 晚")
                        if stats.insufficient { Text("晚数太少，先别下结论") }
                        Text("打呼占比：\(percent(stats.hasRatio)) / \(percent(stats.withoutRatio))")
                        Text("每小时疑似停顿：\(number(stats.hasPauses)) / \(number(stats.withoutPauses))")
                        Text("P95：\(db(stats.hasP95)) / \(db(stats.withoutP95))")
                    }
                }
            }
        }.navigationTitle("历史")
    }
    func percent(_ value: Double?) -> String { value.map { $0.formatted(.percent.precision(.fractionLength(1))) } ?? "暂无" }
    func number(_ value: Double?) -> String { value.map { String(format: "%.2f", $0) } ?? "暂无" }
    func db(_ value: Double?) -> String { value.map { String(format: "约 %.0f dB", $0) } ?? "暂无" }
}
struct SettingsView: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        Form {
            Section("音量") {
                Stepper("校准偏移 \(Int(state.offset))", value: $state.offset, in: 0...160, step: 1)
                Text("拿分贝计 App 对照一次。修改仅影响以后的夜晚。")
            }
            Stepper("留存 \(state.retentionDays) 晚", value: $state.retentionDays, in: 1...365)
            if let expiration = state.expiration { Text("本次安装 \(expiration.formatted()) 到期") } else { Text("开发版，无到期限制") }
            Section("导出某晚") { ForEach(state.records) { record in Button(record.startDate.formatted()) { state.selected = record } } }
            Button("重看引导") { state.onboarded = false }
        }.navigationTitle("设置")
    }
}
struct ShareSheet: UIViewControllerRepresentable {
    let urls: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: urls, applicationActivities: nil) }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct ClipPlaybackRow: View {
    @EnvironmentObject var state: AppState
    let record: NightRecord
    let clip: ClipRecord
    @State private var length = 0.0
    @State private var position = 0.0
    @State private var marker: Double?
    @State private var editing = false
    private var id: String { "\(record.id)/\(clip.id)" }
    private var playing: Bool { state.playingClipID == id }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(DisplayFormat.clipText(record: record, clip: clip))
            HStack {
                Button(playing ? "停止" : "播放") { togglePlayback() }
                    .accessibilityIdentifier("clipPlay-" + clip.id)
                    .disabled(state.active || state.preparingClipID != nil)
                Button(clip.favorite ? "取消收藏" : "收藏") { state.favorite(record: record, clip: clip) }
            }.buttonStyle(.borderless)
            Slider(value: Binding(get: { position }, set: { position = $0 }), in: 0...max(0.001, length), onEditingChanged: { value in
                editing = value
                if playing {
                    state.setScrubbing(value)
                    if !value { state.seekPlayback(position) }
                }
            })
            .overlay {
                GeometryReader { geometry in
                    if let marker, length > 0 {
                        Rectangle().fill(clip.reason == .pause ? Color.red : Color.orange)
                            .frame(width: 3, height: 16)
                            .position(x: 14 + (geometry.size.width - 28) * marker / length, y: geometry.size.height / 2)
                    }
                }.allowsHitTesting(false)
            }
            .disabled(length <= 0 || state.active)
            .accessibilityLabel("片段播放位置")
            .accessibilityIdentifier("clipSlider-" + clip.id)
            HStack {
                Text(ClipMarkers.time(position))
                Spacer()
                Text(ClipMarkers.time(length))
            }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            HStack {
                Button("后退 10 秒") { move(to: position - 10) }
                Button("前进 10 秒") { move(to: position + 10) }
            }.buttonStyle(.borderless).disabled(length <= 0 || state.active)
            if let marker {
                if clip.reason == .pause {
                    HStack {
                        Text("红色刻度：停顿开始 \(ClipMarkers.time(marker))").foregroundStyle(.red)
                        Button("跳到停顿") {
                            move(to: max(0, marker - 5))
                            if !playing { togglePlayback() }
                        }.accessibilityIdentifier("pauseJump-" + clip.id)
                            .buttonStyle(.borderless).disabled(state.active || state.preparingClipID != nil)
                    }.font(.caption)
                } else {
                    Text("橙色刻度：最响一秒 \(ClipMarkers.time(marker))").font(.caption).foregroundStyle(.orange)
                }
            }
            if state.preparingClipID == id { Text("正在放大…").font(.footnote) }
            if state.lastPlayedClipID == id {
                Text("已放大约 \(Int(state.playbackGainDb.rounded())) dB").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .task {
            let url = state.store.directory(record.id).appendingPathComponent("clips/\(clip.fileName)")
            let loud = clip.reason == .loud
            do {
                let metadata = try await Task.detached(priority: .utility) {
                    let audio = try AVAudioFile(forReading: url)
                    let duration = Double(audio.length) / audio.processingFormat.sampleRate
                    let offset = loud ? try ClipAmplifier.measure(url: url).loudestSecondOffset : nil
                    return (duration, offset)
                }.value
                length = metadata.0
                marker = clip.reason == .pause ? ClipMarkers.pauseOffset(record: record, clip: clip, duration: length) : metadata.1
                if let marker, marker < 0 || marker >= length { self.marker = nil }
            } catch { length = 0 }
        }
        .onChange(of: state.playbackElapsed) { _, value in
            if playing, !editing { position = min(length, value) }
        }
        .onChange(of: state.lastPlayedClipID) { _, value in
            if value != id { position = 0; editing = false }
        }
    }
    private func move(to seconds: Double) {
        position = min(length, max(0, seconds))
        if playing { state.seekPlayback(position) }
    }
    private func togglePlayback() {
        if !playing { state.selectPosition(id: id, seconds: position) }
        state.play(record, clip)
    }
}
