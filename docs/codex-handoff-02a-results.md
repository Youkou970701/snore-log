# 02a 返工结果（2026-11-05）

状态：六项返工完成；全量真实分类输出逐字一致；18/18、core/ios测试、演示一致性、模拟器测试及Release编译通过。补齐了02期未能执行的模拟器14号演示和截图。

## 1. 分类器整晚复用与实测

`core/Sources/SnoreCore/Classifier.swift` 现在每晚复用 SNClassifySoundRequest、SNAudioStreamAnalyzer 和PCM缓冲。1秒窗口、overlap0不变。使用内部连续窗口序号匹配回调的timeRange.start，并等待本帧结果，不拿前一帧结果；文件second因delay/gap跳号不会影响内部模型序号。正常路径不会每秒重新加载模型。

超时/失败时移除旧请求并丢弃整个会话，下一次调用重新创建。迟到回调只归旧observer，不能污染新会话；增加mailbox索引、超时和旧会话隔离测试。

修改分类器前先完整执行并保存：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer python3 fixtures/check.py --real
```

改前/改后均退出0，共18行、2587字节。主代理独立读取两文件并逐字节比较，相同，SHA-256均为：

```text
27cd5cd9180e3a85d0bb80a769e600a5fea8f284f70f967c47e356cd52b0c533
```

证据在 `core/Validation/02a-real-before.txt`、`02a-real-after.txt`、各自stderr，以及 `02a-real-comparison.txt`。没有更改check.py或其输出格式。基线全量跑完后才替换生产Classifier。

使用06号语音前120帧，对旧版每帧创建与新版复用同时测量，两类置信度每帧严格 `==`，不使用容差或四舍五入比较：

| 实现 | 平均耗时 |
|---|---:|
| 每帧创建 | 48.7863 ms/帧 |
| 整晚复用 | 2.83918 ms/帧 |

本机该轮约快17.18倍，包含调用开销；不据此推断真机整夜能耗。详见 `02a-classifier-benchmark.json` 和core测试日志。旧实现源码副本、对照测试及复用说明已保留在core。

## 2. 去掉音频块报告重算

`RecordingPipeline.recordedSec` 使用整数样本总数/16000加中断秒数，避免逐块浮点时间累加漂移。NightAnalyzer新增O(1)的latestDb和classifierAverageMs，未增加NightReport字段。

CaptureService.feed/tick不再调用currentReport，UI只收到时长、当前dB、是否中断三个标量。DEBUG演示进度也改为标量。完整报告仅在分段/中断快照、正常结束、意外停止时构建。

## 3. 至少30秒真实缓冲

PCMQueue使用预分配连续帧环形存储，容量为ceil(实际采样率×30秒)，与回调实际是1024/4096/8192帧无关。48kHz约144万帧/声道，96kHz约288万帧/声道。

渲染线程仍只拷贝PCM与更新计数；分析线程消费。溢出秒数累计至diagnostics.droppedSec并markGap，缺失前先排空转换器有效尾样本再reset，避免滤波尾样本跨过缺失边界。引擎恢复或意外停止时无法消费的剩余缓冲也记入丢帧和gap。

## 4. 文件/分类故障降级继续

RecordingPipeline正式模式吞下片段、源AAC编码及快照错误，记录诊断，继续分析输入；DEBUG默认严格抛错，测试可明确注入strictFileErrors:false覆盖正式行为。

- 单候选缺源/编码失败只跳过该候选；已消失的归档也不会继续列作可播放片段。
- 源写失败本段只尝试一次，下段再试，避免每50ms重试与刷日志。
- 文件预算不足时，创建新源文件前预留名额，按时间删除最旧的非留存文件；无法腾出位置就跳过写片段，分析继续。错误列表去重并聚合计数，保留文件峰值。
- 正式模式分类失败按零分类置信度继续计算音量、记录错误，30音频秒后重试；恢复的模型会话不会接收旧回调。故障时这段分类统计可能漏计，诊断可追踪，未修改正常规则阈值。
- 正常结束如存在无法归档的候选，从最终报告retained中去掉，使其与实际clips一致；无故障时完整NightReport与CLI仍一致。

Capture其余运行错误进入重建/重试而非直接fail；确认麦克风权限已撤销才走意外终止。转换器/缓冲创建失败会显式进入恢复，避免静默整晚无分析。

## 5. 没有ended也自动重试

新增可注入RecoverySessionEngine的RecoveryController。仅began、重试失败时保留开始时刻，每30秒尝试一次；收到ended或回到前台立即尝试。真正激活会话和启动引擎成功后才清除中断并markGap，诊断记录实际起点、时长、timer/foreground/notification等恢复方式。

另检测引擎无通知停止，按同一恢复流程处理。媒体服务重置重建引擎。注入假会话测试29秒不试、30/60秒失败、65秒回前台成功，恢复时长65秒且不重复结算。

## 6. 当场部分报告与诊断

NightRecord新增可兼容旧JSON的diagnostics和unexpectedStopReason。意外停止当场调用stopUnexpectedly构建部分报告、封闭可留存音频、记录停止钟点/原因并原子保存，不等待下次冷启动。App以部分NightRecord打开报告，顶部显示“录音在 <时刻> 停止：<原因>”。

若存储当前不可写，仍返回最新内存部分报告并记录保存错误；AppState先用内存结果覆盖同ID旧磁盘快照，避免刚生成的原因被旧数据遮盖。**持续不可写时无法保证当次落盘成功**，此限制没有用吞错伪装为已保存。

诊断内容：中断列表和恢复方式、droppedSec、clipErrors及errorCounts、peakFileCount、classifierAverageMs、后台/前台生命周期、finalBattery。报告最底部DisclosureGroup默认折叠。演示不使用电池/真实模型，所以截图中的最终电量可为“未提供”、分类耗时是假的分类器耗时；真实分类器benchmark单列于上文。未记录额外音内容。

## 验证结果与证据

所有命令均设置 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`。

