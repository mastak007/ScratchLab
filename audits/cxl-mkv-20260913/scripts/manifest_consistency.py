#!/usr/bin/env python3
"""Check dataset/manifest.csv against what is actually on disk, and against the
duplication findings. Read-only: nothing in the dataset is modified."""
import csv, json, os, re, tempfile, collections
from pathlib import Path
EV = Path(__file__).resolve().parent.parent
DS = Path("/Users/karlwatson/Movies/PRO DJ DATASET/dataset")

def atomic(p, t):
    p = Path(p); p.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(p.parent), prefix=".tmp-")
    with os.fdopen(fd, "w") as fh: fh.write(t)
    os.replace(tmp, p)

rows = list(csv.DictReader(open(DS / "manifest.csv")))
cols = ["video", "audio_withBeat", "audio_noBeat", "audio_beatOnly"]
per = {}
for r in rows:
    t = r["scratch"]
    d = per.setdefault(t, {"rows": 0, "missing": collections.Counter(), "present": collections.Counter(),
                           "angles": set(), "takes": set()})
    d["rows"] += 1; d["angles"].add(r["angle"]); d["takes"].add(r["take"])
    for c in cols:
        (d["present"] if (DS / r[c]).exists() else d["missing"])[c] += 1

# what the audit knows about duplicates
dup = {}
for p in sorted((EV / "techniques").glob("*.json")):
    if p.parent.name != "techniques" or ".fractional-lag" in p.name or ".repeat-profile" in p.name \
       or ".drift-crosscheck" in p.name: continue
    try: R = json.loads(p.read_text())
    except Exception: continue
    if "delivered_segment_duplication" not in R: continue
    pairs = set()
    for ang, v in R["delivered_segment_duplication"].items():
        pairs |= set(v["duplicate_pairs_zncc_gt_0.99"].keys())
    dup[R["technique"]] = sorted(pairs)

out = {"manifest_rows": len(rows), "techniques_in_manifest": len(per),
       "note": "Read-only check. No dataset file was modified.",
       "per_technique": {}, "totals": {}}
tm = collections.Counter()
for t, d in sorted(per.items()):
    miss = sum(d["missing"].values()); tot = d["rows"] * len(cols)
    out["per_technique"][t] = {
        "rows": d["rows"], "angles": sorted(d["angles"]), "takes": len(d["takes"]),
        "paths_checked": tot, "paths_missing": miss,
        "missing_by_column": dict(d["missing"]),
        "audited_duplicate_take_pairs": dup.get(t, "not audited"),
    }
    tm["paths_checked"] += tot; tm["paths_missing"] += miss
    if miss: tm["techniques_with_missing_paths"] += 1
out["totals"] = dict(tm)
out["summary"] = {
  "techniques_with_all_four_angles": sum(1 for d in per.values() if len(d["angles"]) == 4),
  "techniques_with_fewer_angles": {t: sorted(d["angles"]) for t, d in per.items() if len(d["angles"]) != 4},
  "audio_path_pattern_problem": ("Manifest names per-angle WAVs, but only one angle's WAVs exist on disk "
    "for several techniques. Audio is byte-identical across angles in every group audited so far, so the "
    "fix is a naming/reference decision, not missing content - but it is NOT verified for unaudited groups."),
  "duplicate_takes_not_marked": ("manifest.csv has no column recording that take05-08 duplicate take01-04. "
    "Every technique audited so far shows that duplication. Adding a duplicate_of column is a dataset "
    "change and was NOT made here."),
}
atomic(EV / "reports" / "manifest-consistency.json", json.dumps(out, indent=2))
print(f"rows={len(rows)} techniques={len(per)} paths_checked={tm['paths_checked']} "
      f"paths_missing={tm['paths_missing']} techniques_with_missing={tm.get('techniques_with_missing_paths',0)}")
print("techniques with != 4 angles:", out["summary"]["techniques_with_fewer_angles"])
worst = sorted(out["per_technique"].items(), key=lambda kv: -kv[1]["paths_missing"])[:6]
for t, v in worst:
    print(f"  {t:<22} missing {v['paths_missing']:>3}/{v['paths_checked']:<3} {dict(v['missing_by_column'])}")
