# Codex 交接 03b：「打呼时长」改按时段算 + 片段放大播放

> 03a 真机第二晚（2026-11-06/07，01:07–08:24，7 小时 16 分，无中断）跑通了「夜里只录、早上分析」。用户反馈两点，Claude 已从手机拉数据查清原因。
> 写入范围：`core/`、`ios/`、`docs/codex-handoff-03b-results.md`。`fixtures/` 只读（Claude 已更新）。不联网、不加依赖、不 git commit。命令加 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`。

## 问题 1：「只录了 1 个多小时」——其实是「打呼时长」口径太窄

报告第一行的「打呼时长 69 分」是 `snoreSec`：被判成打呼的**秒数**。一次呼吸约 4–5 秒，鼾声只占 1–1.5 秒，分类器在真实远场录音上还会漏掉一部分（12 段真实片段里每段只有 9–28 秒被判打呼），所以这个数天然只有「打呼那段时间」的三分之一左右，用户（和付费 App 的习惯）理解的是「打呼的那段时间有多长」。
同一晚按「打呼时段」算（相邻打呼帧相隔 ≤30 秒算同一段）：**204 分钟，占 48%**；而 R4（≤8 秒）切出了 515 段、中位 9 秒，「最长连续打呼」也被切碎。

### 新规则 R11 打呼时段（已写进 requirements，参考实现 `fixtures/reference.py` 已实现）

- 和 R4 同样的合并方式，只是阈值 30 秒：相邻两个打呼帧起点相差 ≤ 30 秒归同一时段；中断一律切断。时段时长 = 末帧 − 首帧 + 1。
- 时段里可以包含疑似停顿（≤30 秒的停顿不切断时段），这是有意的：停顿本来就发生在打呼期间。
- R4 的 `snoreRuns`、`snoreSec` 和停顿检测（R6）、留存（R10）**都不改**，只新增字段。

### NightReport 新增字段（命名照这个，`check.py --codex` 按这些名字对照参考实现）

```
snoreEpisodes: [{start, end, durationSec}]   // R11
snoreEpisodeSec                              // 时段合计
longestSnoreEpisode: {start, end, durationSec}?
longestEpisodeGap: {start, end, durationSec}? // 相邻时段之间，跨中断的不算
```

### 界面改动

- 报告第一组数字改为：**打呼时长 = `snoreEpisodeSec`**（「3 小时 24 分，占 48%」）、**最长连续打呼 = `longestSnoreEpisode`**、**最长不打呼间隔 = `longestEpisodeGap`**。
- 原 `snoreSec` 改名「鼾声发声时间」放到次要位置（数字下面一行小字或诊断区），别再放第一行。
- 历史列表、因素对比、时间轴上的打呼强度也改用时段口径（时间轴可以继续用每分钟 `snoreSec` 画深浅，但图例写清楚）。
- 第一行顺便显示「录了多久」（`recordedSec`），用户第一眼要能看到「录了 7 小时 16 分」。

## 问题 2：「录下的声音播放不了」——其实是太小声

Claude 在 Mac 上量了 3 段真实片段（只算数值）：平均 −52 ～ −59 dBFS，峰值只有满幅的 2%–7%，最响的一秒也只有 −38 ～ −46 dBFS。
录音用 measurement 模式关了自动增益（需求单决策 5，为了音量可跨晚对比），所以原始录音本来就小；按手机正常音量放基本听不见。

### 改法：存的原样不动，只在播放时放大

- 播放时把片段解码成 PCM，算增益：让**最响那一秒的 RMS 到 −20 dBFS**，同时**峰值不超过 −1 dBFS**（两者取小），增益上限 +45 dB；用 `AVAudioEngine` + `AVAudioPlayerNode` 播放放大后的缓冲（或先写一个临时的放大版文件再用 `AVAudioPlayer`），**不要改 `clips/` 里的原文件**（以后可能拿它重新分析）。
- 播放时会话用 `.playback`（不在录音时），不要用 measurement 模式；正在录音时不允许播放。
- 片段行显示播放进度和「已放大约 32 dB」这类小字，让用户知道原声本来很小。
- 导出片段时同时导出放大版（文件名加「-放大」），原版也保留。
- 单元测试：拿 `fixtures/real/20261107/clip-165.m4a`（若存在；不存在就跳过）或自造 −58 dBFS 的音频，验证算出的增益让最响一秒 ≈ −20 dBFS、峰值 ≤ −1 dBFS、原文件哈希不变。

## 顺带

- 昨晚的 12 段真实片段已放到 `fixtures/real/20261107/`（不进 git，有隐私），只可读。
- 苹果分类器在这些片段上大部分秒的首位类别是 `music`（可能是房间里的持续底噪），打呼置信度 ≥0.5 的秒只占 8%–23%。**这次不改分类阈值和窗口**，等 Claude 标注更多真实录音再定（另起一期）。

## 交付

- core：`swift test` 全过；`python3 fixtures/check.py --codex` 18/18（现在会因为缺 R11 字段而失败，补上后应全过；R11 与参考实现差 ≤1 秒）。
- ios：`swift test --package-path ios`、模拟器 `xcodebuild test`、`check_demo.py` 全过；重拍报告页截图（第一行看得到「录了多久」和时段口径的打呼时长）。
- 结果写 `docs/codex-handoff-03b-results.md`。不用装真机。
