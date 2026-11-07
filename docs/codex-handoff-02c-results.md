# 02c 起床长按修复结果

2026-11-05 完成。源码修改仅在 `ios/`，另写本结果文档；未联网、未加依赖、未 git commit、未安装真机。

## 修改

- `ios/SnoreLog/Views.swift`：移除起床区域的空 `Button`，使用普通 `VStack`，保留蓝色大胶囊、白字、底部位置与进度条占位。`contentShape(Capsule())` 覆盖胶囊，直接挂 `onLongPressGesture(minimumDuration: 1, maximumDistance: 30, pressing:perform:)`，无 Button 点按竞争。
- 按下时准备轻震并让进度从 0 线性走到 1；不足 1 秒释放或手势取消时，通过禁用动画的 transaction 立即复位、隐藏进度。识别满 1 秒后，先调用 `UIImpactFeedbackGenerator(style: .light).impactOccurred()`，再调用 `state.wake()`。
- 无障碍把整块区域作为一个元素，添加 `.isButton`、标签“起床”及默认 `.accessibilityAction { state.wake() }`。保留 `wakeUp` 标识，放在无障碍元素配置之后，供 UI 测试查询。
- `ios/SnoreLog/CaptureService.swift`：录音会话配置增加 `setAllowHapticsAndSystemSoundsDuringRecording(true)`。本机 Xcode SDK 的 `AVAudioSession.h` 明确说明该项默认 NO，录音输入活跃时需打开才允许触觉反馈；否则仅调用反馈生成器不足以满足“先震再结束”。
- 全工程 Swift 源码搜索 `onLongPressGesture`、`.gesture(`、`simultaneousGesture`、`highPriorityGesture`，排除构建产物后仅发现并修复上述一处，无其他 Button 叠手势写法。

## 验证结果

| 验证 | 最终结果 | 证据 |
| --- | --- | --- |
| `swift test --package-path ios` | 23 项，0 失败 | `ios/Config/02c-host-tests.log` |
| 模拟器 `xcodebuild test` | 23 项单元测试 + 2 项 UI 测试，全部通过；TEST SUCCEEDED | `ios/Config/02c-simulator-final.log`、`ios/.build/02c-tests-final.xcresult` |
| `check_demo.py` | 三组全部通过，完整报告逐字段一致，片段集合准确，分别 12 / 8 / 6 个文件 | `ios/Config/02c-demo.log` |
| `check_copy.py` | 通过 | `ios/Config/02c-copy.log` |

模拟器：iPhone 18 Pro / iOS 27.2。最终模拟器测试包含上述触觉会话配置，未省略 UI 测试。

新增 `DemoScreenshots.testWakeRequiresFullHold` 走“只录音”启动实际 CaptureService（并处理模拟器麦克风授权），不是等待演示自动结束：验证无障碍按钮标签为“起床”，普通点按与 `press(forDuration: 0.2)` 后仍在睡眠中、未打开报告；随后在胶囊宽度 10%、高度 50% 处调用坐标 `press(forDuration: 1.2)`，验证进入当晚报告并退出睡眠中页。此举也覆盖了文字之外胶囊区域的触摸响应。

保留的 `testDemoNightAndScreens` 仍完整验证普通和带闹钟两次 14 号演示、报告、时间轴、历史与设置。该流程本身等待演示自动完成，不负责证明长按可用。已查看本次更新的 `ios/Screenshots/02-recording.png`，蓝色胶囊、白字、底部布局与原图一致。

首轮 UI 测试发现 `.accessibilityElement(children: .ignore)` 使此前配置的 `wakeUp` 标识丢失，两项 UI 查询失败。将标识移到无障碍配置之后后，重跑最终全套通过；首轮失败日志留在 `ios/Config/02c-simulator-tests.log`，最终交付以 `02c-simulator-final.log` 为准。

复现命令（项目根目录）：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path ios
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer python3 ios/Scripts/check_demo.py
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer python3 ios/Scripts/check_copy.py
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project ios/SnoreLog.xcodeproj -scheme SnoreLog \
  -destination 'platform=iOS Simulator,id=A0FE7932-5E22-4CFE-8A0A-74A042615E00' \
  -derivedDataPath ios/DerivedData -resultBundlePath ios/.build/02c-tests-final.xcresult \
  -disableAutomaticPackageResolution -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO
```

重跑时应换一个尚不存在的 resultBundlePath。

## 真机验收边界

UI 测试通过的是 XCTest 合成长按，不能证明 iPhone 15 Pro 上真实触摸可靠，也不能证明实际轻震效果。VoiceOver 默认操作已按要求接入并经源码核对，未运行真机 VoiceOver 双击验收；中途进度的视觉连续性和取消时的复位仍需真机观察。按交接要求未装真机，由后续重装后确认：短按不结束、持续按满 1 秒轻震并停止、VoiceOver 双击能结束。
