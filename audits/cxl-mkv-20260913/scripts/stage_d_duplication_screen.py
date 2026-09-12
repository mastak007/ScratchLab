#!/usr/bin/env python3
"""Stage D: cheap library-wide SCREEN for the 'chapter 2 is its first half played
twice' pattern.  This is NOT a technique audit and does not complete any technique.

Audio only, one title per technique, isolated-scratch stream where present: correlate
the first half of chapter 2 against the second half at the exact half-offset, with a
+-40 ms refinement.  A high correlation on the ISOLATED SCRATCH track (not the beat)
is strong evidence of duplicated material; a low one means the technique needs the
full audit before any conclusion.

Resumable: results accumulate in reports/stage-d-duplication-screen.json.
"""
import json, os, subprocess, sys, tempfile
from pathlib import Path
import numpy as np
EV = Path(__file__).resolve().parent.parent
SRC = Path("/Volumes/Untitled/CXLrip")
SC = Path(os.environ.get("BATCH_SCRATCH", "/tmp/cxl-batch"))
SR = 48000
OUT = EV / "reports" / "stage-d-duplication-screen.json"

def atomic(p, t):
    fd, tmp = tempfile.mkstemp(dir=str(Path(p).parent), prefix=".tmp-")
    with os.fdopen(fd, "w") as fh: fh.write(t)
    os.replace(tmp, p)

def pcm(title, idx):
    SC.joinpath("pcm").mkdir(parents=True, exist_ok=True)
    dst = SC / "pcm" / f"{title}-a{idx}.s16le"
    if not dst.exists() or dst.stat().st_size == 0:
        subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-i", str(SRC / f"{title}.mkv"),
                        "-map", f"0:a:{idx}", "-vn", "-sn", "-dn", "-ac", "2", "-ar", "48000",
                        "-c:a", "pcm_s16le", "-f", "s16le", str(dst)], check=True)
    return np.fromfile(dst, dtype="<i2").reshape(-1, 2).mean(axis=1).astype(np.float64)

def nc(u, v):
    u = u - u.mean(); v = v - v.mean()
    return float(u @ v / (np.linalg.norm(u) * np.linalg.norm(v) + 1e-12))

groups = json.load(open(EV / "inventory" / "stage-a-groups.json"))
binding = json.load(open(EV / "inventory" / "angle-binding.json"))
res = json.loads(OUT.read_text()) if OUT.exists() else {"_note":
    "SCREEN ONLY - audio evidence, one title per technique. Not a technique audit. "
    "Each entry must be confirmed with scripts/audit_technique.py before acting on it.",
    "results": {}}

for key in sorted(binding):
    if key in res["results"]:
        continue
    b = binding[key]; e = groups["edit_lists"][key]
    ch2 = e["chapter2"]
    t = sorted({v["title"] for v in b["angles"].values() if "title" in v})[0]
    nA = groups["titles"][t]["n_audio"]
    idx = 1 if nA == 3 else 0
    x = pcm(t, idx)
    span = ch2[1] - ch2[0]
    half = span / 2
    # snap the half-offset to a whole video frame, as a DVD repeat necessarily is
    off_f = int(round(half / (1001 / 30000)))
    off = int(round(off_f * 1001 / 30000 * SR))
    n = int(half * SR) - SR // 2
    s0 = int(ch2[0] * SR)
    if s0 + off + n > len(x):
        n = len(x) - s0 - off - 1
    if n < SR:
        res["results"][key] = {"error": "chapter 2 too short for the screen"}
        continue
    a = x[s0:s0+n]
    scan = {d: nc(a, x[s0+off+d:s0+off+d+n]) for d in range(-1920, 1921, 8)}
    bd = max(scan, key=scan.get)
    fine = {d: nc(a, x[s0+off+d:s0+off+d+n]) for d in range(bd-10, bd+11)}
    bf = max(fine, key=fine.get)
    res["results"][key] = {
        "title_screened": t, "stream": f"0:a:{idx}",
        "stream_is_isolated_scratch": nA == 3,
        "chapter2_span_s": round(span, 4),
        "half_offset_frames": off_f, "half_offset_s": round(off_f*1001/30000, 6),
        "best_extra_lag_samples": bf, "best_extra_lag_ms": round(bf/SR*1000, 3),
        "ncc": round(fine[bf], 5),
        "window_s": round(n/SR, 2),
        "screen_verdict": ("duplicated-half likely" if fine[bf] > 0.90 else
                           "inconclusive - needs full audit" if fine[bf] > 0.5 else
                           "no duplicated half detected"),
    }
    atomic(OUT, json.dumps(res, indent=2))
    r = res["results"][key]
    print(f"{key:<24} {t.replace('Scratch_',''):>5}  span={r['chapter2_span_s']:7.3f}s  "
          f"ncc={r['ncc']:.5f}  lag={r['best_extra_lag_ms']:+7.3f}ms  {r['screen_verdict']}")
