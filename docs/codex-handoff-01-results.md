# 01 实现结果（2026-11-05）

## 状态：实现已写入，验收被工具链阻塞，未达到交付通过条件

写入了 `core/` 下的 Swift Package、SnoreCore 库、命令行、Swift Testing 测试和本地合成验证素材。除本结果文件外未改动 `docs/`；未写入 `fixtures/`；未联网、未引入第三方依赖、未执行 git commit。当前项目尚无 `fixtures/`，因此没有进行标注样本准确率验收。

## 测试阻塞（必须先解决）

当前 `swift --version` 为 Apple Swift 6.4.2，arm64-apple-macosx27.2.0，工具链位于 `/Library/Developer/CommandLineTools`。

主代理实际复跑 `cd core && swift test`，退出码为 1，测试目标编译时报：

```text
error: external macro implementation type 'TestingMacros.SuiteDeclarationMacro'
could not be found for macro 'Suite'; plugin for module 'TestingMacros' not found
error: external macro implementation type 'TestingMacros.TestDeclarationMacro'
could not be found for macro 'Test'; plugin for module 'TestingMacros' not found
error: Build failed
error: fatalError
```

按交接单「如果命令行工具下 swift test 跑不起来，停下来说明原因，不要绕开测试」，已停止后续实现及测试尝试，没有改用 XCTest、移除测试或添加插件绕过。需要先修复/补全包含 Swift Testing 宏插件的本地 Swift 工具链，再重新运行原命令。

测试代码共 16 个测试方法，参数化展开后 17 个用例；**实际执行 0 个，不能声称通过**。覆盖原交接单十项，以及呼吸声阻断、恢复打呼、20/30 秒分档、音量异常尖峰、不足一秒尾帧、重复 finish、无效样本。

最重要的规则测试 `boundaryPauseReportsAreIdenticalForWhole120SevenAndFractionalChunks` 已写入：第 115–130 秒安静，比较整段、120 秒、7 秒、20,003 样本块，使用整个 `NightReport` 的 Equatable 比较和 sorted-key JSON 比较，包含不足一秒尾帧和跨边界留存检查。**此测试尚未能执行，关键验收仍未完成。**

## 已运行的离线 CLI 冒烟验证

以下验证在发现上述测试阻塞前开展，不能替代规则单元测试：

- `swift build` 曾成功构建库及命令行。测试阻塞后没有继续更改生产代码或尝试绕过测试。
- 命令行已实际读取本地合成 WAV 并通过苹果真实分类器输出报告。
- `core/Validation/sine-stereo-44100.wav` 当前为 17 秒、44.1 kHz 双声道；真实分类器分别按 120 秒和 7 秒喂入，报告一致，recordedSec/analyzedSec 均为 17。`stereo-report.json` 是该文件此前 3 秒版本的旧转换冒烟输出，不能当成当前文件的参考结果。
- `core/Validation/sine-131.wav` 为 131 秒、16 kHz 单声道；真实分类器按 131 秒（整段）、120 秒、7 秒输入，三个 JSON 逐字段一致，recordedSec/analyzedSec 均为 131。三次 CLI 运行退出码均为 0，耗时约 4.230 / 4.168 / 4.371 秒，见 `real-model-timings.json` 和 `real-131-report-*.json`。
- 纯音未形成鼾声或停顿事件，因此上述一致性只能证明真实分类器的基础分块稳定性，不能证明跨边界事件正确。
- `boundary.wav` 与 `boundary-labels.json` 是本地生成的 145 秒跨边界规则素材；停止时尚未运行该素材的 CLI 验证。

真实模型 probe 使用 `.version1`，确认实际窗口为 1 秒。合成输入的置信度约为：

| 输入 | snoring | breathing |
|---|---:|---:|
| 数字静音 | 0.002024 | 0.005269 |
| 120 Hz 纯音 | 0.000720 | 0.001688 |
| 440 Hz 纯音 | 0.000242 | 0.001728 |

置信度很低，不能据此推断真实鼾声识别准确率。复现脚本在 `core/Validation/classifier-probe.swift`，命令见 `core/README.md`。整夜耗时、真机能耗、远场录音准确率未测。

## 实现内容与需要审阅的边界解释

- PCM 固定为 16 kHz 单声道，内部累计满 16,000 个样本才处理一帧；外部 append 边界不会重置规则状态或模型窗口。模型每帧独立建立 1 秒请求、overlap 为 0，保存 snoring/breathing 置信度供当帧规则判断；报告不额外公开逐秒置信度数组。
- R1–R10 已给出的数值阈值保留，集中在 `AnalyzerConfig`。R6 未给出 breathing 类的置信度门槛，实现采用与 snoring 相同的 0.5，需验收方确认这项未明确的解释。
- API 和 CLI 默认 `startDelaySec=0`，便于交接单的离线规则测试；产品需求中睡前页默认 10 分钟应由 02 期传入 600 秒。这里没有把睡前页默认值接入库。
- 噪声底包含当前帧及延迟期间的已录音帧，使用最近 300 秒内有效帧音量的线性插值 P10；中断不补造噪声观测。音量下限为 -160 dBFS，防止数字静音产生非有限 JSON。
- R4 的间隔按两次打呼帧起点差解释：8 秒合并，9 秒拆分；run.end 为最后一个打呼帧结束时刻。R7 分档为 [10,20)、[20,30)、[30,+∞)。恢复窗口按安静结束后的五个一秒帧判断，若同帧同时满足恢复打呼与大声阈值，标为 gasp。
- `recordedSec` 是累计经过时间，包含中断；`gapSec` 单列；`analyzedSec` 仅计延迟之后、闹钟之前的完整有效帧，中断自然不进入分母。markGap/markAlarm 会结束未完成的证据链。末尾或中断/闹钟前不足一秒的 PCM 仅计入 recordedSec，不参与分类和统计。
- envelope/minuteGrid 保留延迟与闹钟后的录音音量，但这两段不累加打呼及停顿统计。缺失秒 envelope 用 `calibrationOffsetDb-160` 占位，配合 minuteGrid.isGap 解读；部分秒边界仍按秒槽表示。没有打呼时音量统计和最长段/间隔为 nil，JSONEncoder 会省略对应可选字段。
- 留存为元数据候选池，不实际编码/删除音频文件；02 期录音层需根据 retention 快照管理文件。候选分数为：停顿时长、段内打呼 P95、最长 run 时长；优先级 pause > loud > longestRun，同分按较早段号确定顺序，段号从 0 开始。
- 常见的跨 120 秒边界事件用相邻段号合并为一条。为避免长 run 或连续重叠事件链把整夜音频合成一条，最长 run 仅保留开头的边界两段；超过两段的超长安静事件仅保留恢复声附近最后两段，报告仍保留完整事件时长。重叠候选若合并会超过两段，取更强候选。这属于有限留存的代表片段策略，未在交接单中明确，需要审阅，不能视为已验收的 R10 全覆盖。
- healthNotice 仅输出要求的布尔触发结果；固定健康提示文案由后续 App 报告层显示。内核不输出诊断结论。

## 恢复验收

先修复 Swift Testing 插件缺失，再执行 `cd core && swift test`。所有规则测试尤其跨边界逐字段一致性通过后，才能声明 01 完成；随后仍需 Claude 的 fixtures 准确率验收。当前不能进入「测试全过」状态。
