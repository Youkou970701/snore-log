# Codex 交接 02：iOS App 壳

> 先读 `docs/requirements.md`（模块表、红线、已拍板）、`core/README.md`、`fixtures/README.md`。
> 01 分析内核已验收（18/18 样本、20 个单元测试）。本期把它装进 iPhone App：录音 → 分段 → 留存 → 闹钟 → 报告。
> **本期不做视觉设计**：一律用系统默认组件和颜色，别自定义配色、字体、插画。视觉放在 04 期，由用户挑方案。

## 写入范围

- `ios/`：新建 App 工程（全部 App 代码和测试）。
- `core/`：只允许做本文「一、内核小改」列的三处修改，改完 `swift test` 和 `check.py --codex` 必须仍然全过。
- `docs/codex-handoff-02-results.md`：结果报告。
- `fixtures/`、其余 `docs/` 只读。不联网、不加第三方依赖、不 git commit。

## 环境

- Xcode 27.2 已装且已同意许可。命令行一律加 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`（系统默认还指向命令行工具）。
- iOS 27.2 模拟器运行时**可能还在下载**。`xcrun simctl list runtimes` 没有 iOS 时，先用
  `-destination 'generic/platform=iOS Simulator'` 只编译，把需要模拟器的验证留到最后；仍没有就照实写进报告。
- 你只能用模拟器。**真机安装、AlarmKit 真机测试、过夜录音由用户和 Claude 做**，不要尝试。
- **AlarmKit 的 API 以 SDK 里的接口文件为准，不要凭记忆写**：
  `find /Applications/Xcode.app -path "*iPhoneOS.sdk*" -name "*.swiftinterface" | grep -i alarmkit`。

---

## 一、内核小改（core/）

1. **platforms 改成 `.iOS(.v26)`**（用户手机 iOS 27.0.1，已拍板最低部署 iOS 26）。macOS 保持不变。
2. **longestRun 留存改为「run 结束处的末两段」**。原因：App 录音时内存/磁盘里只留最近 3 段音频，
   你现在的「run 开头两段」在 run 变成最长时早已删掉，根本留不下来。
   新规则：**所有留存候选只能指向「提名那一刻的当前段及前 2 段」之内的段号**。停顿（安静 ≤90 秒 + 5 秒恢复窗）和响段天然满足；
   longestRun 在 run 结束（超过 8 秒没有新打呼帧）时提名，指向 run 最后打呼帧所在段及前一段。
   加单元测试：任意时刻 `retention` 里新出现的段号 ≥ 当前段号 − 2。
3. **加 `currentReport() -> NightReport`**：不结束分析、不改变状态，返回到目前为止的报告。App 每段结束时存一份快照，
   App 被系统杀掉后能拿它出「部分报告」。加测试：中途调 `currentReport()` 不影响最终 `finish()` 的结果（与不调时逐字段相同）。

---

## 二、工程

- `ios/SnoreLog.xcodeproj`，App target `SnoreLog`，测试 target `SnoreLogTests`。显示名「呼噜记」。
  手写 pbxproj 时用 Xcode 16+ 的文件夹同步（`PBXFileSystemSynchronizedRootGroup`），新增文件不用改工程文件。
- Bundle ID `$(BUNDLE_ID_PREFIX).snorelog`（前缀在 `Local.xcconfig` 里配）。**`DEVELOPMENT_TEAM` 留空**，从 `ios/Config/Local.xcconfig` 读（加进 `.gitignore`，
  提供 `Local.example.xcconfig`）。用户用免费 Apple ID 签名时自己填。
- 以本地路径依赖 `../core` 的 `SnoreCore`。
- 最低部署 iOS 26.0，仅 iPhone，竖屏。
- Info.plist：`NSMicrophoneUsageDescription`（「整夜录下打呼声用于分析，录音只存在本机」）、AlarmKit 用途说明、
  `UIBackgroundModes = audio`。**不申请任何网络相关能力，代码里不许出现 URLSession / Network 框架。**

## 三、录音与分段（核心，最容易出事的一块）

| 项 | 要求 |
|---|---|
| 音频会话 | `.playAndRecord`（要在报告页回放留存片段）+ mode `.measurement`（关自动增益）。录音时固定用内建麦克风（`setPreferredInput`），插耳机/连蓝牙不切换 |
| 采集 | `AVAudioEngine` input tap → `AVAudioConverter` 转 16 kHz 单声道 Float32。**转换器跨 buffer 复用、不丢样本**（流式转换的尾巴要接上，否则一晚累积漂移） |
| 分析 | 单独串行队列调用 `NightAnalyzer.append`，不在音频线程上跑分类器。音频线程只往环形缓冲写 |
| 分段 | 每满 120 秒音频关闭一段：AAC 32 kbps 编码到 `nights/<夜ID>/tmp/seg-<段号>.m4a`，再存一份 `currentReport()` 快照 |
| 留存 | 每段关闭后读 `retention`：段号在留存里 → 移到 `clips/`；不在留存且早于「当前段 − 2」→ 删除。**任何时刻磁盘上的片段 ≤ 12 + 3 个**。被挤出留存池的片段也要删 |
| 中断 | 监听 `interruptionNotification`：开始时记时间并暂停写入；结束后重启引擎，调用 `markGap(seconds:)`。`mediaServicesWereReset` 时重建整个引擎。中断时段在报告时间轴上标灰 |
| 闹钟后 | 到闹钟时间调用 `markAlarm()`（按设定时间算，不依赖 AlarmKit 回调）。闹钟后 2 小时仍没点「起床」→ 自动结束 |
| 上限 | 一晚最长 14 小时，到了自动结束 |
| 结束 | 「起床」→ 停引擎 → `finish()` → 写 `night.json` → 删掉 `tmp/` → 进报告页 |
| 被杀恢复 | 启动时发现有夜晚没正常结束：用最后一份快照生成报告，顶部写「录音在 03:12 意外停止」（钟点用快照时间），保留已留存的片段 |

## 四、闹钟（AlarmKit）

- 睡前页设时间（默认上次的时间）、贪睡开关（默认开，9 分钟）。点「睡觉」时请求授权并调度；拒绝授权要在睡前页明确提示「闹钟不会响」，但仍允许只录音。
- 闹钟界面：主按钮「关闭」，副按钮「贪睡」（开了才有）。关闭后录音继续，直到用户点「起床」或闹钟后 2 小时自动结束。
- 用户点「起床」时取消所有未响的闹钟（含贪睡）。
- **免费签名 7 天到期**（已拍板，最大的坑）：从 App 包里的 `embedded.mobileprovision` 读 `ExpirationDate`
  （文件是签名包装的 plist，找到 `<?xml` 到 `</plist>` 截出来解析即可）。
  - 设置页显示「本次安装 11 月 12 日 14:03 到期」。
  - 到期前一天 20:00 发本地通知「呼噜记明天到期，记得连 Mac 重新安装」。
  - **点「睡觉」时如果到期时间早于闹钟时间，弹窗拦住**：「今晚会过期，过期后闹钟不会响。先重新安装再睡。」可以选「仍然只录音」。
  - 模拟器/调试包里没有这个文件 → 显示「开发版，无到期限制」，别崩。

## 五、页面（功能齐全即可，系统默认样式）

1. **首次引导**（一页）：手机放床头、离头 30–50 厘米、插电、麦克风朝床；同床有人打呼会算进去；录音只存在本机；这不是医学诊断。
2. **睡前**：闹钟时间、贪睡、今晚因素（多选：喝酒 / 感冒鼻塞 / 很累 / 侧睡 / 吃了宵夜 / 戴了止鼾贴）、延迟开始统计（0/10/20/30 分钟，默认 10）、大按钮「睡觉」。
   提醒条：电量 < 50% 且没插电、麦克风未授权、闹钟未授权、安装快到期。
3. **睡眠中**：深色背景、已录时长、当前约 dB（1 秒刷新）、状态（录音中 / 中断中）、「起床」按钮**长按 1 秒**才生效（防误触）。不常亮屏幕，用户自己锁屏。
4. **报告**：
   - 顶部：`healthNotice` 为真时显示 requirements 红线 1 的**固定原文**，一字不改。
   - 数字：录了多久、打呼总时长和占比、最长连续打呼（钟点起止）、最长不打呼间隔、疑似停顿次数（按 10–20 / 20–30 / ≥30 秒分档）、每小时次数、最长一次、打呼音量「约 XX dB」（中位数和 P95）。
   - 时间轴（Swift Charts）：每分钟一格，颜色深浅 = 打呼秒数，红点 = 疑似停顿，灰 = 中断，闹钟时刻一条竖线。
   - 留存片段列表：钟点、原因（疑似停顿 / 很响 / 最长连续打呼）、播放、收藏。
   - 当晚因素标签。
5. **历史**：按日期倒序；点进去看报告。下方「因素对比」：对每个因素，有这个因素的晚上 vs 没有的晚上，比较打呼占比、每小时疑似停顿、P95 音量的平均值，并写出各自晚数；任一边少于 3 晚显示「晚数太少，先别下结论」。
6. **设置**：音量校准偏移（步进 1，默认 90，旁边写「拿分贝计 App 对照一次」）、留存天数（默认 14）、本次安装到期时间、导出某晚（报告截图 + 留存片段 m4a，走系统分享面板）、重看引导。

## 六、存储

- `Application Support/nights/<yyyyMMdd-HHmmss>/night.json`（开始/结束时间、闹钟、因素、延迟、偏移、NightReport、片段列表及收藏标记）+ `clips/*.m4a`。不用 SwiftData/Core Data。
- 启动时清理：超过留存天数的夜晚删掉**未收藏的片段**，报告保留。
- 偏移改了只影响以后的夜晚，不重算历史（报告里存着当晚用的偏移）。

## 七、文案红线（写测试强制）

- 单元测试扫描 `ios/` 下全部 Swift 源码和字符串资源，出现以下任一即失败：呼吸暂停综合征、AHI、重度、中度、轻度、确诊、诊断为、治疗、止鼾产品推荐类字样。
  （引导页的「这不是医学诊断」允许，测试里列白名单。）
- 健康提示文案做成单一常量，测试断言它与 requirements 原文逐字相同。
- 音量一律写「约 XX dB」。

## 八、演示夜（验收必需）

模拟器没有真实的夜晚，要有一条**不经过麦克风、但走同一条分段/留存/报告管线**的路径：

- 仅 DEBUG：启动参数 `-demoNight <wav 路径> [-demoLabels <labels.json>] [-demoGapAt SEC:DUR] [-demoAlarmAt SEC]`，
  App 启动后自动「睡觉」，把文件按音频时间尽快喂入（不按真实时间等待），喂完自动「起床」并打开报告。
  `-demoLabels` 用的格式与 `snore-analyze --fake-classifier` 相同；不给就用真实分类器。
- 演示夜的「钟点」= 一个固定的开始时间（如 23:30）加音频秒，方便截图。
- **一致性要求**：同一个 wav + labels，演示夜得出的 `NightReport` 与 `snore-analyze` 命令行输出逐字段相同（`startDate` 之类元数据除外）。写一个测试或脚本证明，至少用 `fixtures/out/14_composite_90min.wav` 和 `12_frequent.wav`。
- 演示夜结束后，`clips/` 里的文件 = 报告 `retained` 指向的段，一个不多一个不少；过程中任何时刻片段数 ≤ 15。

## 九、测试与交付

- `cd core && swift test` 全过；`python3 fixtures/check.py --codex` 18/18。
- `xcodebuild test -project ios/SnoreLog.xcodeproj -scheme SnoreLog -destination 'platform=iOS Simulator,name=<可用机型>'` 全过。至少覆盖：
  分段/留存文件管理（用假分析器，含被挤出池、跨段事件、≤15 个）、中断计时、闹钟后 2 小时自动结束、14 小时上限、
  被杀恢复、到期时间解析（自造一个 mobileprovision 样例）与「今晚会过期」判断、因素对比（含少于 3 晚）、文案红线、演示夜一致性。
- `grep -rn "URLSession\|import Network" ios/` 无结果。
- 模拟器里跑一遍 14 号演示夜，截图：睡前页、睡眠中、报告页（含时间轴和片段列表）、历史页、设置页，存 `ios/Screenshots/`。
- 结果写 `docs/codex-handoff-02-results.md`：做了什么、和本文不一致的地方及原因、没验证到的（真机项一律列出来）。

## 十、留给真机验证的（不用你做，报告里列出相关代码位置即可）

1. 锁屏后台连续录 8 小时不断、分类器在后台能跑、耗电和发热。
2. AlarmKit 在免费签名下能调度、静音键和专注模式下会响、贪睡正常。
3. 来电打断后自动恢复。
4. 校准偏移的默认值 90 是否合理（用户拿分贝计对照）。
