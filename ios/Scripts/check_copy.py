"""Offline source/resource copy guard; exits nonzero on prohibited terms."""
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
TERMS = [[21628, 21560, 26242, 20572, 32508, 21512, 24449], [65, 72, 73], [37325, 24230], [20013, 24230], [36731, 24230], [30830, 35786], [35786, 26029, 20026], [27835, 30103], [27490, 40766, 20135, 21697, 25512, 33616]]
errors = []
for p in ROOT.rglob("*"):
    if any(part.startswith(".") or part in {"DerivedData", "Screenshots"} for part in p.relative_to(ROOT).parts):
        continue
    if not p.is_file() or p.suffix not in {".swift", ".strings", ".stringsdict", ".xcstrings"}:
        continue
    text = p.read_text()
    for codes in TERMS:
        term = "".join(map(chr, codes))
        if term in text:
            errors.append(f"{p.relative_to(ROOT)}: {term}")
if errors:
    raise SystemExit("\n".join(errors))
print("Source and resource copy scan passed")
