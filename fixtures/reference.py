"""R1–R9 的参考实现（纯 Python，只给验收用，不进 App）。

用途：
1. 生成样本后，用它确认「样本 + 标注」在文档规则下确实得出设计的结果（防止 Claude 自己的样本出错）。
2. 验收时和 Codex 的 snore-analyze 输出对照。

口径与 docs/requirements.md「关键规则」+ codex-handoff-01-core.md「补充 A」一致。
"""
import math
import wave
from array import array

SR = 16000
CFG = dict(
    offset=90.0, floor_window=300, floor_pct=0.10,
    snore_conf=0.5, snore_above_floor=6.0, breath_conf=0.5,
    merge_gap=8, episode_gap=30, quiet_above_floor=3.0,
    pause_min=10, pause_max=90, pre_window=60, pre_min_snore=5,
    recovery_window=5, gasp_above_median=6.0,
    notice_per_hour=5.0, notice_long=30,
)


def read_wav_frames_db(path, offset=CFG["offset"]):
    """每 1 秒一帧，返回约 dB 列表。dBFS = 10*log10(mean(x^2))，x 为 [-1,1] 浮点。"""
    with wave.open(path, "rb") as w:
        assert w.getframerate() == SR and w.getnchannels() == 1 and w.getsampwidth() == 2
        raw = w.readframes(w.getnframes())
    a = array("h")
    a.frombytes(raw)
    out = []
    n = len(a) // SR
    scale = 1.0 / (32767.0 ** 2)
    for k in range(n):
        seg = a[k * SR:(k + 1) * SR]
        ms = sum(v * v for v in seg) * scale / SR
        out.append(10 * math.log10(ms + 1e-12) + offset)
    return out


def pick(sorted_vals, p):
    """线性插值百分位（同 numpy 默认）。"""
    if len(sorted_vals) == 1:
        return sorted_vals[0]
    pos = p * (len(sorted_vals) - 1)
    lo = int(math.floor(pos))
    hi = min(lo + 1, len(sorted_vals) - 1)
    return sorted_vals[lo] + (sorted_vals[hi] - sorted_vals[lo]) * (pos - lo)


