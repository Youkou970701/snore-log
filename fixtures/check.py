"""验收对照。

    python3 check.py --reference [编号...]   用参考实现跑样本，确认样本本身没设计错（Claude 自检）
    python3 check.py --codex [编号...]       跑 Codex 的 snore-analyze（假分类器），对照期望 + 分块一致性
    python3 check.py --real [编号...]        跑 snore-analyze 的真实苹果分类器，只打印不判分（合成鼾声不代表真鼾声）

需要先 python3 gen.py 生成 out/*.wav。
"""
import glob
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CORE = os.path.join(HERE, "..", "core")
sys.path.insert(0, HERE)


def load_cases(filters):
    for p in sorted(glob.glob(os.path.join(HERE, "cases", "*.json"))):
        c = json.load(open(p, encoding="utf-8"))
        if filters and not any(c["id"].startswith(f) for f in filters):
            continue
        yield c


def run_codex(c, args, chunk=None, fake=True):
    cmd = ["swift", "run", "-c", "release", "--quiet", "--package-path", CORE, "snore-analyze",
           os.path.join(HERE, c["wav"]), "--offset", "90", "--delay", str(args.get("delay", 0))]
    if fake:
        cmd += ["--fake-classifier", codex_labels(c)]
    for s, d in args.get("gapAt", []):
        cmd += ["--gap-at", f"{s}:{d}"]
    if "alarmAt" in args:
        cmd += ["--alarm-at", str(args["alarmAt"])]
    if chunk:
        cmd += ["--chunk", str(chunk)]
    out = subprocess.run(cmd, capture_output=True, text=True)
    if out.returncode != 0:
        raise RuntimeError(out.stderr[-2000:])
    return json.loads(out.stdout)


def run_reference(c, args):
    import reference
    db = reference.read_wav_frames_db(os.path.join(HERE, c["wav"]))
    lab = json.load(open(os.path.join(HERE, c["labels"])))
    r = reference.analyze(db, lab["snoring"], lab["breathing"], delay=args.get("delay", 0),
                          gaps=[tuple(g) for g in args.get("gapAt", [])], alarm_at=args.get("alarmAt"))
    return r


BUCKET_ALIAS = {"10-20": "10-20", "10–20": "10-20", "20-30": "20-30", "20–30": "20-30",
                "30+": "30+", ">=30": "30+", "≥30": "30+"}


def bucket_of(d):
    return "10-20" if d < 20 else ("20-30" if d < 30 else "30+")


def codex_labels(c):
    """把 labels/{snoring:[],breathing:[]} 转成 snore-analyze 认的数组格式（下标 = 音频秒，不含中断）。"""
    lab = json.load(open(os.path.join(HERE, c["labels"])))
    arr = [{"second": i, "snoring": s, "breathing": b} for i, (s, b) in enumerate(zip(lab["snoring"], lab["breathing"]))]
    p = os.path.join(HERE, "out", c["id"] + ".codex-labels.json")
    json.dump(arr, open(p, "w"))
    return p


def compare(rep, exp):
    errs = []
    if "pauses" in exp:
        got = sorted(rep.get("pauses", []), key=lambda p: p["start"])
        want = exp["pauses"]
        if len(got) != len(want):
            errs.append(f"停顿次数 期望 {len(want)} 实际 {len(got)}："
                        + ", ".join(f"{p['start']}s/{p['durationSec']}s" for p in got))
        else:
            for g, w in zip(got, want):
                if abs(g["start"] - w["startSec"]) > w["tol"] or abs(g["durationSec"] - w["durationSec"]) > w["tol"]:
                    errs.append(f"停顿 期望 {w['startSec']}s 起 {w['durationSec']}s，实际 {g['start']}s 起 {g['durationSec']}s")
                if BUCKET_ALIAS.get(g.get("bucket")) != bucket_of(g["durationSec"]):
                    errs.append(f"停顿分档与时长不符：{g['durationSec']}s 标成 {g.get('bucket')}")
                if g.get("recoveryType") != w["recoveryType"]:
                    errs.append(f"恢复方式 期望 {w['recoveryType']} 实际 {g.get('recoveryType')}")
    for key in ("snoreSec", "gapSec", "analyzedSec", "recordedSec"):
        if key in exp:
            v = rep.get(key)
            if v is None or abs(v - exp[key]["value"]) > exp[key]["tol"]:
                errs.append(f"{key} 期望 {exp[key]['value']}±{exp[key]['tol']} 实际 {v}")
    for key in ("longestSnoreRun", "longestQuietGap"):
        if key in exp:
            v = (rep.get(key) or {}).get("durationSec")
            if v is None or abs(v - exp[key]["durationSec"]) > exp[key]["tol"]:
                errs.append(f"{key} 期望 {exp[key]['durationSec']}±{exp[key]['tol']} 实际 {v}")
    if "healthNotice" in exp and rep.get("healthNotice") != exp["healthNotice"]:
        errs.append(f"健康提示 期望 {exp['healthNotice']} 实际 {rep.get('healthNotice')}"
                    f"（{rep.get('pausesPerHour', 0):.2f} 次/小时，最长 {rep.get('longestPauseSec')}s）")
    if "snoreRunsCount" in exp and len(rep.get("snoreRuns", [])) != exp["snoreRunsCount"]:
        errs.append(f"打呼段数 期望 {exp['snoreRunsCount']} 实际 {len(rep.get('snoreRuns', []))}")
    if "snoreP95Db" in exp:
        v = rep.get("snoreP95Db")
        if v is None or not (exp["snoreP95Db"]["min"] <= v <= exp["snoreP95Db"]["max"]):
            errs.append(f"打呼 P95 期望 {exp['snoreP95Db']} 实际 {v}")
    if "envelopeMax" in exp:
        v = rep.get("envelopeMax")
        if v is None and rep.get("envelope"):
            v = max(rep["envelope"])
        if v is None or v < exp["envelopeMax"]["min"]:
            errs.append(f"包络最大值 期望 ≥{exp['envelopeMax']['min']} 实际 {v}")
    if "snoreSecBefore" in exp:
        lim = exp["snoreSecBefore"]["sec"] // 60
        v = sum(m["snoreSec"] for m in rep.get("minuteGrid", []) if m["minute"] < lim)
        if v != exp["snoreSecBefore"]["value"]:
            errs.append(f"前 {lim} 分钟打呼秒数 期望 0 实际 {v}")
    if "retained" in exp and "retained" in rep:
        r = rep["retained"]
        segs = set()
        for x in r:
            segs |= set(x.get("segmentNumbers", [x.get("segmentIndex")]))
        e = exp["retained"]
        if len(r) > e["maxCount"]:
            errs.append(f"留存 {len(r)} 条，超过 {e['maxCount']}")
        miss = [s for s in e["mustIncludeSegments"] if s not in segs]
        if miss:
            errs.append(f"停顿所在段没留：{miss}")
        if not segs & set(e["loudAnyOf"]):
            errs.append(f"最响的段 {e['loudAnyOf']} 一个都没留")
    return errs


