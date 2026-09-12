#!/usr/bin/env python3
"""Consolidate every audiovisual-review item across all audited techniques.

Merges rather than overwrites: hand-authored items (currently tears_98bpm) keep their
detail, and auto-detected divergences from every other technique are added alongside.
Nothing here decides which pass is faithful - that is an operator judgement.
"""
import json, os, tempfile
from pathlib import Path
EV = Path(__file__).resolve().parent.parent
FRAME_S = 1001 / 30000

def atomic(p, t):
    p = Path(p); p.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(p.parent), prefix=".tmp-")
    with os.fdopen(fd, "w") as fh: fh.write(t)
    os.replace(tmp, p)

qp = EV / "reports" / "REVIEW_QUEUE.json"
q = json.loads(qp.read_text()) if qp.exists() else {"items": []}
q.setdefault("items", [])
hand = {i["technique"] for i in q["items"]}

groups = json.loads((EV / "inventory" / "stage-a-groups.json").read_text())
added, scanned = [], []
for pr in sorted((EV / "techniques").glob("*.repeat-profile.json")):
    if pr.parent.name != "techniques": continue
    P = json.loads(pr.read_text())
    key = P["technique"]; scanned.append(key)
    if not P.get("divergence_detected"): continue
    if key in hand: continue                      # keep the detailed hand-written entry
    tj = json.loads((EV / "techniques" / f"{key}.json").read_text())
    e = groups["edit_lists"][key]; keeps = e.get("keeps", [])
    off = P["offset_s"]
    affected = set()
    for a, b in P["divergence_spans_first_pass_s"]:
        for n, (ks, ke) in enumerate(keeps, 1):
            if not (ke <= a or ks >= b): affected.add(n)
            if not (ke <= a + off or ks >= b + off): affected.add(n)
    q["items"].append({
        "technique": key, "bpm": e["bpm"],
        "source_titles": tj["angle_to_title"],
        "chapter2_s": P["chapter2"],
        "repeat_offset_frames": P["offset_frames"], "repeat_offset_s": off,
        "finding": "Windows where the picture still duplicates at the repeat offset but the isolated "
                   "scratch audio does not. The two passes carry the same image and different sound there.",
        "cause": "NOT DETERMINED.",
        "detector_controls": P["controls"],
        "source_ranges_to_review": [
            {"pass": "first", "start_s": a, "end_s": b,
             "video_frames": [int(round(a / FRAME_S)), int(round(b / FRAME_S))]}
            for a, b in P["divergence_spans_first_pass_s"]] + [
            {"pass": "second", "start_s": a, "end_s": b,
             "video_frames": [int(round(a / FRAME_S)), int(round(b / FRAME_S))]}
            for a, b in P["divergence_spans_second_pass_s"]],
        "delivered_takes_affected": sorted(affected),
        "audition_material": f"previews/{key}/ (boundary clips only; a clip covering the divergent window "
                             "has NOT been rendered for this technique)",
        "status": "OPEN - awaiting operator audiovisual review",
        "detected_by": "scripts/repeat_profile.py divergence detector, auto-consolidated"})
    added.append(key)

q["consolidated"] = {
  "techniques_with_a_repeat_profile": sorted(scanned),
  "n_scanned": len(scanned),
  "auto_added_this_run": added,
  "hand_authored_kept": sorted(hand),
  "open_items": len([i for i in q["items"] if i.get("status", "").startswith("OPEN")]),
}
q["principle"] = ("Both versions are preserved. The evidence shows the two passes differ; it does NOT show "
                  "which one is faithful. Do not delete, prefer or overwrite either until a person has "
                  "watched and listened to both.")
atomic(qp, json.dumps(q, indent=2))
print(f"scanned {len(scanned)} repeat-profiles; auto-added {len(added)}: {added or 'none'}; "
      f"open items now {q['consolidated']['open_items']}")
