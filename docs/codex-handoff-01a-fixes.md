# Codex 交接 01a：01 返工（Claude 验收后）

> 先读 `docs/codex-handoff-01-results.md`（你自己的报告）和 `fixtures/README.md`。
> 写入范围仍是 `core/`。`fixtures/` 和 `docs/`（除本期结果文件）只读。

## 验收结果（2026-11-05，Claude 用 fixtures 跑的）

`python3 fixtures/check.py --codex`：**12/16 通过**。跨 120 秒边界停顿、整段/120 秒/7 秒分块逐字段一致、resumeSnore、
风扇噪声底、延迟 10 分钟、健康提示阈值都对了。失败 4 个：

| 样本 | 现象 | 原因 |
|---|---|---|
| 02 | 安静 5 分钟后又打呼 → 报了 1 次 301 秒停顿 + 健康提示 | 缺 R6④ |
| 07 | 不打呼 2 分钟后关门 → 报了 1 次 120 秒停顿 | 缺 R6④ |
| 14 | 90 分钟组合夜，安静 15 分钟 → 报了 901 秒停顿，健康提示误触发 | 缺 R6④ |
| 10 | `Unknown option --gap-at` | 命令行缺参数 |

R6④ 是 Claude 原规则漏写，已补进 `requirements.md`。

## 要改的

1. **R6④**：安静时长 > 90 秒的不算疑似停顿（`AnalyzerConfig.pauseMaximumSec = 90`）。
   有了这条，你报告里「超过两段的超长安静事件」的留存特例可以删掉，留存逻辑会简单一些。
   单元测试补：安静 90 秒 + 大喘 → 算；91 秒 + 大喘 → 不算。
2. **命令行加两个参数**：
   - `--gap-at SEC:DUR`（可重复）：喂完文件前 SEC 秒的音频后调用 `markGap(seconds: DUR)`，中断本身没有音频。
   - `--alarm-at SEC`：喂到文件第 SEC 秒时调用 `markAlarm()`。
   - `--fake-classifier` 的 `second` = **音频帧序号**（文件第几秒，不含中断时长）。样本 10 的标注是按这个对齐的。
3. 跑 `swift test`：用户正在装 Xcode。装好后不用 sudo 切换，直接
   `cd core && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`。
   Xcode 还没装完就先做 1、2，测试留到最后；还是跑不起来就照实写，不要绕开。

## 你报告里待确认的解释——Claude 裁定

| 项 | 裁定 |
|---|---|
| breathing 门槛 0.5 | 认可 |
| R4 按两个打呼帧起点差 ≤ 8 秒合并 | 认可（参考实现已改成同样口径） |
| 噪声底用线性插值 P10 | 认可；中位数、P95 也都用线性插值 |
| 分档字符串 `10–20` / `20–30` / `>=30` | 认可，不用改 |
| 内核默认 delay=0，产品默认 600 由 02 期传入 | 认可 |
| 留存只出元数据，文件由 02 期录音层管理 | 认可 |

## 交付

- `python3 fixtures/gen.py`（约 40 秒，460 MB，只写文件不出声）后 `python3 fixtures/check.py --codex` **16/16**。
- `swift test` 全过（含你写的 17 个用例 + 新补的 90/91 秒）。
- 结果追加写到 `docs/codex-handoff-01a-results.md`。不要 git commit。
  （若 `python3` 报 Xcode license 错：用户需先在终端执行 `sudo xcodebuild -license accept`；Codex 不能替用户同意。）
