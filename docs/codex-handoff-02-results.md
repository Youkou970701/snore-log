# 02 App 壳实现结果（2026-11-05）

状态：App 与测试包编译通过；内核、共享管线及演示一致性验证通过。**本机没有 iOS 模拟器运行时，模拟器执行和截图未完成，不能宣称第九节全部验收通过。**

## 写入范围

新增 `ios/`；内核仅修改 `Package.swift`、`NightAnalyzer.swift` 及相关规则测试；文档仅新增本文件。未修改 fixtures 的脚本、标注和样本定义，未联网、未添加第三方依赖、未 git commit。运行原有验收脚本时，其既定行为会写 fixtures/out 的临时 CLI 格式标注；未手动改写 fixtures。

所有执行命令均设置 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`，没有改变系统 xcode-select。

## 已实现

- `ios/SnoreLog.xcodeproj`：App `SnoreLog`、测试 `SnoreLogTests`，同步文件夹、本地 `../core` 包，iPhone/iOS26/竖屏，显示名呼噜记。DEVELOPMENT_TEAM 默认空，通过已忽略的 Local.xcconfig 配置，附示例。
- `NightStore.swift`：Codable JSON 夜晚记录、收藏、仅删除过期未收藏音频、原子快照、未正常结束时恢复部分报告，清理孤儿文件。恢复时过滤未实际存在的片段，避免崩溃发生在候选替换中间时留下失效播放项。
- `RecordingPipeline.swift`：同一管线供录音与演示使用，120秒网格分段、AAC32kbps、候选归档、滚动最近三段、currentReport 快照、finish 清理 tmp。跨段候选合为一个实际 clips 文件，最多12个归档和3个源段；驱逐先于替换写入，避免临时超限。纯中断网格没有源音频，不补造PCM，候选包含此网格时只归档实际存在的一侧。
- `CaptureService.swift`：AVAudioEngine、playAndRecord/measurement、优先内建麦克风并在路由变化时重申；音频回调只向预分配有界环形缓冲复制PCM，串行队列复用转换器转16k单声道、分析和写文件；转换器中断/结束时排空尾部。环形缓冲过载作为缺失时段处理。中断开始记录通知时间，恢复时 markGap，媒体服务重置重建引擎；按设定钟点 markAlarm，闹钟后2小时或开始14小时结束。
- `AlarmService.swift`：按 SDK AlarmKit `.swiftinterface` 实现授权、固定钟点、9分钟贪睡、取消闹钟；拒绝/失败时保留录音并显示闹钟不会响。
- `Provisioning.swift`：签名包装 plist 的 ExpirationDate 解析、开发包缺失兼容、过期早于闹钟的拦截与仅录音选项；本地到期前一天20:00提醒在 AlarmService。
- `AppState.swift` / `Views.swift`：引导、睡前参数、因素、睡眠中每秒音量/状态、长按1秒起床、报告数字及 Swift Charts 时间轴、片段播放收藏、历史与因素均值及晚数提示、设置、截图+片段系统分享。系统默认组件和颜色，睡眠中使用系统深色模式，不常亮屏幕。
- `DemoRunner.swift`：DEBUG App参数绕过麦克风，固定开始时间、快速文件输入、可选假分类器/中断/闹钟，共用 RecordingPipeline，自动结束打开报告。段级进度回调不改变分析状态。

## 内核三处修改

1. platforms iOS26；`.v26` 要求 PackageDescription6.2，因此 tools-version 同步升至6.2，macOS版本不变。
2. longestRun 仅结束时提名最后打呼帧所在段及前段，不再从 getter 提名尚未结束的run。滚动窗口测试发现临时响段 getter 会让曾被挤出的旧候选重新出现，因此改为持久滚动提名，保证“新出现段号在当前段及前两段内”。滚动候选保留较强提名分数，报告音量P95计算及R1–R10数值阈值未改。
3. currentReport 走只读报告构建器，包含正在进行的run、已录尾帧时间，不关闭run、不提交留存事件、不改变最终finish结果。

## 已完成的实际验证

### 内核

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path core
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer python3 fixtures/check.py --codex
```

20个Swift Testing方法、参数化22用例全过；样本 **18/18** 全过。包括新候选滚动窗口、反复currentReport不影响finish，以及原有整段/120秒/7秒/非整秒分块完整报告一致性。

