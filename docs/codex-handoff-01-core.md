# Codex 交接 01：分析内核 SnoreCore

> 先读 `docs/requirements.md`（尤其「关键规则 R1–R10」和「安全与隐私红线」）。
> 本期**只做分析内核**：吃音频文件 → 出事件和报告。不碰麦克风、不做界面、不建 Xcode 工程。
> 写入范围：`core/`、`Package.swift`（放 `core/` 下）。**不要改 `docs/` 和 `fixtures/`**（Claude 负责）。

## 环境

- Mac，macOS 27，Swift 6.4。目前**只有命令行工具没有 Xcode**；SoundAnalysis / AVFAudio 框架在命令行工具的 SDK 里有。
- 测试优先用 Swift Testing（`import Testing`）。如果命令行工具下 `swift test` 跑不起来，停下来说明原因，不要绕开测试。
- 不准联网下载模型或数据集；不加第三方依赖。

## 目录

```
core/
  Package.swift
  Sources/SnoreCore/       # 库：帧特征、噪声底、打呼段、停顿检测、留存候选池、报告
  Sources/snore-analyze/   # 命令行
  Tests/SnoreCoreTests/
```

## 接口（形状按这个来，命名可微调）

```swift
public struct AnalyzerConfig { /* R1–R10 的所有阈值，默认值=requirements 里的数；calibrationOffsetDb=90; startDelaySec */ }

public final class NightAnalyzer {
    public init(config: AnalyzerConfig, startDate: Date)
    /// 流式喂入，任意长度的 16kHz 单声道 Float32 PCM。App 每 2 分钟喂一段，命令行可以一次喂整晚。
    public func append(_ samples: [Float]) throws
    /// 告诉分析器某段时间没录到（来电中断等），这段从统计分母扣掉
    public func markGap(seconds: Double)
    /// 闹钟开始响，之后的帧不计入
    public func markAlarm()
    public func finish() -> NightReport
    /// 当前候选池（App 用它决定哪些 2 分钟段的音频要留）
    public var retention: [RetainedSegment] { get }
}
```

- **流式与一次性必须结果一致**：同一个文件，整段喂 vs 每 120 秒切开喂 vs 每 7 秒切开喂，`NightReport` 必须逐字段相同。这是本期最重要的测试——跨分段边界的打呼段和停顿不能被切断。
- 分类器用 `SNClassifySoundRequest(classifierIdentifier: .version1)`，取 `snoring` 类置信度；同时把 `breathing` 类置信度也存下来（R6 的「无打呼/呼吸类声音」要用）。窗口时长按 1 秒对齐帧。
- 为了单元测试可控，分类器做成协议 `SnoreClassifier`：真实实现走 SoundAnalysis，测试里可注入「按脚本返回置信度」的假实现。规则层的测试全部用假分类器，不依赖苹果模型的输出。

## NightReport 字段

```
recordedSec, gapSec, analyzedSec            // R9
snoreSec, snoreRatio                        // 打呼帧总秒数/分析秒数
snoreRuns: [{start, end, medianDb, p95Db}]  // R4
longestSnoreRun: {start, end, durationSec}
longestQuietGap: {start, end, durationSec}  // R5
pauses: [{start, durationSec, bucket, recoveryType: gasp|resumeSnore}]  // R6 R7
pausesPerHour, longestPauseSec
snoreMedianDb, snoreP95Db                   // R8，只统计打呼帧
envelope: [Float]                           // 每秒一个约 dB 值
minuteGrid: [{minute, snoreSec, maxDb, hasPause, isGap}]  // 时间轴用
healthNotice: Bool                          // 红线 1 的触发条件
retained: [RetainedSegment]                 // R10，每条含段号、原因(pause|loud|longestRun)、得分
```

时间一律用「距开始的秒数」，报告层再换成钟点。

## 命令行

```
swift run snore-analyze <file.wav|m4a> [--offset 90] [--delay 0] [--chunk 120] [--fake-classifier labels.json]
```

- 输出 `NightReport` 的 JSON 到 stdout；`--chunk` 控制流式喂入的块长，用来复现边界问题。
- `--fake-classifier`：读一个「第 N 秒 snoring/breathing 置信度」的 JSON，替代真实分类器。Claude 的规则样本会用它。
- 任意采样率/声道的输入先转成 16 kHz 单声道。

## 单元测试最少要覆盖

1. 合成音频 + 假分类器：打呼 3 分钟（每 4 秒一声）→ 安静 15 秒 → 一声大的 → 继续打呼。期望 1 次停顿（10–20 秒档，recoveryType=gasp）。
2. 同上但安静后**没有**恢复声（之后一直安静）→ 0 次停顿。
3. 安静 9 秒 → 0 次停顿（不到 10 秒）。
4. 呼噜间隔 8 秒以内合并成一段；间隔 9 秒拆成两段。
5. 底噪从 30 dB 抬到 45 dB（开风扇）→ 噪声底在 5 分钟内跟上，风扇本身不算打呼。
6. 整晚安静 → snoreSec=0、pauses 为空、healthNotice=false。
7. 停顿恰好跨 120 秒边界（第 115–130 秒安静）→ 切块 120 / 7 / 不切三种结果相同。
8. 留存池：制造 20 个候选，池子始终 ≤12，停顿段优先于响的段；跨边界事件合并成 1 条。
9. healthNotice：5 次/小时触发；1 次 ≥30 秒触发；4 次/小时且都 <30 秒不触发。
10. markAlarm 之后的打呼不计入；markGap 的时长从分母扣掉。

## 交付

- `cd core && swift test` 全过；`swift run snore-analyze` 能跑一个真实 wav（自己用 `say` 或合成音生成一个就行，别联网下载）。
- 写 `docs/codex-handoff-01-results.md`：测试数量、实际实现与本文档不一致的地方及原因、苹果分类器在合成音上的 snoring 置信度大概多少（如实写，低就写低）。
- 不要 git commit，Claude 验收后再提交。
