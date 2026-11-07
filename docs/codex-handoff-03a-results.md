# 03a 执行结果：夜里录音，前台分析

日期：2026-11-06。没有联网、增加依赖、git commit 或安装真机。修改限定在 `ios/`、必要的 `core/` 接口和本文。

## 已实现

- 夜间 `RecordingPipeline` 不创建或调用声音分类器，只采集、计算原始每秒音量、写 16kHz 单声道 AAC 32kbps。全部两分钟源段保留在当晚 `tmp/`，取消原先最多15个活动文件的滚动删除限制。
- 起床、14小时上限或闹钟后两小时结束，只关闭录音并保存「待分析」。后台不启动分析；前台统一调用 `DeferredNightAnalysis`，界面显示百分比，历史/报告显示「打开后分析」。
- 使用 `SNAudioFileAnalyzer` 按完整秒批量分类，再将置信度及录音时保存的原始 dB 送入同一个 `NightAnalyzer`。AAC 是有损格式，因此不从解码 AAC 重算原有音量，保证演示与 CLI 的报告数值一致。真实分类输入是解码后的 AAC；不声称它与压缩前 PCM 的分类置信度相同。
- 每个源段/事件单元保存规则引擎状态、剩余不足一秒 PCM、音量索引、音频与墙钟位置。已完成段不会重分类；退后台取消当前文件分析，未完成单元从上个原子检查点继续。中断、延迟、闹钟、小数秒边界保持连续规则语义。
- 完成后归档最多12条代表片段，跨段候选合并为一条，然后删除整个 `tmp/` 和分析检查点。报告先原子提交，删除期间被杀的残留会在下次启动补清理；分类失败保留源音频和待分析状态，不再用零置信度冒充正常结果。
- 被杀恢复保留临时音频；可读取但尚未写入检查点的最后 AAC 尾部会补回日志。停止原因使用中文；旧版固定英文原因读入时迁移。系统异常原文保留诊断。
- 录音和播放会话增加 `.mixWithOthers`，录音请求 `setPrefersNoInterruptionsFromSystemAlerts(true)`。后台30秒重试保留；后台恢复失败发无声音的本地通知，每晚最多3条、每次中断最多1条。回前台立即尝试恢复，诊断区分后台失败和前台恢复。
- 点睡觉前检查至少1GB剩余空间；延迟选择固定在睡觉按钮上方；隐私文案更新为「整夜录音只在分析前临时存在本机，分析完自动删除，只留几段代表片段」。错误聚合增加首次/末次时间。

## core 变动范围

规则和阈值未修改。`NightAnalyzer` 增加录音音量/置信度回放入口、部分帧计时入口和完整规则状态检查点；`AnalyzerConfig`、`RetentionPool` 增加 Codable。现有 PCM 入口仍供 CLI 使用。

## 耗时与一致性

- Mac 最后一次主机测试：120秒音频，逐帧分类 **0.409557秒**，文件分类（含临时无损文件写入和删除）**0.221721秒**。同时运行模拟器等任务时也观测到文件分类 **0.507867秒/120秒**。按240段线性外推8小时分类约 **53～122秒**；这不是整晚真机实测，也不包含所有报告/归档开销。夜间不分类，原诊断里的分类器耗时为0；本节数据来自独立离线性能测试。
- 按交接单真机 **9.5ms/帧**，8小时逐帧需要 `28800 × 9.5ms = 273.6秒`，约4分34秒，超过3分钟，因此本次已经采用文件批量分析。真机文件模式总耗时需安装后测量，不承诺10秒出报告。
- 文件/逐帧测试使用同一份 PCM、1秒窗口、零重叠：逐帧 snoring/breathing 置信度和完整 `NightReport` 精确相等，拆成两段重新初始化也相等。演示则通过实际 AAC 临时落盘、待分析、归档和清理流程，以假分类器与 CLI 做逐字段比对。

## 验证

全部命令均设置 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`。

| 验证 | 结果 |
| --- | --- |
| `swift test --package-path core` | 22项通过，包含分类器复用对照 |
| `fixtures/check.py --codex` | 18/18通过；运行原 main，标注转换输出改到临时目录，未修改 fixtures |
| `swift test --package-path ios` | 31项通过，0失败 |
| `python3 ios/Scripts/check_demo.py` | 3/3通过；90分钟12条、频繁事件8条、中断+闹钟6条，报告/留存逐字段一致，tmp已删除 |
| `python3 ios/Scripts/check_copy.py` | 通过 |
| 模拟器 `xcodebuild test` | iPhone 18 Pro / iOS 27.2，31项单元测试 + 2项UI测试全部通过 |
| 新增模拟器混音/回放单测 | `testMixedSessionCanPlayDeferredRetainedAAC` 单独运行1/1通过；真实走录音分段、分析留存、mixWithOthers会话、AVAudioPlayer准备与播放 |

新增测试覆盖：录音零分类、后台自动结束仅待分析、检查点重建续算与一次算完/原PCM逐字段一致、跨段及同段小数中断与闹钟、恢复保留tmp、补回最后未checkpoint的可读尾部、分析后删除tmp且留存不超过12、错误首次/末次存盘、后台取消令牌失效、文件/逐帧完整报告一致性。

模拟器完整命令：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project ios/SnoreLog.xcodeproj -scheme SnoreLog -destination 'platform=iOS Simulator,id=A0FE7932-5E22-4CFE-8A0A-74A042615E00' -derivedDataPath /tmp/snore-log-03a-ui-build CODE_SIGNING_ALLOWED=NO
```

首轮UI测试暴露测试定位问题：只录音按钮被固定底栏遮住时 XCTest 仍报告可点击，改为滚动至底栏上方再操作；新增延迟选项的文案断言需等待 SwiftUI 状态更新。修正后完整UI通过；未删除原有断言。快速切回前台时取消任务尚未退出的续算竞争也已修复。

日志保存于 `ios/Config/03a-core-tests.log`、`03a-check-codex.log`、`03a-host-tests.log`、`03a-demo-check.log`、`03a-simulator-tests.log`、`03a-playback-tests.log`。UI截图同时保存在 `ios/Screenshots/`，已核查20分钟延迟文案位于睡觉按钮上方；xcresult 路径记录在模拟器日志末尾。最后补充的崩溃清理会同时删除含少量PCM的 `analysis.json`，已重跑主机全套31/31；回放单测的模拟器编译亦包含该修正。

## 尚需真机验证

本次没有安装真机。今晚仍需验证后台连续录音、其他App混音、真实系统中断及静音通知、恢复录音、AlarmKit、AAC远场识别质量及整晚文件分析耗时。系统回收时尚未封口且无法解码的最后AAC文件无法保证恢复；已完成源段会保留，不能将不可读源文件伪装成正常零打鼾结果。