### iOS 编译

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild build-for-testing \
  -project ios/SnoreLog.xcodeproj -scheme SnoreLog \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath ios/.build/Xcode CODE_SIGNING_ALLOWED=NO
```

**TEST BUILD SUCCEEDED**。此前普通 build 同样成功。App和测试bundle实际编译完成，日志分别在 `ios/Config/build.log`、`build-tests.log`（构建日志已忽略）。

### 共享 App 管线测试

额外提供 `ios/Package.swift`，直接编译 App 的同一份非UI源码，供无模拟器时进行补充验证，不是模拟器测试替代品。

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path ios
```

9项 XCTest 全过：实际AAC20段滚动/驱逐/≤15文件/最终精确集合、跨边界停顿合并一条、中断计时及2h/14h边界、崩溃恢复、收藏和过期清理、因素均值与不足3晚、mobileprovision包装解析与到期判断、固定健康原文、全Swift/字符串资源红线扫描。最新运行9项0失败，日志 `ios/Config/host-tests.log`。

### 演示夜与 CLI 逐字段一致性（必须项）

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer python3 ios/Scripts/check_demo.py
```

使用同一 wav + labels，执行实际 RecordingPipeline/AAC文件管理后，将 **NightRecord.report 整个JSON对象** 与 snore-analyze 输出比较，不剔除或放宽任何 NightReport 字段：

| 场景 | 完整报告 | 最终clips实际文件 |
|---|---|---|
| 14_composite_90min | 相同 | 12个，与retained逐条对应 |
| 12_frequent | 相同 | 8个，与retained逐条对应 |
| 12_frequent + gap200:60 + alarm800 | 相同 | 6个，与retained逐条对应 |
| 12_frequent + gap200:600（跨多个纯中断段） | 相同 | 9个，与retained逐条对应 |

脚本同时检查文件名集合、候选段号集合完全相同、没有多余文件、tmp已移除；管线内部持续强制≤15文件，越界抛错使验证失败。输入只读 fixtures，转换标注和输出放系统临时目录。不播放声音。

文案脚本 `ios/Scripts/check_copy.py` 通过；`rg -n 'URLSession|import Network' ios/SnoreLog ios/SnoreLogTests` 无结果（退出1表示无匹配），未申请网络相关能力。

## 与文档的差异和未完成验收

- 开始及最终两次 `xcrun simctl list runtimes` 均只有空的 `== Runtimes ==`；设备列表同样为空。没有联网下载运行时。因此未执行需要具体设备的 `xcodebuild test`，未在模拟器App内跑14号演示，也没有睡前/睡眠中/报告/历史/设置截图。`ios/Screenshots/README.md` 明确记录缺失，没有用其他图替代。
- 同一份 App 非UI管线已通过 macOS host 执行一致性；这不代表 iOS 界面或模拟器进程已实际运行。运行时安装完成后，需执行 README 中的模拟器测试、用 DEBUG 参数跑14号演示并截图，才能完成第九节。
- 源段ID按报告120秒墙钟网格对齐，中断不占音频、允许留下空段号，因此含中断的源段可能少于120秒实际音频；普通连续录音仍每120秒关闭。这样保持留存段号、时间轴和CLI一致。
- 存储测试注入假分类器并运行真实分析器/真实AAC存储，覆盖完整集成路径，而不是仅用假的分析器。
- SDK26.1起 AlarmPresentation.Alert 的自定义 stopButton 初始化器已弃用，系统控制主按钮；代码为26.0兼容保留“关闭”标签，26.1+是否采用该标签不能由App保证。贪睡通过SDK提供的countdown secondaryButton/postAlert540秒实现。
- 演示CLI比较和共享管线测试通过不说明苹果分类器对远场真实鼾声的准确率。未做额外模型或阈值调整。

## 必须留给真机的验证及代码位置

1. 锁屏8小时、后台分类、耗电发热：CaptureService 的环形缓冲/串行转换分析、Info.plist audio后台模式。也需确认路由变化时内建麦克风偏好持续有效。
2. 免费签名、静音/专注响铃、停止和贪睡：AlarmService；签名到期、安装提醒与仅录音拦截：Provisioning及AppState/BedtimeView。
3. 来电实际打断/自动恢复、媒体服务重置：CaptureService.handleInterruption及通知监听。
4. 默认偏移90真机对照分贝计：SettingsView校准项及每晚持久化的offsetDb。

没有尝试真机安装、签名、调试或过夜录音。
