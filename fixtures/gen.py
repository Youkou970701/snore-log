"""生成验收样本：合成音频 + 假分类器标注 + 设计期望。

    python3 gen.py            # 生成全部（out/ 下 wav 约 600 MB，已 gitignore）
    python3 gen.py 01 08      # 只生成编号前缀匹配的

只写文件，不播放任何声音（say 用 -o 输出到文件）。
产物：
    out/<id>.wav               16 kHz 单声道 16 bit
    labels/<id>.labels.json    {"snoring": [...], "breathing": [...]}，按文件秒对齐
    cases/<id>.json            运行参数 + 期望值（容差见各字段）
"""
import json
import math
import os
import random
import subprocess
import sys
import wave
from array import array

SR = 16000
OFFSET = 90.0
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "out")
LAB = os.path.join(HERE, "labels")
CASES = os.path.join(HERE, "cases")


def rms_norm(x, db):
    """把片段整体 RMS 归一到「约 db」（= dBFS + 90）。"""
    ms = sum(v * v for v in x) / len(x)
    target = 10 ** ((db - OFFSET) / 20)
    g = target / math.sqrt(ms + 1e-20)
    return array("f", (v * g for v in x))


def env(n, attack, release):
    a, r = int(attack * SR), int(release * SR)
    out = []
    for i in range(n):
        e = 1.0
        if i < a:
            e = 0.5 - 0.5 * math.cos(math.pi * i / a)
        elif i > n - r:
            e = 0.5 - 0.5 * math.cos(math.pi * (n - i) / r)
        out.append(e)
    return out


