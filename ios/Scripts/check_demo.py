"""Compare the real App recording pipeline with the CLI; no microphone or playback."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

IOS = Path(__file__).resolve().parents[1]
PROJECT = IOS.parent
os.environ["DEVELOPER_DIR"] = "/Applications/Xcode.app/Contents/Developer"

def command(args):
    result = subprocess.run(args, capture_output=True, text=True, check=True)
    return json.loads(result.stdout)

def check(case, extra=None):
    extra = extra or []
    labels = json.loads((PROJECT / "fixtures" / "labels" / (case + ".labels.json")).read_text())
    with tempfile.TemporaryDirectory(prefix="snore-demo-") as scratch:
        root = Path(scratch)
        script = root / "labels.json"
        script.write_text(json.dumps([dict(second=i, snoring=s, breathing=b) for i, (s,b) in enumerate(zip(labels["snoring"],labels["breathing"]))]))
        wav = PROJECT / "fixtures" / "out" / (case + ".wav")
        cli = command(["swift", "run", "-c", "release", "--quiet", "--package-path", str(PROJECT / "core"), "snore-analyze", str(wav), "--fake-classifier", str(script)] + extra)
        demo = command(["swift", "run", "-c", "release", "--quiet", "--package-path", str(IOS), "demo-check", str(wav), "--labels", str(script), "--output-root", str(root / "nights")] + extra)
        assert demo["report"] == cli, f"{case}: entire report differs"
        clips = demo["clips"]
        desired = sorted(sorted(x["segmentNumbers"]) for x in cli["retained"])
        assert sorted(sorted(x["segmentNumbers"]) for x in clips) == desired, f"{case}: retained entries differ"
        clipdir = root / "nights" / demo["id"] / "clips"
        assert {p.name for p in clipdir.iterdir()} == {c["fileName"] for c in clips}, f"{case}: extra/missing files"
        assert len(clips) <= 12
        assert not (clipdir.parent / "tmp").exists()
        print(f"PASS {case}{' '+str(extra) if extra else ''}: full report equal, exact {len(clips)} clip files, deferred analysis deleted all temporary audio")

if __name__ == "__main__":
    for case in ["14_composite_90min", "12_frequent"]:
        check(case)
    check("12_frequent", ["--gap-at", "200:60", "--alarm-at", "800"])