def analyze(db, snoring, breathing, delay=0, gaps=(), alarm_at=None, cfg=CFG):
    """db/snoring/breathing：按文件秒对齐的列表。
    gaps：[(file_sec, dur)] —— 喂完 file_sec 秒音频后发生中断 dur 秒（中断没有音频）。
    alarm_at：文件秒，之后的帧不计入。
    报告时间 = 录音开始起的墙钟秒（中断时长计入时间轴）。"""
    n = min(len(db), len(snoring), len(breathing))
    gaps = sorted(gaps)
    # 时间轴：每个元素 (wall_sec, file_idx 或 None 表示中断)
    timeline = []
    wall = 0
    gi = 0
    for k in range(n):
        while gi < len(gaps) and gaps[gi][0] == k:
            for _ in range(int(gaps[gi][1])):
                timeline.append((wall, None))
                wall += 1
            gi += 1
        timeline.append((wall, k))
        wall += 1
    recorded = wall
    gap_sec = sum(int(g[1]) for g in gaps)

    # 噪声底：最近 300 个有音频的帧（含当前）的 10 分位
    floor = [0.0] * n
    hist = []
    for k in range(n):
        hist.append(db[k])
        if len(hist) > cfg["floor_window"]:
            hist.pop(0)
        floor[k] = pick(sorted(hist), cfg["floor_pct"])

    def counted(k):
        return k >= delay and (alarm_at is None or k < alarm_at)

    snore = [counted(k) and snoring[k] >= cfg["snore_conf"]
             and db[k] >= floor[k] + cfg["snore_above_floor"] for k in range(n)]
    quiet = [counted(k) and db[k] < floor[k] + cfg["quiet_above_floor"]
             and snoring[k] < cfg["snore_conf"] and breathing[k] < cfg["breath_conf"] for k in range(n)]
    analyzed = sum(1 for k in range(n) if counted(k))

    # 打呼段（中断一律切断；相邻两个打呼帧起点相差 ≤ 8 秒合并）
    runs = []
    cur = None
    for wall_s, k in timeline:
        if k is None:
            if cur:
                runs.append(cur)
            cur = None
            continue
        if snore[k]:
            if cur and wall_s - cur[1] <= cfg["merge_gap"]:
                cur[1] = wall_s
                cur[2].append(db[k])
            else:
                if cur:
                    runs.append(cur)
                cur = [wall_s, wall_s, [db[k]]]
    if cur:
        runs.append(cur)
    runs_out = [dict(start=r[0], end=r[1], durationSec=r[1] - r[0] + 1) for r in runs]

    # R11 打呼时段：同 R4，但相邻打呼帧起点相差 ≤ 30 秒就合并（中断仍然切断）
    episodes = []
    cur_e = None
    for wall_s, k in timeline:
        if k is None:
            if cur_e:
                episodes.append(cur_e)
            cur_e = None
            continue
        if snore[k]:
            if cur_e and wall_s - cur_e[1] <= cfg["episode_gap"]:
                cur_e[1] = wall_s
            else:
                if cur_e:
                    episodes.append(cur_e)
                cur_e = [wall_s, wall_s]
    if cur_e:
        episodes.append(cur_e)
    episodes_out = [dict(start=e[0], end=e[1], durationSec=e[1] - e[0] + 1) for e in episodes]
    gap_walls_e = {w for w, k in timeline if k is None}
    ep_gaps = [dict(start=a["end"] + 1, end=b["start"] - 1, durationSec=b["start"] - a["end"] - 1)
               for a, b in zip(episodes_out, episodes_out[1:])
               if not any(a["end"] < g < b["start"] for g in gap_walls_e)]

    # 疑似停顿：在时间轴上找连续安静帧段（中断切断）
    wall_of = {k: w for w, k in timeline if k is not None}
    pauses = []
    i = 0
    T = len(timeline)
    while i < T:
        w, k = timeline[i]
        if k is None or not quiet[k]:
            i += 1
            continue
        j = i
        while j < T and timeline[j][1] is not None and quiet[timeline[j][1]]:
            j += 1
        L = j - i
        start_k = k
        if cfg["pause_min"] <= L <= cfg["pause_max"]:
            # 「前 60 秒」按墙钟往回数，中断占掉的秒不补（timeline 下标 = 墙钟秒）
            pre = [db[x] for _, x in timeline[max(0, i - cfg["pre_window"]):i] if x is not None and snore[x]]
            if len(pre) >= cfg["pre_min_snore"]:
                med = pick(sorted(pre), 0.5)
                win = [timeline[x][1] for x in range(j, min(T, j + cfg["recovery_window"]))]
                win = [x for x in win if x is not None and counted(x)]  # 闹钟后的声音不能当恢复声
                rtype = None
                if any(db[x] >= med + cfg["gasp_above_median"] for x in win):
                    rtype = "gasp"
                elif any(snore[x] for x in win):
                    rtype = "resumeSnore"
                if rtype:
                    bucket = "10-20" if L < 20 else ("20-30" if L < 30 else "30+")
                    pauses.append(dict(start=w, durationSec=L, bucket=bucket, recoveryType=rtype))
        i = j

    snore_db = sorted(db[k] for k in range(n) if snore[k])
    longest_run = max(runs_out, key=lambda r: r["durationSec"]) if runs_out else None
    # 不打呼间隔：相邻两段之间，跨中断的不算
    gaps_between = []
    gap_walls = {w for w, k in timeline if k is None}
    for a, b in zip(runs_out, runs_out[1:]):
        if any(a["end"] < g < b["start"] for g in gap_walls):
            continue
        gaps_between.append(dict(start=a["end"] + 1, end=b["start"] - 1, durationSec=b["start"] - a["end"] - 1))
    longest_gap = max(gaps_between, key=lambda g: g["durationSec"]) if gaps_between else None
    per_hour = len(pauses) / (analyzed / 3600) if analyzed else 0.0
    longest_pause = max((p["durationSec"] for p in pauses), default=0)
    minutes = {}
    for w, k in timeline:
        if k is not None and snore[k]:
            minutes[w // 60] = minutes.get(w // 60, 0) + 1
    grid = [dict(minute=m, snoreSec=minutes.get(m, 0)) for m in range((recorded + 59) // 60)]
    return dict(
        snoreEpisodes=episodes_out,
        snoreEpisodeSec=sum(e["durationSec"] for e in episodes_out),
        longestSnoreEpisode=max(episodes_out, key=lambda e: e["durationSec"]) if episodes_out else None,
        longestEpisodeGap=max(ep_gaps, key=lambda g: g["durationSec"]) if ep_gaps else None,
        minuteGrid=grid,
        recordedSec=recorded, gapSec=gap_sec, analyzedSec=analyzed,
        snoreSec=sum(snore), snoreRuns=runs_out, longestSnoreRun=longest_run,
        longestQuietGap=longest_gap, pauses=pauses, pausesPerHour=per_hour,
        longestPauseSec=longest_pause,
        snoreMedianDb=(pick(snore_db, 0.5) if snore_db else None),
        snoreP95Db=(pick(snore_db, 0.95) if snore_db else None),
        envelopeMax=max(db[:n]) if n else None,
        healthNotice=per_hour >= cfg["notice_per_hour"] or longest_pause >= cfg["notice_long"],
    )
