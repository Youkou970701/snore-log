# Codex 交接 02c：真机上长按「起床」没反应（急，今晚要用）

> 2026-11-05 已装到用户 iPhone 15 Pro 真机。**闹钟正常响**；但睡眠中页长按「长按 1 秒起床」按多久都结束不了录音。
> 写入范围：`ios/` + `docs/codex-handoff-02c-results.md`。不联网、不加依赖、不 git commit。**不用你装真机**，改完 Claude 重装给用户测。

## 原因（Claude 读代码判断）

`SleepView`（`ios/SnoreLog/Views.swift` 约 90–104 行）是 `Button {} label: {...}` 再挂 `.onLongPressGesture(minimumDuration: 1, ...)`。
真机上 `Button` 自带的点按手势先拿到触摸，长按手势收不到；模拟器 UI 测试用 `press(forDuration:)` 合成事件，正好绕过，所以测试全过、真机失灵。

## 要改的

1. 去掉 `Button`，换成普通视图（同样的蓝色大胶囊外观、白字，`contentShape` 覆盖整个胶囊）+ `onLongPressGesture(minimumDuration: 1, maximumDistance: 30, pressing:perform:)`。
   不要用 `Button` + `simultaneousGesture` 之类的组合，真机上同样不可靠。
2. 按住时进度条从 0 走到 1（现在的 `ProgressView` 保留），松手不足 1 秒就复位；满 1 秒时轻震一下（`UIImpactFeedbackGenerator`）再结束。
3. 无障碍：`.accessibilityAddTraits(.isButton)` + `.accessibilityLabel("起床")` + `.accessibilityAction { state.wake() }`，VoiceOver 用户双击也能结束。
4. 全工程搜一遍有没有别的 `Button` 上叠手势的写法（`onLongPressGesture` / `gesture(` / `simultaneousGesture`），有就一起改。
5. UI 测试里的起床步骤保持能过；在结果里写清楚测试是怎么触发的（合成长按不能证明真机可用，这点照实写）。

## 交付

`swift test --package-path ios`、模拟器 `xcodebuild test`（含 UI 测试）、`check_demo.py` 全过；结果写 `docs/codex-handoff-02c-results.md`。
