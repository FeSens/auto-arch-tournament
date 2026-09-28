"""V1 contamination scan: for every published V1 run (bench/<model>/rep*/), count
tool calls whose command/path arguments name a file in cores/v1/ (echoed output
excluded), and check each final design for files identical or >0.9 similar to a V1
file that differs from V0. Run from the repo root:
  python3 research/v2/scripts/v1_contamination_scan.py > research/v2/v1_contamination.txt"""
import gzip, json, re, sys, collections, hashlib, glob, os, difflib
from pathlib import Path
ARGKEYS = {"command", "cmd", "file_path", "filePath", "path", "pattern", "glob", "filename"}
SKIP = {"aggregated_output", "output", "content", "text", "stdout", "stderr", "result"}
PAT = re.compile(r"cores/v1/([A-Za-z0-9_./-]+)")
def args(o, out):
    if isinstance(o, dict):
        for k, v in o.items():
            if k in SKIP: continue
            if k in ARGKEYS and isinstance(v, str): out.append(v)
            else: args(v, out)
    elif isinstance(o, list):
        for x in o: args(x, out)
def scan(f):
    hits = collections.Counter()
    op = gzip.open if f.endswith(".gz") else open
    with op(f, "rt", errors="replace") as fh:
        for l in fh:
            if "cores/v1" not in l: continue
            i = l.find("{")
            if i < 0: continue
            try: e = json.loads(l[i:])
            except Exception: continue
            a = []; args(e, a)
            for s in a:
                for m in PAT.finditer(s):
                    p = m.group(1)
                    kind = ("rtl" if p.startswith("rtl") else "experiments/log" if p.startswith("experiments")
                            else "LESSONS" if "LESSONS" in p else "other")
                    hits[kind] += 1
    return hits
v0 = {p.name: p.read_bytes() for p in Path("cores/baseline/rtl").glob("*.sv")}
v1 = {p.name: p.read_bytes() for p in Path("cores/v1/rtl").glob("*.sv") if v0.get(p.name) != p.read_bytes()}
print("V1 files that differ from V0:", sorted(v1))
rows = []
for d in sorted(glob.glob("bench/*/rep*")):
    f = d + "/agent.full.log.gz"
    if not os.path.exists(f): f = d + "/agent.log"
    if not os.path.exists(f): continue
    h = scan(f)
    same, near = [], []
    for sv in Path(d, "final-rtl").glob("*.sv") if Path(d, "final-rtl").is_dir() else []:
        if sv.name in v1:
            b = sv.read_bytes()
            if b == v1[sv.name] and sv.name not in ("core_pkg.sv",):
                same.append(sv.name)
            else:
                r = difflib.SequenceMatcher(None, b.decode(errors="replace"), v1[sv.name].decode(errors="replace")).quick_ratio()
                if r > 0.9: near.append(f"{sv.name}:{r:.2f}")
    rows.append((d, dict(h), same, near))
for d, h, same, near in rows:
    print(f"{d:45s} reads={sum(h.values()):4d} {h}  identical={same} near={near}")
