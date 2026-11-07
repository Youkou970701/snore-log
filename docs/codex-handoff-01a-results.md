# 01a 返工结果（2026-11-05）

状态：本期交付标准全部通过。

## 修改

- `core/Sources/SnoreCore/Models.swift`：新增 `AnalyzerConfig.pauseMaximumSec=90`，其余规则阈值未改。
- `core/Sources/SnoreCore/NightAnalyzer.swift`：R6 安静时长必须同时满足下限和上限，90 秒可计入，91 秒及更长不计入；删除超长安静事件的末两段留存特例。音频时间与含中断的报告时间分开累计，传给分类器的 second 按文件音频秒计算，不含中断时长。
- `core/Sources/snore-analyze/main.swift`：支持重复的 `--gap-at SEC:DUR` 和单个 `--alarm-at SEC`。事件按文件内位置排序，在准确的 16 kHz 样本位置拆开输入块后调用 markGap/markAlarm；相同位置按参数出现顺序执行。校验非有限/负时间、非正中断时长、重复闹钟参数和超出文件末尾的事件。
- `core/Tests/SnoreCoreTests/RuleTests.swift`：增加 90/91 秒参数化边界测试及中断后分类器按文件秒对齐的回归测试。
- `core/README.md`：补充规则上限和 CLI 参数说明。

## 实际验证

在项目目录执行：

```sh
python3 fixtures/gen.py
python3 fixtures/check.py --codex
```

生成器退出码 0，生成全部 15 个样本，只写文件，没有播放声音。未编辑 fixtures 的脚本、标注或样本定义；仅按要求运行其生成器和验收器（后者还会生成 out 中的临时分类器标注）。

验收脚本退出码 0：**16/16 通过**。包括此前失败的 02、07、10、14，及跨 120 秒边界、resumeSnore、风扇、延迟、健康提示、留存池。每项均通过脚本的期望值对照、参考实现打呼秒数对照及默认/120 秒/7 秒输入完整 JSON 一致性检查。

另在 `core/` 执行指定命令：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

退出码 0。Swift Testing 输出 `Test run with 18 tests in 1 suite passed`，参数化展开共 **20 个用例**：原 17 个，加 90/91 秒两个和分类器文件时间回归一个。整段、120 秒、7 秒、20,003 样本分块的整个 NightReport 及 sorted-key JSON 比较通过。Xcode 工具链解决了此前 TestingMacros 缺失的问题，无需切换系统工具链或绕过测试。

## 范围与限制

生产代码仅修改 `core/`，docs 仅新增本结果文件，未联网、未添加依赖、未 git commit。

本期验证的是规则及流式一致性；合成音和假分类器通过不代表真实远场鼾声识别准确率。07b 的短安静后关门误报仍按规则存在，其验收通过代表与已知预期一致，未擅自改阈值消除它。
