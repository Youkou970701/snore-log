# Codex 交接 02a：02 返工（耗电 + 整夜不能断）

> 先读 `docs/codex-handoff-02-results.md`（你自己的报告）。写入范围同 02：`ios/`、`core/`、本期结果文件 `docs/codex-handoff-02a-results.md`。
> 不联网、不加依赖、不 git commit。命令都加 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`。

## Claude 验收结论（2026-11-05）

亲自重跑通过：core 20 个测试、`check.py --codex` 18/18、`swift test --package-path ios` 9 项、`check_demo.py`（14/12 号逐字段一致、片段文件精确）、文案扫描、无网络代码。
代码通读：结构清楚，演示夜共用管线、到期拦截、长按起床、健康提示原文都对。

问题集中在**「一整晚 8 小时、锁屏、没人看着」这个场景**——测试测不出来，真机过夜才会暴露。下面 1–2 是实测数据，3–6 是读代码发现的。

## 要改的

### 1. 分类器每秒重新加载模型（最大的耗电点）

`AppleSnoreClassifier.classify` 每帧新建 `SNClassifySoundRequest` + `SNAudioStreamAnalyzer`。Claude 在本机实测（06 号样本 120 帧）：

| 方式 | 每帧耗时 | snoring 置信度 |
|---|---|---|
| 现在：每帧新建 | 30.3 ms | — |
| 整晚复用一个分析器，按顺序 `analyze(buffer, atAudioFramePosition: 秒×16000)` | **1.6 ms** | 与每帧新建**最大差 0.0000** |

改成整晚复用一个分析器（每个 `NightAnalyzer` 一个）。注意结果是通过观察者回调来的，要保证**第 N 秒的规则判断拿到的是第 N 秒的结果**，且分块一致性不变。
验收：`check.py --codex` 18/18；`check.py --real` 在全部样本上的输出与改之前逐字相同（先跑一遍存下来再改）；core 加一个测试比较两种方式在一段音频上逐帧结果相同。

### 2. 每个音频块都重算整份报告

`CaptureService.feed()` 为判断闹钟每次调用 `pipeline.currentReport.recordedSec`（约每 50 ms 一次），`tick()` 每秒又算一次整份报告推给界面。
实测 8 小时时一次 0.8 ms（Mac），按每秒 20 次约 2% CPU，而且随录音时长线性变慢；整份报告（含 2.9 万个包络值）每秒复制到主线程也没必要。
改：`RecordingPipeline` 自己维护 `recordedSec`（样本数 + 中断秒数累加），`NightAnalyzer` 暴露最近一帧 dB；界面只收「已录时长、当前 dB、是否中断」三个数。**整份报告只在每段结束存快照时算。**

### 3. 环形缓冲只有约 2.7 秒

`PCMQueue` 32 格 × 4096 帧，48 kHz 下约 2.7 秒。分析队列只要卡住超过 2.7 秒（段结束时编码 AAC、合并片段、写 JSON，加上后台被系统降频）就丢音频。
改：容量至少 30 秒。丢掉的秒数累计写进诊断（见 6）。

### 4. 片段管理出错会让整晚录音停掉

`reconcile` 里找不到源文件就 `throw`、文件数 >15 也 `throw`，异常一路传到 `CaptureService.fail()`，**录音直接停止**——用户睡着了根本不知道。
改：片段管理的任何错误都**不能停止录音**。正式版：跳过这条候选、删掉最旧的非留存文件来守住 ≤15，并把错误记进诊断；只在 DEBUG/测试里保留 throw，好让测试抓到。
同理检查其他会走到 `fail()` 的路径：只有「麦克风彻底拿不到」才允许停，其余都降级继续。

### 5. 中断后系统不发「结束」通知就永远不恢复

现在只在收到 `interruptionNotification` 的 ended 时重启。实际上来电拒接、别的 App 抢了音频，系统**经常不发 ended**，这样后半夜全丢。
改：中断超过 30 秒后，每 30 秒尝试一次重新激活会话 + 重启引擎；App 回到前台时也尝试一次。成功后按实际中断时长 `markGap`。加测试（用可注入的会话/引擎接口模拟「只有 began 没有 ended」）。

### 6. 录音意外停止要当场留下部分报告 + 诊断信息

- `fail()` 时立即用 `currentReport()` 写好部分报告，`night.json` 里记停止时刻和原因；早上打开 App 直接看到「录音在 03:12 停止：<原因>」，不用等下次冷启动恢复。
- `night.json` 加 `diagnostics`：中断列表（开始、时长、是怎么恢复的）、丢帧秒数、片段管理错误、峰值文件数、分类器平均耗时、App 进后台/回前台时刻、最终电量。报告页最底下加一个默认折叠的「诊断信息」。
  这是 03 期真机过夜后 Claude 排查问题的唯一依据，**宁可多记**（但不记录音内容）。

## 交付

- core：`swift test` 全过；`check.py --codex` 18/18；`check.py --real` 与改前逐字相同。
- ios：`swift test --package-path ios` 全过（加上 4、5、6 的测试）；`check_demo.py` 全过。
- 模拟器运行时如果有了（`xcrun simctl list runtimes`），补跑 02 第九节的 `xcodebuild test` 和截图；还没有就照实写。
- 结果写 `docs/codex-handoff-02a-results.md`，列出 1 的改前/改后耗时（你自己测一遍）。
