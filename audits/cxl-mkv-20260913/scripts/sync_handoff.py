#!/usr/bin/env python3
"""Roll batch-state.json into progress.json and HANDOFF_TO_CODEX.md.

run_batch.py owns batch-state.json; this keeps the human-facing handoff in step with
it so the handoff is never stale. Safe to run while the runner is working - it only
reads batch-state.json and writes progress.json / HANDOFF_TO_CODEX.md.
"""
import json, sys
from pathlib import Path
EV = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(EV / "scripts"))
import checkpoint as C

st = json.loads((EV / "batch-state.json").read_text())
p = C.load()
VERIFIED = ("verified_duplicate_half", "verified_partial_repeat", "verified_no_repeat")

done, failed, inconc = [], [], []
for k, r in st["techniques"].items():
    s = r.get("state", "")
    facts = r.get("facts", {})
    if s in VERIFIED:
        done.append(k)
        bits = [s]
        if facts.get("offset_frames") is not None:
            bits.append(f"offset {facts['offset_frames']} fr"
                        + ("" if facts.get("offset_equals_half_chapter") else " (NOT half-chapter)"))
        if facts.get("audio_ncc_median_fractional") is not None:
            bits.append(f"audio ncc median {facts['audio_ncc_median_fractional']}")
        if facts.get("divergence_spans_first_pass_s"):
            bits.append(f"DIVERGENCE {facts['divergence_spans_first_pass_s']}")
        if facts.get("missing_delivered_angles"):
            bits.append(f"missing angles {facts['missing_delivered_angles']}")
        if facts.get("identical_video_titles"):
            bits.append(f"identical titles {facts['identical_video_titles']}")
        p["techniques"][k] = {"state": "complete", "titles": ",".join(
            t.replace("Scratch_", "") for t in r.get("titles", [])),
            "headline": "; ".join(bits),
            "evidence": f"techniques/{k}*.json, previews/{k}/"}
    elif s == "failed":
        failed.append(k)
        p["techniques"][k] = {"state": "FAILED", "titles": ",".join(
            t.replace("Scratch_", "") for t in r.get("titles", [])),
            "headline": f"FAILED: {r.get('reason','?')}  steps={r.get('steps',{})}",
            "evidence": "batch-state.json -> techniques." + k + ".log"}
    elif s == "inconclusive":
        inconc.append(k)
        p["techniques"][k] = {"state": "INCONCLUSIVE", "titles": ",".join(
            t.replace("Scratch_", "") for t in r.get("titles", [])),
            "headline": f"INCONCLUSIVE: {r.get('reason','?')}",
            "evidence": f"techniques/{k}*.json"}

all_keys = sorted(p["techniques"])
pending = [k for k in all_keys if k not in done + failed + inconc]
p["techniques_completed"] = sorted(done)
p["techniques_partial"] = sorted(inconc)
p["techniques_blocked"] = sorted(failed)
p["techniques_pending"] = sorted(pending)
p["counts"] = {"total_techniques": len(all_keys), "verified_audited": len(done),
               "pending": len(pending), "inconclusive": len(inconc), "failed": len(failed),
               "screened_only_not_audited": len(pending),
               "note": "Counts come straight from batch-state.json. 'pending' means not yet run by the "
                       "runner; the cheap screen is a hypothesis, not a finding."}
p["state"] = (f"{len(done)} verified, {len(inconc)} inconclusive, {len(failed)} failed, "
              f"{len(pending)} pending of {len(all_keys)}.")
p["current_operation"] = (f"python3 scripts/run_batch.py --all  (in progress; {len(pending)} left)"
                          if pending else "run_batch --all finished; consolidating")
p["next_exact_operation"] = ("python3 scripts/run_batch.py --all   (resumes; verified techniques are "
                             "skipped when their fingerprint matches)" if pending else
                             "python3 scripts/consolidate_review_queue.py && python3 scripts/manifest_consistency.py")
C.save(p)
print(f"verified={len(done)} inconclusive={len(inconc)} failed={len(failed)} pending={len(pending)}")
if failed: print("  FAILED:", failed)
if inconc: print("  INCONCLUSIVE:", inconc)
