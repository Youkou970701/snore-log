# 呼噜记 · 02 App 壳

无第三方依赖，本地路径引用 ../core。系统默认组件，仅睡眠中使用系统深色模式。

所有命令均需设置 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`。

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild build-for-testing -project ios/SnoreLog.xcodeproj -scheme SnoreLog -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path ios
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer python3 ios/Scripts/check_demo.py
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer python3 ios/Scripts/check_copy.py
```

host Swift Package 仅编译 App 使用的共享存储、分段、演示和签名解析源码，便于在没有模拟器运行时的机器上进行额外验证；不能代替模拟器与真机测试。

有可用模拟器后：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project ios/SnoreLog.xcodeproj -scheme SnoreLog -destination 'platform=iOS Simulator,name=<实际可用机型>'
```

DEBUG 启动参数：`-demoNight <wav绝对路径> -demoLabels <CLI格式labels绝对路径> -demoGapAt SEC:DUR -demoAlarmAt SEC`。中断参数可重复；参数均使用文件内音频时间。演示绕过麦克风和闹钟授权，使用与录音共用的 RecordingPipeline，尽快喂完并自动打开报告。不给 labels 时使用苹果分类器。`Scripts/check_demo.py` 从 fixtures 只读加载标注并在系统临时目录转换格式，验证 14/12 两夜及带中断/闹钟的完整报告一致性和实际留存文件。

03a：夜间只采集、计算每秒音量并保存全部两分钟 AAC 源段（32kbps），不创建或调用声音分类器。整夜音频只在分析前临时存在本机，分析完自动删除，只留几段代表片段（最多12条）。仅在前台按段用 SNAudioFileAnalyzer 分类，由同一个 NightAnalyzer 生成报告。每段原子保存规则状态和剩余 PCM；退后台取消当前分类段，重开从已完成段继续。中断和闹钟以采样位置持久化，原始音量单独保存，避免 AAC 压缩改变报告数值。跨边界候选合并归档，最终立即删除 tmp。

从 `Config/Local.example.xcconfig` 复制为 `Config/Local.xcconfig` 后由用户填写开发团队。Local.xcconfig 已忽略。没有 embedded.mobileprovision 时显示开发版。真机安装、签名和到期能力验证由用户负责。

## 02a 录音韧性

UI 进度仅传时长、最近一帧约 dB、中断状态。完整报告只在分段快照、中断快照、结束或意外停止时生成。PCMQueue按真实帧数保证至少30秒；溢出会计入诊断和时间轴中断，转换器先排空缺失前的尾样本再reset。

正式模式编码/快照故障记录诊断，DEBUG默认严格抛错便于测试；测试可注入strictFileErrors:false验证正式行为。分类失败保留待分析状态及全部源音频，重试从上一个成功段继续，不用零置信度冒充结果。若系统存储持续不可写，无法承诺录音或状态落盘成功。

中断没有ended通知时每30秒重试激活会话和引擎；回前台立即尝试；只有成功才结束中断计时。night.json诊断包含中断恢复方式、丢帧秒数、错误聚合、文件峰值、分类耗时、生命周期和最终电量。报告底部默认折叠显示。

本机现有iOS27.2运行时；02a已执行模拟器单元测试和14号演示UI流程，实际截图见Screenshots/。真机8小时后台、来电、AlarmKit、耗电仍需03期验证。