| 项 | 结果 | 证据 |
|---|---|---|
| core swift test | 22方法、参数化24用例，全过 | core/Validation/02a-core-tests.log |
| fixtures/check.py --codex | 18/18 | core/Validation/02a-codex-check.txt |
| fixtures/check.py --real 前后 | 18组逐字节相同 | core/Validation/02a-real-comparison.txt |
| swift test --package-path ios | 18项XCTest，0失败 | ios/Config/02a-host-final.log |
| check_demo.py | 14、12、12+gap/alarm完整JSON一致，文件集合精确 | ios/Config/02a-demo.log |
| 文案/无网络源码检查 | 通过 | check_copy.py；rg无匹配 |
| 模拟器xcodebuild test | 18单元+1 UI流程，全过 | ios/Config/02a-simulator-tests.log；ios/.build/02a-tests-final.xcresult |
| Release设备SDK仅编译 | BUILD SUCCEEDED，未安装真机 | ios/Config/02a-release-build.log |

新增App韧性测试涵盖：缺源、编码不可写、文件数异常清理、分类失败backoff、即时部分报告+全部诊断、存储不可写仍返回内存报告、旧JSON兼容，以及真实30秒环形缓冲绕回/溢出、无ended的可注入会话恢复。

模拟器命令：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project ios/SnoreLog.xcodeproj -scheme SnoreLog \
  -destination 'platform=iOS Simulator,id=A0FE7932-5E22-4CFE-8A0A-74A042615E00' \
  -derivedDataPath ios/.build/Xcode02a CODE_SIGNING_ALLOWED=NO
```

本机现有iPhone18Pro/iOS27.2。工程补上常规Debug ONLY_ACTIVE_ARCH=YES，避免无关x86_64模块缓存干扰本机arm64模拟器构建。新增SnoreLogUITests同步目录与target，可重复实际14号演示、页面导航和截图，不是假静态界面。

`ios/Screenshots/`已有01–09九张实际PNG：睡前、输入进行中、报告、时间轴、片段、历史、设置、诊断默认折叠/展开。已逐页查看真实保存图片，报告没有提示遮挡、时间轴和片段列表可见。UI额外重跑用于校验展开诊断的数值可见，日志 `ios/Config/02a-ui-final.log`，xcresult为 `ios/.build/02a-ui-final.xcresult`。

## 范围与剩余真机项

仅写ios/、core/和本结果文件；原docs及fixtures定义只读，验收脚本自身按其既定行为产生out临时标注。未联网、未加依赖、未git commit。仍为系统默认样式。

本期没有真机安装或过夜。锁屏8小时连续采集、真实来电恢复、后台系统调度、耗电发热、免费签名下AlarmKit及校准仍留03期实测；模拟器和Mac性能测试不代表这些真机项已经通过。
