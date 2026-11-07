# 03b 执行结果：打呼时段与放大播放

日期：2026-11-07。写入仅限 core/、ios/ 和本文；未联网、增加依赖、git commit 或安装真机。所有验证命令均设置 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`。

## 已实现

- R11：相邻打呼帧起点差 ≤30 秒合为时段，中断和闹钟切断证据链。新增 `snoreEpisodes`、`snoreEpisodeSec`、`longestSnoreEpisode`、`longestEpisodeGap`；时段 `end` 为末帧起点，`durationSec = end - start + 1`。相邻时段间的最长间隔排除跨中断候选。R4、R6、R10、分类窗口和阈值保持不变。
- 报告第一行显示「录了多久」，打呼时长及占比、最长连续打呼、最长不打呼间隔使用 R11；「鼾声发声时间」移到小字说明。历史列表和因素对比改用时段占比（分母仍为有效分析秒数）；时间轴保留每分钟发声秒数的颜色，并增加清楚的图例。
- `ClipAmplifier` 解码为 Float PCM，以逐采样滑动一秒窗口寻找最大 RMS；不足一秒按实际长度计算。增益取达到 −20 dBFS 所需增益、峰值 −1 dBFS 限制及 +45 dB 上限的最小值。静音不放大；本来足够响的不压低至 −20，但超出峰值上限时会衰减。
- 播放在后台任务生成临时 `-放大.wav`，使用 `.playback` / `.default` 会话及 AVAudioPlayer，原 clips 文件只读。录音中禁止播放；开始录音、切换片段、离开报告和播放结束时停止并清理临时副本。片段行显示进度、时长和增益，可点击停止。
- 导出包含报告图片、原始片段和对应 `-放大.wav`。与播放共用同一个增益算法；关闭分享面板后清理导出的放大临时文件。
- 兼容旧 NightReport 和旧分析检查点：从 R4 段重建时段，不会因缺新字段丢失历史记录或已处理统计。旧数据只有分钟级中断信息，任何接触中断分钟的合并/间隔候选均保守排除，因此旧中断夜晚可能低估时段；新报告和新检查点使用精确边界。

## 验证

| 验证 | 结果 |
| --- | --- |
| `swift test --package-path core` | 27 项通过，含 R11 30/31秒边界、中断、闹钟、停顿保留、旧报告及检查点兼容 |
| 原 `fixtures/check.py --codex`（只读包装） | 18/18，包含120秒/7秒分块一致性 |
| `swift test --package-path ios` | 37 项通过，0失败；真实片段测试实际执行，无跳过 |
| `python3 ios/Scripts/check_demo.py` | 3/3，通过完整报告逐字段一致、实际留存文件和 tmp 清理 |
| 模拟器 `xcodebuild test` | iPhone 18 Pro / iOS27.2，39项单元测试 + 2项UI测试全部通过 |
| `python3 ios/Scripts/check_copy.py` | 通过 |

模拟器 `xcodebuild test` 已通过：单元测试39/39、UI测试2/2，0失败。报告页已重拍并查看实际PNG：`ios/Screenshots/03-report.png`，首行录音1小时30分，R11打呼1小时4分/72.1%，次要发声26分50秒，最长连续44分56秒、最长间隔15分1秒（90分钟合成演示数据）。fixtures 全部78个文件的SHA256清单前后完全一致（含真实录音），无新增/删除。

`python3 ios/Scripts/check_copy.py`：通过。

真实 `fixtures/real/20261107/clip-165.m4a` 数值：增益 **25.214648 dB**，放大后最响一秒 **−20.0000004 dBFS**，峰值 **−7.699182 dBFS**；原文件 SHA256 不变。

合成测试覆盖 −58 dBFS → −20 dBFS、跨整数秒边界的最响一秒、峰值优先、+45 dB 上限、短片、静音、超峰衰减。首轮跨秒测试使用的非标准 1000Hz 被 AVAudioFile 钳为8000Hz，实际不足一秒；已改用16000Hz并断言真实文件采样率与2秒长度，保留严格+40dB断言。算法未因测试而放宽。模拟器集成测试验证实际放大播放、进度、会话类别和录音防护。

`fixtures/check.py` 原入口会写 labels 到 fixtures/out，因此使用 `core/Validation/check_codex_readonly.py` 调用未修改的 checker，只将 labels 输出重定向系统临时目录；通过 `PYTHONDONTWRITEBYTECODE=1` 禁止 Python 缓存写入 fixtures。

日志：`core/Validation/03b-core-tests.log`、`core/Validation/03b-codex-check.log`、`ios/Config/03b-host-tests.log`、`ios/Config/03b-demo-check.log`、`ios/Config/03b-simulator-tests.log`。

真机扬声器实际听感、整晚运行和系统中断仍需后续真机验证；本次没有安装真机。

最终模拟器命令：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project ios/SnoreLog.xcodeproj -scheme SnoreLog -destination 'platform=iOS Simulator,id=A0FE7932-5E22-4CFE-8A0A-74A042615E00' -derivedDataPath /tmp/snore-log-03b-ui-build CODE_SIGNING_ALLOWED=NO
```

最终 xcresult：`/tmp/snore-log-03b-ui-build/Logs/Test/Test-SnoreLog-2026.11.07_10-21-07-+0800.xcresult`。首轮报告行在SwiftUI辅助功能树中无法按裸标题定位，现为录音时长/时段时长提供稳定标识，并断言其可见、录音时长和占比文案；完整UI重跑通过。最终再次核对fixtures全部78个文件哈希不变。
