# SnoreCore

无第三方依赖。Swift Package 提供规则内核及离线命令行；不采集麦克风音频。

```sh
cd core
swift test
swift run snore-analyze /absolute/path/night.wav --offset 90 --delay 0 --chunk 120
swift run snore-analyze /absolute/path/night.m4a --fake-classifier labels.json --chunk 7
```

命令行将任何 AVAudioFile 可解码的音频连续转换为 16 kHz 单声道 Float32；`--chunk` 单位为秒，只改变分析器 `append` 调用边界。JSON 写 stdout，错误写 stderr 并返回非零退出码。文件路径应位于选项前面。

`labels.json` 可用下面任一格式，秒编号从 0 开始。缺省秒的两个置信度均为 0；`breathing` 可省略。置信度必须在 0–1 之间。

```json
[
  {"snoring": 0.9, "breathing": 0.1},
  {"snoring": 0.0, "breathing": 0.0}
]
```

稀疏数组可显式指定 `second`：

```json
[{"second": 12, "snoring": 0.95, "breathing": 0.0}]
```

也支持秒编号为键：

```json
{"12": {"snoring": 0.95, "breathing": 0.0}}
```

真实分类器为苹果 SoundAnalysis `.version1`。每晚复用同一个模型请求、流分析器和 PCM 缓冲，窗口 1 秒、overlap 0。每个完整 1 秒帧使用连续内部模型位置，按回调时间窗索引等待该帧结果，确保分类结果不受调用者切块影响。每帧提取 `snoring` 与 `breathing`。未得到模型结果、模型失败或 30 秒未完成时抛错，避免悄悄将失败当成安静。该同步接口应在后台工作队列使用，不可在音频实时回调中使用。异常或超时后丢弃旧会话，下一次调用重新创建，防止迟到回调和旧错误污染后续帧。真机整夜耗时与能耗仍需后续实测。

可离线复现合成音分类置信度：

```sh
swiftc Sources/SnoreCore/Classifier.swift Validation/classifier-probe.swift -o .build/classifier-probe
.build/classifier-probe
```

此 probe 使用静音、120 Hz 和 440 Hz 纯音；不代表真实鼾声准确率。

01a 补充：R6 安静时长上限为 `AnalyzerConfig.pauseMaximumSec=90`，90 秒仍可计入，超过 90 秒不计入。

CLI 支持 `--gap-at SEC:DUR`（可重复）与 `--alarm-at SEC`，例如：

```sh
swift run snore-analyze night.wav --fake-classifier labels.json --gap-at 120:60 --gap-at 300:15 --alarm-at 500 --chunk 7
```

SEC 均为文件内音频时间，不含中断时长；事件在指定的 16 kHz 样本位置生效，自动拆开输入块。报告时间仍包含中断。假分类器的 second 按文件音频秒对齐。同一位置的事件按参数顺序执行，事件超出文件末尾会报错。闹钟参数只允许一次。