def strip_volatile(rep):
    return json.dumps(rep, sort_keys=True)


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "--reference"
    filters = sys.argv[2:]
    total = bad = 0
    for c in load_cases(filters):
        for i, run in enumerate(c["runs"]):
            total += 1
            tag = f"{c['id']}#{i}"
            try:
                if mode == "--reference":
                    rep = run_reference(c, run["args"])
                    errs = compare(rep, run["expect"])
                elif mode == "--codex":
                    rep = run_codex(c, run["args"])
                    errs = compare(rep, run["expect"])
                    ref = run_reference(c, run["args"])
                    if abs(rep.get("snoreSec", -1) - ref["snoreSec"]) > max(2, 0.02 * ref["snoreSec"]):
                        errs.append(f"打呼秒数与参考实现差太多：{rep.get('snoreSec')} vs {ref['snoreSec']}")
                    # R11 打呼时段：与参考实现对照（±1 秒）
                    if "snoreEpisodeSec" not in rep:
                        errs.append("报告缺少 R11 字段 snoreEpisodeSec / snoreEpisodes / longestSnoreEpisode / longestEpisodeGap")
                    else:
                        if abs(rep["snoreEpisodeSec"] - ref["snoreEpisodeSec"]) > 1 + 0.01 * ref["snoreEpisodeSec"]:
                            errs.append(f"打呼时段合计与参考实现不符：{rep['snoreEpisodeSec']} vs {ref['snoreEpisodeSec']}")
                        if len(rep.get("snoreEpisodes", [])) != len(ref["snoreEpisodes"]):
                            errs.append(f"打呼时段个数与参考实现不符：{len(rep.get('snoreEpisodes', []))} vs {len(ref['snoreEpisodes'])}")
                        for key in ("longestSnoreEpisode", "longestEpisodeGap"):
                            a = (rep.get(key) or {}).get("durationSec"); b = (ref[key] or {}).get("durationSec")
                            if (a is None) != (b is None) or (a is not None and abs(a - b) > 1):
                                errs.append(f"{key} 与参考实现不符：{a} vs {b}")
                    for ch in (120, 7):
                        if strip_volatile(run_codex(c, run["args"], chunk=ch)) != strip_volatile(rep):
                            errs.append(f"按 {ch} 秒分块喂入，结果和整段喂入不一致")
                elif mode == "--real":
                    rep = run_codex(c, run["args"], fake=False)
                    print(f"{tag}: 打呼 {rep.get('snoreSec')}s，停顿 {len(rep.get('pauses', []))} 次，"
                          f"P95 {rep.get('snoreP95Db')}，提示 {rep.get('healthNotice')}  —— {c['desc'][:30]}")
                    continue
            except Exception as ex:  # noqa
                errs = [f"运行失败：{ex}"]
            if errs:
                bad += 1
                print(f"FAIL {tag}  {c['desc'][:40]}")
                for e in errs:
                    print("   -", e)
            else:
                print(f"PASS {tag}")
    if mode != "--real":
        print(f"\n{total - bad}/{total} 通过")
        sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
