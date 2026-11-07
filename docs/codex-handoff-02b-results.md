# 02b 界面小修结果（2026-11-05）

七项完成。仅修改ios/，文档仅新增本结果文件；core源代码和fixtures未改。无联网、无新增依赖、无git commit，保持系统默认组件、字体与颜色。

## 改动

1. 睡前页主按钮移入bottom safeAreaInset，使用大号borderedProminent按钮。首屏可见，位于底部标签栏之上；Form随安全区调整并可滚动。延迟统计Picker增加稳定的无障碍标识供UI验收使用。
2. 起床改为屏幕下方的大号系统按钮，与顶部状态分开；普通点击不结束，长按1秒才调用起床操作。按下期间显示从0到1的系统进度条，提前松开或手势取消时清零。
3. 共享DisplayFormat.duration统一报告、睡眠中和历史：24秒→“24 秒”，1610秒→“26 分 50 秒”，5400秒→“1 小时 30 分”；整小时省略零分钟，≥1小时不显示秒。零时长显示“0 秒”。
4. 时间轴横轴改为Date，整点/半点使用本地HH:mm；跨午夜显示23:30、00:00、00:30、01:00。闹钟使用RuleMark虚线和图内文字标注；横轴边缘留出刻度文字空间，避免端点裁切。
5. 片段按最早源段号升序展示，不改变内核留存优先级或报告数组。停顿行使用匹配事件的真实开始钟点和时长；响段使用对应retained分数显示约dB；longestRun显示“最长连续打呼的结尾”。旧记录缺少数字时不编造。截图中可见“23:42 · 疑似停顿 14 秒”“00:20 · 很响 约 62 dB”，按整夜实际时间先后排序。
6. 演示夜按Calendar.current构造2026-11-05本地23:30，不再使用固定UTC瞬间。测试覆盖上海、洛杉矶、UTC。只改变NightRecord日期元数据，不改变NightReport分析结果。
7. 历史行新增“每小时疑似停顿 X 次”和紧凑打呼时长；日期使用入睡当天，按“M 月 d 日 EEE”显示。星期由日历计算，例如2026-11-05实际为周四，没有照文档示例硬写周三。

主要文件：Views.swift、DisplayFormat.swift、DemoRunner.swift；Host Package纳入展示辅助源码；增加DisplayFormatTests并扩展DemoScreenshots UI测试。

## 验证

全部命令带 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`。

- `swift test --package-path ios`：23项XCTest，0失败。包括原18项及新增5项格式/时区/午夜刻度/排序原因数字/极大有限时长回归。日志：`ios/Config/02b-host-tests.log`。
- `python3 ios/Scripts/check_demo.py`：全部通过。14号、12号和12号带中断/闹钟的整个NightReport仍与snore-analyze逐字段相同，实际片段文件集合精确匹配；分别12、8、6个归档。日志：`ios/Config/02b-demo.log`。
- 模拟器 `xcodebuild test`：23项单元测试和1项完整UI流程通过。iPhone18Pro/iOS27.2；UI验证首屏主按钮可点击且在标签栏之上、滚动后延迟选项可操作、起床按钮位于下半屏，并跑普通和带闹钟两次14号演示。
- `python3 ios/Scripts/check_copy.py`：通过；原健康提示和文案限制未改。

模拟器命令：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project ios/SnoreLog.xcodeproj -scheme SnoreLog \
  -destination 'platform=iOS Simulator,id=A0FE7932-5E22-4CFE-8A0A-74A042615E00' \
  -derivedDataPath ios/.build/Xcode02a CODE_SIGNING_ALLOWED=NO
```

最终日志 `ios/Config/02b-simulator-tests.log`，结果包 `ios/.build/02b-tests-delivery.xcresult`。首次UI测试把Picker误当静态文本查询，后改为控件标识验证，没有移除可操作性断言；截图检查又修正了闹钟标注裁切，之后重跑最终全套。

## 重拍截图

`ios/Screenshots/` 中01–09均已重拍；新增：

- `01b-bedtime-options.png`：滚动后延迟选项完整可见，睡觉按钮仍固定。
- `10-timeline-alarm.png`：14号演示附 `-demoAlarmAt 3600`，本地00:30闹钟竖线及图内标注。

已检查实际保存PNG，包括主按钮、时长、时间轴、按时间排列的片段原因数字、历史新行及带闹钟时间轴。起床截图为未按下状态，进度条只在按住期间显示。历史里保留了前期演示生成的7月旧记录，它们的日期没有重写，新演示记录在11月5日。

## 边界

本期没有改动分析规则、录音/恢复或AlarmKit调度。模拟器演示仍使用文件和假分类器；真机麦克风会话下的长按结束、整晚后台录音与响铃继续由后续真机验收验证。
