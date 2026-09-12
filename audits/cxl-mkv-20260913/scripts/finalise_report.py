#!/usr/bin/env python3
"""Splice the current batch results into reports/BATCH_AUDIT_REPORT.md.

Idempotent: the generated section is delimited and replaced wholesale on each run,
so this can be run at any point, including part-way through the batch.
"""
import json, os, tempfile
from pathlib import Path
from collections import Counter
EV = Path(__file__).resolve().parent.parent
BEGIN = "<!-- BEGIN GENERATED BATCH RESULTS -->"
END = "<!-- END GENERATED BATCH RESULTS -->"

def atomic(p, t):
    p = Path(p); fd, tmp = tempfile.mkstemp(dir=str(p.parent), prefix=".tmp-")
    with os.fdopen(fd, "w") as fh: fh.write(t)
    os.replace(tmp, p)

st = json.loads((EV / "batch-state.json").read_text())
binding = json.loads((EV / "inventory" / "angle-binding.json").read_text())
q = json.loads((EV / "reports" / "REVIEW_QUEUE.json").read_text())
VER = ("verified_duplicate_half", "verified_partial_repeat", "verified_no_repeat")
cnt = Counter()
offs, nothalf, divs, miss, ident = [], [], [], [], []
for k in sorted(binding):
    r = st["techniques"].get(k)
    if not r or r.get("state") not in VER:
        cnt["not_classified"] += 1; continue
    cnt[r["state"]] += 1
    f = r.get("facts") or {}
    if f.get("offset_frames"): offs.append(f["offset_frames"])
    if f.get("offset_equals_half_chapter") is False: nothalf.append(k)
    if f.get("divergence_spans_first_pass_s"): divs.append((k, f["divergence_spans_first_pass_s"]))
    if f.get("missing_delivered_angles"): miss.append((k, f["missing_delivered_angles"]))
    if f.get("identical_video_titles"): ident.append((k, f["identical_video_titles"]))
done = sum(cnt[s] for s in VER)

L = [BEGIN, "",
 "## 10. Batch results",
 "",
 f"**{done} of {len(binding)} techniques classified.** "
 + ", ".join(f"{v} {k}" for k, v in sorted(cnt.items()) if k in VER)
 + (f"; {cnt['not_classified']} not yet classified." if cnt.get("not_classified") else "."),
 "",
 "Full per-technique measurements: `reports/RESULTS_TABLE.md`.",
 "",
 "### The repeat is real across the library, and its offset varies",
 "",
 f"Repeat offsets found so far span **{min(offs)} to {max(offs)} frames** "
 f"({min(offs)*1001/30000:.2f} s to {max(offs)*1001/30000:.2f} s). "
 f"**{len(nothalf)}** of the classified techniques repeat at an offset that is NOT half the chapter "
 f"duration: {', '.join(nothalf) if nothalf else 'none'}. The offset is searched per technique and "
 "cross-checked against an independently discovered audio offset; assuming half the chapter would have "
 "produced wrong answers.",
 "",
 "### Picture/audio divergence",
 ""]
if divs:
    L.append("Techniques where the picture still duplicates but the isolated-scratch audio does not:")
    L.append("")
    for k, spans in divs:
        L.append(f"- **{k}** - first-pass spans {spans}")
    L.append("")
    L.append("These are queued in `reports/REVIEW_QUEUE.json` "
             f"({q.get('consolidated',{}).get('open_items','?')} open). "
             "Both passes are preserved; the evidence does not say which is faithful.")
else:
    L.append("None detected in the classified techniques.")
L += ["", "### Source-level gaps", ""]
if miss:
    for k, a in miss: L.append(f"- **{k}** - delivered angles missing: {a}")
else:
    L.append("- No technique other than those listed above is missing a delivered angle.")
if ident:
    L.append("")
    for k, g in ident:
        L.append(f"- **{k}** - titles decoding to identical frames: "
                 + "; ".join("+".join(x.replace('Scratch_','') for x in gg) for gg in g))
    L.append("")
    L.append("Note `baby` and `cutting` share a chapter-2 range and therefore one candidate group, so "
             "cutting's t05+t06 pair is reported under both. baby's own titles t00-t03 are distinct.")
L += ["",
 "### Still not established, for any technique",
 "",
 "- **Absolute audio/video synchronisation.** Every timing figure here is relative, measured across a "
 "title's own repeat. A constant offset between picture and sound would be invisible to it.",
 "- **That any region is speech-free.** Component subtraction cannot prove absence, and the voice-band "
 "indicator has no sensitivity against a music bed. Every boundary still needs operator audition.",
 "", END]
p = EV / "reports" / "BATCH_AUDIT_REPORT.md"
s = p.read_text()
block = "\n".join(L)
if BEGIN in s and END in s:
    s = s[:s.index(BEGIN)] + block + s[s.index(END) + len(END):]
else:
    s = s.rstrip() + "\n\n---\n\n" + block + "\n"
atomic(p, s)
print(f"report updated: {done}/{len(binding)} classified; offsets {min(offs)}-{max(offs)} fr; "
      f"{len(nothalf)} not-half; {len(divs)} divergence(s)")
