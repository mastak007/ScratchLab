#!/usr/bin/env python3
"""Atomically update progress.json and HANDOFF_TO_CODEX.md. Called after every stage
and every technique so an interruption always leaves a usable, truthful state."""
import json, os, sys, tempfile, datetime
from pathlib import Path
EV = Path(__file__).resolve().parent.parent

def atomic(path, text):
    fd, tmp = tempfile.mkstemp(dir=str(Path(path).parent), prefix=".tmp-")
    with os.fdopen(fd, "w") as fh: fh.write(text)
    os.replace(tmp, path)

def load():
    return json.loads((EV / "progress.json").read_text())

def save(p):
    p["last_update"] = datetime.datetime.now().isoformat(timespec="seconds")
    atomic(EV / "progress.json", json.dumps(p, indent=2))
    atomic(EV / "HANDOFF_TO_CODEX.md", render(p))

def render(p):
    done = p["techniques_completed"]; part = p["techniques_partial"]
    pend = p["techniques_pending"]; blk = p["techniques_blocked"]
    L = []
    A = L.append
    A("# Handoff - CXL MKV batch audit\n")
    A(f"**Last update: {p['last_update']}**  |  state: {p['state']}\n")
    A(f"Techniques: **{len(done)} complete**, {len(part)} partial, {len(pend)} pending, {len(blk)} blocked, "
      f"out of {p.get('n_techniques_total','?')}.\n")
    A("## Objective\n")
    A("Audit the remaining techniques in `/Volumes/Untitled/CXLrip` for the classes of problem found in\n"
      "the Baby pilot, BEFORE any bulk re-encode or trim. Produce an audit and a candidate rebuild plan.\n"
      "Do not rebuild the library or change canonical/package data.\n")
    A("## Protected paths - read only\n")
    for q in p["protected_read_only"]: A(f"- `{q}`")
    A("\nNo app or database changes, no training, no installs, no commits, no pushes.\n")
    A("## All new output goes here\n")
    A(f"`{p['output_root']}`\n")
    A("## Usage monitoring\n")
    u = p["usage_monitoring"]
    A(f"- plan-usage data available: **{u['plan_usage_data_available']}**")
    A(f"- {u['note']}\n")
    A("## Stages\n")
    for k, v in p["stages"].items():
        A(f"- **{k}**: {v['status']}" + (f" - {v['note']}" if v.get("note") else ""))
    A("")
    if p.get("corrections_to_prior_evidence"):
        A("## Corrections to prior evidence (important)\n")
        for c in p["corrections_to_prior_evidence"]:
            A(f"- **{c['claim']}**\n  - verdict: {c['verdict']}\n  - evidence: {c['evidence']}\n"
              f"  - consequence: {c['consequence']}")
        A("")
    if p.get("counts"):
        c = p["counts"]
        A("## Counts\n")
        A("| state | n |")
        A("|---|---:|")
        A(f"| verified (fully audited) | {c['verified_audited']} |")
        A(f"| pending (screened only, not audited) | {c['pending']} |")
        A(f"| inconclusive | {c['inconclusive']} |")
        A(f"| failed | {c['failed']} |")
        A(f"| **total** | **{c['total_techniques']}** |")
        A("")
        A(c["note"] + "\n")
    if p.get("runner"):
        r = p["runner"]
        A("## The command to process the remaining techniques\n")
        A("```sh")
        A(f"cd {p['output_root']}")
        A("export BATCH_SCRATCH=/tmp/cxl-batch      # or any durable dir; see Cache below")
        A("python3 scripts/run_batch.py --list      # what is pending")
        A("python3 scripts/run_batch.py --all       # process all pending, checkpointing as it goes")
        A("python3 scripts/run_batch.py --all --limit 3        # smaller batches")
        A("python3 scripts/run_batch.py --only <key>           # a single technique")
        A("python3 scripts/run_batch.py --validate <key>       # re-derive one from cache and compare")
        A("```\n")
        A(f"State is written to `{r['state_file']}` after every step. "
          f"`progress.json` stays the human-facing summary.\n")
        A("**Result vocabulary** (kept distinct on purpose):\n")
        for k, v in r["result_vocabulary"].items():
            A(f"- `{k}` - {v}")
        A("")
        A(f"**Skip rule.** {r['skip_rule']}\n")
        A(f"**Offset policy.** {r['offset_policy']}\n")
        A(f"**Failure handling.** {r['failure_handling']}\n")
    if p.get("artifact_versions"):
        av = p["artifact_versions"]
        A("## Artifacts from the earlier analysis version\n")
        A(av["note"] + "\n")
        A("```sh")
        A(av["command"])
        A("```\n")
    if p.get("cache"):
        c = p["cache"]
        A("## Paths\n")
        A("| what | where |")
        A("|---|---|")
        A("| original MKVs (read only) | `/Volumes/Untitled/CXLrip` |")
        A("| current dataset (read only) | `/Users/karlwatson/Movies/PRO DJ DATASET/dataset` |")
        A(f"| all new output | `{p['output_root']}` |")
        A("| scripts | `<output>/scripts/` |")
        A("| per-technique evidence | `<output>/techniques/<key>*.json` |")
        A("| previews for audition | `<output>/previews/<key>/` |")
        A("| reports | `<output>/reports/` |")
        A("| runner state | `<output>/batch-state.json` |")
        A("| review queue | `<output>/reports/REVIEW_QUEUE.json` |")
        A(f"| decode cache | `${c['env_var']}` |")
        A("")
        A(f"Cache used so far: `{c['path_used_so_far']}`\n")
        A(f"{c['warning']}\n")
        A("Cache subdirectories:\n")
        for k, v in c["subdirs"].items():
            A(f"- `{k}/` - {v}")
        A("")
        A(f"{c['approx_size_per_technique']}.\n")
    if p.get("dependencies"):
        d = p["dependencies"]
        A("## Dependencies\n")
        A(f"- Python {d['python']}, numpy {d['numpy']}")
        A(f"- {d['ffmpeg']}")
        A(f"- {d['notes']}\n")
    if p.get("runner_validation"):
        v = p["runner_validation"]
        A("## Runner validation result\n")
        A(f"Validated on **{v['technique']}** ({v['mode']}), writing only into `{v['wrote_only_into']}`.\n")
        for k, val in v["checks"].items():
            A(f"- `{k}`: {val}")
        A("")
        oc = v["offset_check"]
        A(f"**Offset check:** searched {oc['searched']} frames, half-chapter {oc['half_chapter']} frames, "
          f"equal: {oc['equal']}. {oc['meaning']}.\n")
        A(f"**Independent offset agreement:** the audio's own discovered offset differs from the "
          f"video-derived one by {v['independent_offset_agreement_ms']} ms.\n")
        A(f"**Divergence detector, negative control:** {v['divergence_detector_negative_control']}\n")
        A(f"**Classifier output:** {v['classifier_output']}\n")
        A("The validation found and fixed two real problems:\n")
        for i in v["issues_found_and_fixed_by_the_validation"]:
            A(f"- {i}")
        A("")
        A(f"**Not exercised:** {v['not_exercised']}\n")
    if p.get("limitations"):
        A("## What these measurements cannot establish\n")
        for l in p["limitations"]:
            A(f"- {l}")
        A("")
    if p.get("review_queue"):
        rq = p["review_queue"]
        A("## Audiovisual review queue\n")
        A(f"`{rq['path']}` - {rq['open_items']} open item.\n")
        A(f"{rq['summary']}\n")
    A("## Technique status\n")
    A("| technique | state | source titles | headline finding | evidence |")
    A("|---|---|---|---|---|")
    for t, r in p.get("techniques", {}).items():
        A(f"| {t} | {r['state']} | {r.get('titles','')} | {r.get('headline','')} | {r.get('evidence','')} |")
    A("")
    if p.get("pending_operator_checks"):
        A("## Pending operator checks\n")
        for c in p["pending_operator_checks"]: A(f"- {c}")
        A("")
    if p.get("unresolved_claims"):
        A("## Unresolved / open questions\n")
        for c in p["unresolved_claims"]: A(f"- {c}")
        A("")
    A("## Scripts and how to run them\n")
    A("```sh")
    A(f"cd {p['output_root']}")
    A("export BATCH_SCRATCH=/tmp/cxl-batch     # any scratch dir; caches decoded grayscale/PCM")
    A("python3 scripts/stage_a_inventory.py        # groups (cached, safe to rerun)")
    A("python3 scripts/stage_a2_angle_binding.py   # angle<->title binding (resumable, skips done)")
    A("python3 scripts/stage_b_field_retention.py  # field-retention claim check")
    A("python3 scripts/stage_d_duplication_screen.py # cheap library-wide screen (under-reports; see below)")
    A("python3 scripts/audit_technique.py <technique_key>       # full audit of one technique")
    A("python3 scripts/fractional_lag_repeat.py <key> <title> <ch2start> <ch2end> <offset_frames>")
    A("python3 scripts/repeat_profile.py <technique_key>        # localise where a repeat holds/breaks")
    A("python3 scripts/drift_crosscheck.py <technique_key>      # relative A/V timing across the repeat")
    A("python3 scripts/make_boundary_previews.py <technique_key>")
    A("```\n")
    A("**Measurement pitfalls already paid for - do not repeat them:**\n")
    A("- A repeat of N video frames lands at `N*1601.6` audio samples. That is fractional unless N is a")
    A("  multiple of 5, so fixed integer-lag correlation UNDER-REPORTS the match. Both screen-inconclusive")
    A("  techniques were false alarms from exactly this. Use `fractional_lag_repeat.py`.")
    A("- The best lag can also step by a few samples along a span (splices in the authored duplicate).")
    A("  Search a window of at least +-32 samples, and check whether the result saturates at the bound.")
    A("- The component role test must be run over the performance region only. Over the full title it reads")
    A("  -9 to -11 dB and looks like a failure, because narration sits on the mixed track alone.")
    A("- The motion-envelope A/V sync method produced spurious multi-frame drift on three of four techniques.")
    A("- A whole-span correlation number cannot see a localised divergence. `tears_98bpm` scores 1.000 in 19")
    A("  of 21 windows and still hides a 2.25 s stretch where picture duplicates and audio does not.")
    A("```sh")
    A("# (block re-opened so the fenced section below stays valid)")
    A("```\n")
    A("## Resume command\n")
    A("```sh")
    A(f"cd {p['output_root']} && cat progress.json")
    A(f"# then run: {p['next_exact_operation']}")
    A("```\n")
    A("## Next exact operation\n")
    A(f"{p['next_exact_operation']}\n")
    A("## Note\n")
    A("This handoff was written to disk. It has NOT been sent to Codex or anyone else.\n")
    return "\n".join(L)

if __name__ == "__main__":
    p = load(); save(p); print("checkpoint written")