class Tl:
    def __init__(self, dur, seed, floor_db=30.0):
        self.dur = dur
        self.rng = random.Random(seed)
        self.events = []  # (kind, t0, t1)
        loop = self._pink(10 * SR)
        loop = rms_norm(loop, floor_db)
        n = dur * SR
        reps = n // len(loop) + 1
        self.x = (loop * reps)[:n]
        self._snores = [self._snore_tpl() for _ in range(8)]

    # ---------- 声音模板 ----------
    def _white(self, n):
        g = self.rng.gauss
        return [g(0, 1) for _ in range(n)]

    def _pink(self, n):
        w = self._white(n)
        out, y = array("f"), 0.0
        for v in w:
            y = 0.97 * y + 0.03 * v
            out.append(y + 0.15 * v)
        return out

    def _snore_tpl(self, dur=1.3):
        n = int(dur * SR)
        f0 = self.rng.uniform(70, 110)
        ph = [self.rng.uniform(0, 2 * math.pi) for _ in range(12)]
        e = env(n, 0.3, 0.4)
        w = self._white(n)
        out, y = [], 0.0
        for i in range(n):
            t = i / SR
            h = sum(math.sin(2 * math.pi * f0 * (k + 1) * t + ph[k]) / (k + 1) for k in range(12))
            flutter = 1 + 0.7 * math.sin(2 * math.pi * 28 * t)
            y = 0.9 * y + 0.1 * w[i]
            out.append(e[i] * (h * flutter + 2.0 * y))
        return out

    def _add(self, t0, sig, db, kind, dur=None):
        sig = rms_norm(sig, db)
        s = int(t0 * SR)
        x = self.x
        for i, v in enumerate(sig):
            j = s + i
            if j >= len(x):
                break
            x[j] += v
        self.events.append((kind, t0, t0 + (dur if dur else len(sig) / SR)))

    # ---------- 事件 ----------
    def snore(self, t0, t1, db=52.0, period=4.0):
        """t0 起每 period 秒一声鼾，最后一声在 t1 前结束；返回最后一声的结束时刻。"""
        t, last = t0, t0
        while t + 1.3 <= t1:
            tpl = self.rng.choice(self._snores)
            self._add(t, tpl, db + self.rng.uniform(-1.5, 1.5), "snore")
            last = t + 1.3
            t += period + self.rng.uniform(-0.3, 0.3)
        return last

    def gasp(self, t, db=64.0):
        n = int(1.5 * SR)
        w = self._white(n)
        e = env(n, 0.05, 0.6)
        out, y = [], 0.0
        for i in range(n):
            y = 0.6 * y + 0.4 * w[i]
            snort = math.sin(2 * math.pi * 60 * i / SR) * 3 if i < 0.4 * SR else 0
            out.append(e[i] * (y + snort))
        self._add(t, out, db, "gasp")
        return t + 1.5

    def snore_with_pauses(self, t0, t1, pauses, db=52.0, recovery="gasp"):
        """在 [t0,t1) 里打呼，pauses = [(大约开始时刻, 安静秒数)]。
        返回实际停顿 [(安静开始=最后一声结束, 秒数)]。"""
        actual, t = [], t0
        for (ps, d) in pauses:
            last = self.snore(t, ps)
            q_start = last
            if recovery == "gasp":
                end = self.gasp(q_start + d)
                t = end + 1.5
            else:
                t = q_start + d
            actual.append((q_start, d))
        self.snore(t, t1, db)
        return actual

    def breath(self, t0, t1, db=34.0, period=4.0):
        t = t0
        while t + 1.6 <= t1:
            n = int(1.6 * SR)
            w = self._white(n)
            e = env(n, 0.5, 0.7)
            out, y = [], 0.0
            for i in range(n):
                y = 0.5 * y + 0.5 * w[i]
                out.append(e[i] * (w[i] - y))
            self._add(t, out, db, "breath")
            t += period + self.rng.uniform(-0.3, 0.3)

    def cough(self, t, db=62.0):
        n = int(0.4 * SR)
        w = self._white(n)
        out = [w[i] * math.exp(-((i % (SR // 5)) / SR) * 25) for i in range(n)]
        self._add(t, out, db, "cough")

    def door(self, t, db=70.0):
        n = int(0.25 * SR)
        w = self._white(n)
        out = [(w[i] + 3 * math.sin(2 * math.pi * 80 * i / SR)) * math.exp(-i / SR * 18) for i in range(n)]
        self._add(t, out, db, "door")

    def alarm(self, t0, t1, db=60.0):
        t = t0
        while t + 0.5 <= t1:
            n = int(0.5 * SR)
            out = [math.sin(2 * math.pi * 880 * i / SR) for i in range(n)]
            self._add(t, out, db, "alarm")
            t += 1.0

    def fan(self, t0, t1, db=45.0):
        loop = self._pink(20 * SR)
        loop = array("f", (v + 0.3 * math.sin(2 * math.pi * 100 * i / SR) for i, v in enumerate(loop)))
        loop = rms_norm(loop, db)
        s, e = int(t0 * SR), int(t1 * SR)
        x = self.x
        L = len(loop)
        for j in range(s, min(e, len(x))):
            x[j] += loop[(j - s) % L]
        self.events.append(("fan", t0, t1))

    def speech(self, t, text, db=52.0):
        tmp = os.path.join(OUT, "_say.wav")
        subprocess.run(["say", "-v", "Tingting", "-o", tmp, "--file-format=WAVE",
                        "--data-format=LEI16@16000", text], check=True)
        with wave.open(tmp, "rb") as w:
            a = array("h")
            a.frombytes(w.readframes(w.getnframes()))
        os.remove(tmp)
        sig = [v / 32768 for v in a]
        assert len(sig) > SR // 2, "say 没生成语音（该语音包可能没下载）"
        self._add(t, sig, db, "speech")
        return t + len(sig) / SR

    # ---------- 输出 ----------
    def labels(self):
        n = self.dur
        sn = [0.02] * n
        br = [0.05] * n
        for kind, a, b in self.events:
            for k in range(int(a), min(n, int(b) + 1)):
                ov = max(0.0, min(b, k + 1) - max(a, k))
                if ov < 0.3:
                    continue
                if kind == "snore":
                    sn[k] = max(sn[k], 0.9)
                elif kind == "gasp":
                    sn[k] = max(sn[k], 0.3)
                    br[k] = max(br[k], 0.6)
                elif kind == "breath":
                    br[k] = max(br[k], 0.7)
                elif kind == "cough":
                    sn[k] = max(sn[k], 0.1)
        return {"snoring": sn, "breathing": br}

    def write(self, cid):
        mx = max(abs(v) for v in self.x)
        assert mx < 1.0, f"{cid} 削波 {mx}"
        pcm = array("h", map(int, (v * 32767 for v in self.x)))
        with wave.open(os.path.join(OUT, cid + ".wav"), "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(SR)
            w.writeframes(pcm.tobytes())
        with open(os.path.join(LAB, cid + ".labels.json"), "w") as f:
            json.dump(self.labels(), f, separators=(",", ":"))


def P(start, dur, bucket=None, rtype="gasp", tol=2):
    b = bucket or ("10-20" if dur < 20 else ("20-30" if dur < 30 else "30+"))
    return {"startSec": round(start), "durationSec": dur, "bucket": b, "recoveryType": rtype, "tol": tol}


# ---------------- 场景 ----------------
CASES_DEF = {}


def case(fn):
    CASES_DEF[fn.__name__.lstrip("c")] = fn
    return fn


@case
def c01_basic_pause():
    tl = Tl(360, 1)
    act = tl.snore_with_pauses(0, 360, [(180, 15)])
    return tl, "打呼 3 分钟 → 安静 15 秒 → 大喘一声 → 继续打呼", [
        {"args": {}, "expect": {"pauses": [P(*act[0])], "healthNotice": True,
                                "longestSnoreRun": {"durationSec": 175, "tol": 6}}}]  # 开头几秒噪声底还没建立，前 ~4 秒不算打呼


@case
def c02_stop_long_quiet():
    tl = Tl(600, 2)
    last = tl.snore(0, 180)
    tl.snore(480, 600)
    return tl, "打呼 3 分钟 → 安静 5 分钟（翻身不打了）→ 又打呼。安静超过 90 秒不算停顿（R6④）", [
        {"args": {}, "expect": {"pauses": [], "healthNotice": False,
                                "longestQuietGap": {"durationSec": round(480 - last), "tol": 4}}}]


@case
def c03_quiet_9s():
    tl = Tl(300, 3)
    last = tl.snore(0, 150)
    tl.snore(last + 9, 300)
    return tl, "打呼中安静 9 秒后接着打（不到 10 秒，不算停顿；超过 8 秒，拆成两段）", [
        {"args": {}, "expect": {"pauses": [], "snoreRunsCount": 2}}]


@case
def c04_resume_no_gasp():
    tl = Tl(400, 4)
    act = tl.snore_with_pauses(0, 400, [(180, 14)], recovery="resume")
    return tl, "安静 14 秒后没有大喘，直接以正常音量接着打呼 → 1 次停顿，恢复方式 resumeSnore", [
        {"args": {}, "expect": {"pauses": [P(*act[0], rtype="resumeSnore")]}}]


@case
def c05_fan_onset():
    tl = Tl(1500, 5)
    tl.fan(300, 1500)
    act = tl.snore_with_pauses(960, 1500, [(1200, 12)], db=55.0)
    return tl, "安静 5 分钟（30 dB）→ 开风扇（45 dB）11 分钟不打呼 → 风扇下打呼 55 dB，中间停 12 秒+大喘", [
        {"args": {}, "expect": {"pauses": [P(*act[0])],
                                "snoreSecBefore": {"sec": 960, "value": 0}}}]


@case
def c06_tv_speech():
    tl = Tl(300, 6)
    lines = ["今天的天气预报，明天多云转晴，气温十二到二十度。",
             "接下来是体育新闻，昨晚的比赛进行得非常激烈。",
             "观众朋友们，欢迎收看今天的节目，我们马上回来。",
             "最近几天早晚温差比较大，出门请注意添加衣物。",
             "下面请看一段广告，精彩内容稍后继续。",
             "感谢您的收看，我们明天同一时间再见。"]
    t = 10.0
    for s in lines:
        end = tl.speech(t, s)
        t = end + tl.rng.uniform(11, 16)
    return tl, "电视说话，句子之间停 11–16 秒（停完再大声说话），没有打呼 → 0 打呼 0 停顿", [
        {"args": {}, "expect": {"pauses": [], "snoreSec": {"value": 0, "tol": 0}}}]


@case
def c07_cough_door():
    tl = Tl(420, 7)
    tl.snore(0, 180)
    tl.cough(61.5)
    tl.door(300)
    return tl, "打呼中咳嗽一声；不打呼 2 分钟后关门一声。打呼音量统计不应被咳嗽和关门拉高，也不算停顿", [
        {"args": {}, "expect": {"pauses": [], "snoreP95Db": {"min": 47, "max": 55},
                                "envelopeMax": {"min": 58}}}]


@case
def c07b_door_known_fp():
    tl = Tl(300, 71)
    last = tl.snore(0, 180)
    tl.door(last + 12)
    return tl, "【已知误报】打呼停了 12 秒后关门 → 按 R6 规则会算 1 次停顿（关门声被当成大喘）。用于确认规则按文档执行，03 期真机再决定要不要靠分类器排除", [
        {"args": {}, "expect": {"pauses": [P(last, 12)]}}]


@case
def c08_boundary():
    tl = Tl(360, 8)
    tl.snore(0, 115)
    # 让安静段从 ~115 秒开始、跨过 120 秒分段边界
    last = max(b for k, a, b in tl.events if k == "snore")
    end = tl.gasp(last + 15)
    tl.snore(end + 1.5, 360)
    return tl, "停顿正好跨第 120 秒的分段边界；整段喂 / 每 120 秒 / 每 7 秒喂，结果必须一样", [
        {"args": {}, "expect": {"pauses": [P(last, 15)]}, "chunkInvariant": True}]


@case
def c09_breathing_only():
    tl = Tl(600, 9)
    tl.breath(0, 300)
    tl.breath(320, 600)
    return tl, "整段只有轻微呼吸声，中间完全安静 20 秒，从头到尾不打呼 → 0 打呼 0 停顿", [
        {"args": {}, "expect": {"pauses": [], "snoreSec": {"value": 0, "tol": 0}, "healthNotice": False}}]


@case
def c10_gap_alarm():
    tl = Tl(600, 10)
    tl.snore(0, 294)
    tl.gasp(306)
    tl.snore(308, 600)
    tl.alarm(480, 540)
    return tl, "打呼到 294 秒→安静→第 300 秒中断 60 秒（来电）→恢复后安静 6 秒再一声大喘；第 480 秒闹钟响（之后不计）。中断不能当成安静拼起来算停顿", [
        {"args": {"gapAt": [[300, 60]], "alarmAt": 480},
         "expect": {"pauses": [], "gapSec": {"value": 60, "tol": 0}, "analyzedSec": {"value": 480, "tol": 1},
                    "recordedSec": {"value": 660, "tol": 1}}}]


@case
def c11_long_pause():
    tl = Tl(900, 11)
    act = tl.snore_with_pauses(0, 900, [(400, 32)])
    return tl, "15 分钟里只有 1 次停顿但长达 32 秒（4 次/小时不到 5）→ 仅凭 ≥30 秒触发健康提示", [
        {"args": {}, "expect": {"pauses": [P(*act[0])], "healthNotice": True}}]


@case
def c12_frequent():
    tl = Tl(1200, 12)
    plan = [(100, 12), (280, 15), (450, 18), (700, 13), (880, 16), (1050, 12)]
    act = tl.snore_with_pauses(0, 1200, plan)
    return tl, "20 分钟 6 次停顿（12–18 秒）= 18 次/小时 → 健康提示；另跑「延迟 10 分钟」只算后 3 次、闹钟切在大喘上、中断切在停顿前", [
        {"args": {}, "expect": {"pauses": [P(*a) for a in act], "healthNotice": True}},
        {"args": {"delay": 600}, "expect": {"pauses": [P(*a) for a in act[3:]], "healthNotice": True,
                                             "analyzedSec": {"value": 600, "tol": 1}}},
        # 01a 差分探针补的回归：闹钟恰好在大喘那一秒 → 第 2 次不能确认；中断 120 秒后的安静不能沿用中断前的打呼
        {"args": {"alarmAt": 290}, "expect": {"pauses": [P(*act[0])]}},
        {"args": {"gapAt": [[285, 5], [700, 120]]},
         "expect": {"pauses": [P(*act[0]), P(act[2][0] + 5, act[2][1]), P(act[4][0] + 125, act[4][1]),
                               P(act[5][0] + 125, act[5][1])], "gapSec": {"value": 125, "tol": 0}}}]


@case
def c13_four_per_hour():
    tl = Tl(1800, 13)
    act = tl.snore_with_pauses(0, 1800, [(600, 15), (1300, 22)])
    return tl, "30 分钟 2 次停顿（15、22 秒）= 4 次/小时，都不到 30 秒 → 不触发健康提示", [
        {"args": {}, "expect": {"pauses": [P(*a) for a in act], "healthNotice": False}}]


@case
def c14_composite_90min():
    tl = Tl(5400, 14)
    tl.cough(200)
    tl.door(400)
    a1 = tl.snore_with_pauses(600, 1800, [(770, 14), (1130, 18), (1490, 22)])
    tl.snore(2700, 3000)
    tl.snore(3000, 3240, db=60.0)
    tl.snore(3240, 3900)
    tl.snore(3900, 4320)
    tl.snore(4320, 4440, db=62.0)
    a2 = tl.snore_with_pauses(4440, 5400, [(4490, 12), (4730, 16), (4970, 25), (5210, 13)])
    pauses = a1 + a2
    seg = sorted({int(s // 120) for s, d in pauses})
    return tl, "90 分钟组合夜：前 10 分钟醒着（咳嗽、关门）→ 打呼段含 3 次停顿 → 安静 15 分钟 → 连续打呼约 30 分钟（含 60 dB、62 dB 两个响段）→ 4 次停顿。考留存池：7 个停顿段必须全留、总数 ≤12；7 次/1.5 小时 = 4.7 次/小时，差一点不到 5 → 不触发健康提示", [
        {"args": {}, "expect": {"pauses": [P(*a) for a in pauses], "healthNotice": False,
                                "longestSnoreRun": {"durationSec": round(a2[0][0] - 2700), "tol": 8},
                                "longestQuietGap": {"durationSec": 900, "tol": 8},
                                "retained": {"maxCount": 12, "mustIncludeSegments": seg,
                                             "loudAnyOf": [25, 26, 36]}}, "chunkInvariant": True}]


def main(filters):
    for d in (OUT, LAB, CASES):
        os.makedirs(d, exist_ok=True)
    for cid, fn in CASES_DEF.items():
        if filters and not any(cid.startswith(f) for f in filters):
            continue
        tl, desc, runs = fn()
        tl.write(cid)
        with open(os.path.join(CASES, cid + ".json"), "w", encoding="utf-8") as f:
            json.dump({"id": cid, "desc": desc, "durationSec": tl.dur,
                       "wav": f"out/{cid}.wav", "labels": f"labels/{cid}.labels.json", "runs": runs},
                      f, ensure_ascii=False, indent=1)
        print("ok", cid, tl.dur, "s")


if __name__ == "__main__":
    main(sys.argv[1:])
