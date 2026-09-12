#!/usr/bin/env python3
"""Render the per-technique results table from batch-state.json into
reports/RESULTS_TABLE.md. Safe to run while the runner is working; it only reads
batch-state.json and the technique JSONs."""
import json, os, tempfile
from pathlib import Path
EV = Path(__file__).resolve().parent.parent
FRAME_S = 1001 / 30000

def atomic(p, t):
    p = Path(p); p.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(p.parent), prefix=".tmp-")
    with os.fdopen(fd, "w") as fh: fh.write(t)
    os.replace(tmp, p)

st = json.loads((EV / "batch-state.json").read_text())
binding = json.loads((EV / "inventory" / "angle-binding.json").read_text())
VER = ("verified_duplicate_half", "verified_partial_repeat", "verified_no_repeat")
L = []
A = L.append
A("# Per-technique results\n")
A("Generated from `batch-state.json`. `state` is the runner's classification; the columns after it are")
A("the measurements it classified on. An offset is always the SEARCHED value, never assumed to be half")
A("the chapter.\n")
A("| technique | state | titles | offset (fr) | = half? | audio ncc med | lag spread | divergence | missing angles | identical titles |")
A("|---|---|---|---:|---|---:|---:|---|---|---|")
rows = 0
for k in sorted(binding):
    r = st["techniques"].get(k)
    if not r:
        A(f"| {k} | _not run_ | | | | | | | | |"); continue
    s = r.get("state", "?")
    f = r.get("facts") or {}
    if s not in VER and not f:
        A(f"| {k} | _in flight or interrupted_ | | | | | | | | |"); continue
    rows += 1
    ttl = ",".join(t.replace("Scratch_", "") for t in r.get("titles", []))
    div = f["divergence_spans_first_pass_s"] if f.get("divergence_spans_first_pass_s") else "-"
    ma = ",".join(f.get("missing_delivered_angles") or []) or "-"
    it = ";".join("+".join(x.replace("Scratch_", "") for x in g)
                  for g in (f.get("identical_video_titles") or [])) or "-"
    A(f"| {k} | {s} | {ttl} | {f.get('offset_frames')} | "
      f"{'yes' if f.get('offset_equals_half_chapter') else 'NO'} | "
      f"{f.get('audio_ncc_median_fractional')} | {f.get('lag_spread_samples')} | {div} | {ma} | {it} |")
A("")
A(f"{rows} techniques classified of {len(binding)}.\n")
A("## Column meanings\n")
A("- **offset (fr)** - repeat offset in video frames, found by searching every offset.")
A("- **= half?** - whether that equals half the chapter-2 duration. `NO` is common and expected.")
A("- **audio ncc med** - median isolated-scratch correlation across active 1 s windows at the best")
A("  FRACTIONAL lag. Integer-lag correlation under-reports and is not used here.")
A("- **lag spread** - how far the best lag moves across the span, in audio samples. A non-zero spread")
A("  indicates a splice in the authored copy, not drift.")
A("- **divergence** - spans where the picture still duplicates but the audio does not. These go to")
A("  `reports/REVIEW_QUEUE.json`; the evidence never says which pass is faithful.")
A("- **identical titles** - two titles in the group decoding to the same frames. Note that `baby` and")
A("  `cutting` share a chapter group, so cutting's t05+t06 pair appears in both rows.\n")
A("## What none of these columns establish\n")
A("- Absolute audio/video synchronisation. Every timing figure is relative, across a title's own repeat.")
A("- That any region is speech-free. Talking boundaries need operator audition.\n")
atomic(EV / "reports" / "RESULTS_TABLE.md", "\n".join(L))
print(f"wrote reports/RESULTS_TABLE.md ({rows} classified of {len(binding)})")
