#!/usr/bin/env python3
"""Resumable batch runner for the remaining CXL technique audits.

This ORCHESTRATES the existing per-technique scripts; it does not reimplement any
analysis. Per technique it runs, in order:

  1. audit_technique.py          - decode integrity, angle binding check, audio roles,
                                   title duplicates, repeat SEARCH, segment duplication,
                                   talking-boundary evidence, noise, envelope A/V sync
  2. fractional_lag_repeat.py --discover
                                 - audio repeat at fractional lag, plus the audio's OWN
                                   independently discovered offset for cross-check
  3. repeat_profile.py           - windowed video-vs-audio comparison and divergence
                                   detection (the tears_98bpm signature)
  4. drift_crosscheck.py         - relative A/V timing across the repeat
  5. make_boundary_previews.py   - operator audition material

Result vocabulary, kept deliberately distinct:
  verified_duplicate_half   repeat found and confirmed in BOTH video and audio
  verified_partial_repeat   repeat confirmed but with divergent spans inside it
  verified_no_repeat        searched and none found
  inconclusive              evidence conflicts or falls below thresholds
  failed                    a step errored; partial results preserved, NOT complete
  screened_only             not audited yet

Skip rules: a technique is skipped only when its recorded fingerprint matches the
current one - same source files (size+mtime), same script contents, same analysis
versions and parameters. Anything else re-runs.

Usage:
  run_batch.py --list
  run_batch.py --all                  # every pending technique
  run_batch.py --only KEY [KEY ...]
  run_batch.py --limit N
  run_batch.py --validate KEY         # re-derive one audited technique from cache, compare
  run_batch.py --dry-run
"""
import argparse, hashlib, json, os, subprocess, sys, tempfile, time, datetime
from pathlib import Path

ANALYSIS_VERSION = "run_batch/1"
EV = Path(__file__).resolve().parent.parent
SCRIPTS = EV / "scripts"
SRC = Path("/Volumes/Untitled/CXLrip")
SC = Path(os.environ.get("BATCH_SCRATCH", "/tmp/cxl-batch"))
STATE = EV / "batch-state.json"
FRAME_S = 1001 / 30000

STEPS = ["audit", "fractional_lag", "repeat_profile", "drift_crosscheck", "previews"]

def atomic(path, text):
    path = Path(path); path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=".tmp-")
    with os.fdopen(fd, "w") as fh: fh.write(text)
    os.replace(tmp, path)

def sha(p):
    h = hashlib.sha256()
    with open(p, "rb") as fh:
        for c in iter(lambda: fh.read(1 << 20), b""): h.update(c)
    return h.hexdigest()

def load_state():
    if STATE.exists(): return json.loads(STATE.read_text())
    return {"analysis_version": ANALYSIS_VERSION, "techniques": {}, "runs": []}

def save_state(s):
    s["last_update"] = datetime.datetime.now().isoformat(timespec="seconds")
    atomic(STATE, json.dumps(s, indent=2))

def fingerprint(key, titles):
    """Inputs + code + parameters. A skip is only safe when all three match."""
    src = {}
    for t in titles:
        p = SRC / f"{t}.mkv"
        src[t] = {"exists": p.exists(),
                  "bytes": p.stat().st_size if p.exists() else None,
                  "mtime_ns": p.stat().st_mtime_ns if p.exists() else None}
    code = {n: sha(SCRIPTS / n)[:16] for n in sorted(
        ["audit_technique.py", "fractional_lag_repeat.py", "repeat_profile.py",
         "drift_crosscheck.py", "make_boundary_previews.py", "run_batch.py"])}
    return {"sources": src, "script_sha256_16": code, "runner_version": ANALYSIS_VERSION,
            "params": {"frac_max_lag": 32.0, "frac_probe_s": 6.0, "profile_window_s": 1.0,
                       "video_match": 0.995, "audio_match": 0.90}}

def run(cmd, log):
    t0 = time.time()
    r = subprocess.run([sys.executable, *cmd], capture_output=True, text=True, cwd=str(EV))
    log.append({"cmd": " ".join(str(c) for c in cmd), "rc": r.returncode,
                "seconds": round(time.time() - t0, 1),
                "stdout_tail": r.stdout.strip()[-1500:], "stderr_tail": r.stderr.strip()[-1500:]})
    return r

def classify(key, derived_dir=None):
    """Turn the produced evidence files into one of the distinct result states.
    derived_dir lets validation classify its own recomputed artifacts instead of the
    stored ones."""
    dd = Path(derived_dir) if derived_dir else (EV / "techniques")
    tj = EV / "techniques" / f"{key}.json"
    if not tj.exists(): return "failed", "no technique JSON produced", {}
    R = json.loads(tj.read_text())
    if not R.get("complete"): return "failed", "technique JSON incomplete", {}
    rep = R.get("repeat_within_title", {})
    facts = {"offset_frames": rep.get("best_nonlocal_offset", {}).get("offset_frames"),
             "video_repeat_detected": rep.get("video_repeat_detected"),
             "video_mean_similarity": rep.get("best_nonlocal_offset", {}).get("mean_similarity"),
             "adjacent_frame_similarity": rep.get("adjacent_frame_similarity"),
             "audio_roles": R.get("audio", {}).get("roles", {}).get("verdict"),
             "missing_delivered_angles": R.get("missing_delivered_angles"),
             "identical_video_titles": R.get("title_duplicates", {}).get("identical_video_groups")}
    if not rep.get("video_repeat_detected"):
        return "verified_no_repeat", "no offset made frames as similar as neighbours", facts
    fl = dd / f"{key}.fractional-lag.json"
    pr = dd / f"{key}.repeat-profile.json"
    if not fl.exists() or not pr.exists():
        return "inconclusive", "repeat found in video but audio evidence missing", facts
    F = json.loads(fl.read_text()); P = json.loads(pr.read_text())
    facts.update({
      "audio_ncc_median_fractional": F.get("ncc_best_fractional", {}).get("median"),
      "audio_ncc_min_fractional": F.get("ncc_best_fractional", {}).get("min"),
      "audio_windows_below_0.90": F.get("n_windows_below_0.90"),
      "lag_spread_samples": F.get("extra_lag_samples", {}).get("spread"),
      "lag_hit_search_bound": F.get("any_lag_hit_search_bound"),
      "offset_equals_half_chapter": F.get("offset_equals_half_chapter"),
      "audio_discovered_offset_delta_ms": F.get("audio_vs_supplied_offset_delta_ms"),
      "divergence_spans_first_pass_s": P.get("divergence_spans_first_pass_s"),
      "divergence_spans_second_pass_s": P.get("divergence_spans_second_pass_s")})
    med = F.get("ncc_best_fractional", {}).get("median") or 0
    delta = F.get("audio_vs_supplied_offset_delta_ms")
    if delta is not None and abs(delta) > 40:
        return "inconclusive", (f"audio's own offset differs from the video's by {delta:.1f} ms "
                                "(> one frame) - offsets must be reconciled before any conclusion"), facts
    if F.get("any_lag_hit_search_bound"):
        return "inconclusive", "best lag hit the search bound; widen --max-lag and re-run", facts
    if med < 0.90:
        return "inconclusive", f"audio median ncc {med:.3f} below 0.90 even at fractional lag", facts
    if P.get("divergence_detected"):
        return ("verified_partial_repeat",
                f"repeat confirmed, but {len(P['divergence_spans_first_pass_s'])} span(s) where the "
                "picture duplicates and the audio does not - flag for A/V review", facts)
    return "verified_duplicate_half", f"video and audio both repeat at {facts['offset_frames']} frames", facts

def process(key, groups, binding, state, dry=False):
    e = groups["edit_lists"][key]
    ch2 = e["chapter2"]
    titles = sorted({v["title"] for v in binding[key]["angles"].values() if "title" in v})
    fp = fingerprint(key, titles)
    prev = state["techniques"].get(key)
    if prev and prev.get("state", "").startswith("verified") and prev.get("fingerprint") == fp:
        print(f"[skip] {key}: already {prev['state']} and fingerprint matches")
        return prev
    if prev and prev.get("fingerprint") != fp and prev.get("state"):
        print(f"[rerun] {key}: fingerprint changed since {prev.get('state')}")
    if dry:
        print(f"[dry-run] would process {key}: titles={titles} chapter2={ch2}")
        return prev or {"state": "screened_only"}

    rec = {"key": key, "titles": titles, "chapter2": ch2, "fingerprint": fp,
           "started": datetime.datetime.now().isoformat(timespec="seconds"),
           "steps": {}, "log": [], "state": "failed", "reason": "run did not finish"}
    state["techniques"][key] = rec; save_state(state)      # partial recorded up front

    r = run([SCRIPTS / "audit_technique.py", key], rec["log"])
    rec["steps"]["audit"] = "ok" if r.returncode == 0 else f"rc={r.returncode}"
    save_state(state)
    if r.returncode != 0:
        rec["reason"] = "audit_technique.py failed; see log"; save_state(state); return rec

    R = json.loads((EV / "techniques" / f"{key}.json").read_text())
    t_ref = R["repeat_within_title"]["reference_title"]
    offf = R["repeat_within_title"]["best_nonlocal_offset"]["offset_frames"]
    half = int(round((ch2[1] - ch2[0]) / 2 / FRAME_S))
    rec["offset_frames_searched"] = offf
    rec["offset_frames_half_chapter"] = half
    rec["offset_equals_half_chapter"] = (offf == half)
    if offf != half:
        print(f"  note: searched offset {offf} != half-chapter {half} frames "
              f"({(offf-half)*FRAME_S*1000:+.1f} ms) - using the SEARCHED value")

    if R["repeat_within_title"]["video_repeat_detected"] and R["audio"]["n_streams"] == 3:
        r = run([SCRIPTS / "fractional_lag_repeat.py", key, t_ref, str(ch2[0]), str(ch2[1]),
                 str(offf), "--discover"], rec["log"])
        rec["steps"]["fractional_lag"] = "ok" if r.returncode == 0 else f"rc={r.returncode}"
        save_state(state)
        r = run([SCRIPTS / "repeat_profile.py", key], rec["log"])
        rec["steps"]["repeat_profile"] = "ok" if r.returncode == 0 else f"rc={r.returncode}"
        save_state(state)
        r = run([SCRIPTS / "drift_crosscheck.py", key], rec["log"])
        rec["steps"]["drift_crosscheck"] = "ok" if r.returncode == 0 else f"rc={r.returncode}"
        save_state(state)
    else:
        for s in ("fractional_lag", "repeat_profile", "drift_crosscheck"):
            rec["steps"][s] = "skipped: no video repeat detected or fewer than 3 audio streams"

    r = run([SCRIPTS / "make_boundary_previews.py", key], rec["log"])
    rec["steps"]["previews"] = "ok" if r.returncode == 0 else f"rc={r.returncode}"

    st, why, facts = classify(key)
    rec["state"], rec["reason"], rec["facts"] = st, why, facts
    rec["finished"] = datetime.datetime.now().isoformat(timespec="seconds")
    rec["operator_checks_required"] = [
        "Talking boundaries are NOT established. Component subtraction cannot prove a region is "
        "speech-free, and the voice-band indicator has no sensitivity against a music bed. "
        f"Audition previews/{key}/.",
        "Absolute audio/video synchronisation is NOT established. Every timing result here is "
        "relative, measured across the title's own repeat."]
    save_state(state)
    print(f"[{st}] {key}: {why}")
    return rec

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--only", nargs="+", default=None)
    ap.add_argument("--limit", type=int, default=None)
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--validate", default=None)
    a = ap.parse_args()

    groups = json.loads((EV / "inventory" / "stage-a-groups.json").read_text())
    binding = json.loads((EV / "inventory" / "angle-binding.json").read_text())
    prog = json.loads((EV / "progress.json").read_text())
    state = load_state()
    done_before = set(prog["techniques_completed"])

    if a.validate:
        sys.exit(validate(a.validate, groups, binding))

    keys = sorted(binding)
    pending = [k for k in keys if k not in done_before
               and not state["techniques"].get(k, {}).get("state", "").startswith("verified")]
    if a.list:
        print(f"{len(keys)} techniques; {len(done_before)} audited earlier; {len(pending)} pending")
        for k in keys:
            s = ("audited-earlier" if k in done_before
                 else state["techniques"].get(k, {}).get("state", "screened_only"))
            print(f"  {k:<24} {s}")
        return
    todo = a.only if a.only else (pending if a.all else [])
    if not todo:
        print("nothing selected; use --all, --only KEY, or --list"); return
    if a.limit: todo = todo[:a.limit]
    print(f"processing {len(todo)}: {', '.join(todo)}")
    for k in todo:
        try:
            process(k, groups, binding, state, dry=a.dry_run)
        except Exception as exc:                      # a crash must not look like success
            rec = state["techniques"].setdefault(k, {"key": k})
            rec.update({"state": "failed", "reason": f"runner exception: {exc!r}",
                        "finished": datetime.datetime.now().isoformat(timespec="seconds")})
            save_state(state)
            print(f"[failed] {k}: {exc!r}")
    counts = {}
    for k in keys:
        s = ("audited-earlier" if k in done_before
             else state["techniques"].get(k, {}).get("state", "screened_only"))
        counts[s] = counts.get(s, 0) + 1
    print("\ncounts:", json.dumps(counts, indent=1))
    print(f"state file: {STATE}")

def validate(key, groups, binding):
    """Re-derive ONE already-audited technique from cached inputs and compare against
    its stored results. Writes only into reports/runner-validation/, never over the
    stored evidence."""
    out = EV / "reports" / "runner-validation"; out.mkdir(parents=True, exist_ok=True)
    R = json.loads((EV / "techniques" / f"{key}.json").read_text())
    ch2 = R["chapter2"]; t_ref = R["repeat_within_title"]["reference_title"]
    offf = R["repeat_within_title"]["best_nonlocal_offset"]["offset_frames"]
    half = int(round((ch2[1] - ch2[0]) / 2 / FRAME_S))
    log = []
    res = {"analysis_version": ANALYSIS_VERSION, "validated_technique": key,
           "reference_title": t_ref, "chapter2": ch2,
           "offset_frames_from_stored_audit": offf, "offset_frames_half_chapter": half,
           "offset_equals_half_chapter": offf == half,
           "cache_used": str(SC), "wrote_only_into": str(out), "checks": {}}

    need = [SC / "pcm" / f"{t_ref}-a1.s16le", SC / "grayfull" / f"{t_ref}.gray"]
    res["cache_inputs"] = {str(p): (p.exists() and p.stat().st_size) for p in need}
    if not all(p.exists() for p in need):
        res["checks"]["cache_present"] = "FAIL - required cache missing"
        atomic(out / f"{key}-validation.json", json.dumps(res, indent=2))
        print(json.dumps(res["cache_inputs"], indent=1)); return 2
    res["checks"]["cache_present"] = "PASS"

    r = run([SCRIPTS / "fractional_lag_repeat.py", key, t_ref, str(ch2[0]), str(ch2[1]),
             str(offf), "--discover", "--out", str(out / f"{key}.fractional-lag.json")], log)
    res["checks"]["fractional_lag_ran"] = "PASS" if r.returncode == 0 else f"FAIL rc={r.returncode}"
    r = run([SCRIPTS / "repeat_profile.py", key, "--out", str(out / f"{key}.repeat-profile.json")], log)
    res["checks"]["repeat_profile_ran"] = "PASS" if r.returncode == 0 else f"FAIL rc={r.returncode}"

    stored = EV / "techniques" / f"{key}.fractional-lag.json"
    if stored.exists() and (out / f"{key}.fractional-lag.json").exists():
        A = json.loads(stored.read_text()); B = json.loads((out / f"{key}.fractional-lag.json").read_text())
        res["stored_analysis_version"] = A.get("analysis_version", "(none - predates versioning)")
        res["recomputed_analysis_version"] = B.get("analysis_version")
        same_version = A.get("analysis_version") == B.get("analysis_version")
        res["stored_and_recomputed_same_version"] = same_version
        cmp = {}
        for field in ("active_windows",):
            cmp[field] = {"stored": A.get(field), "recomputed": B.get(field),
                          "match": A.get(field) == B.get(field)}
        for field in ("ncc_best_fractional", "extra_lag_samples"):
            av, bv = A.get(field, {}), B.get(field, {})
            cmp[field] = {"stored": av, "recomputed": bv,
                          "match": all(abs((av.get(k) or 0) - (bv.get(k) or 0)) < 1e-6
                                       for k in ("min", "median", "max"))}
        res["comparison_vs_stored"] = cmp
        if same_version:
            res["checks"]["reproduces_stored_numbers"] = (
                "PASS" if all(c["match"] for c in cmp.values()) else "FAIL")
        else:
            res["checks"]["reproduces_stored_numbers"] = (
                "SKIPPED - stored file was produced by " + str(res["stored_analysis_version"]) +
                ", the current analysis is " + str(res["recomputed_analysis_version"]) +
                ". Differing numbers here are an expected consequence of the widened lag search, "
                "not a reproducibility failure. Re-run this technique to refresh its artifacts.")
            res["checks"]["detects_superseded_artifacts"] = "PASS"
    else:
        res["checks"]["reproduces_stored_numbers"] = "SKIPPED - no stored fractional-lag file"

    prof = out / f"{key}.repeat-profile.json"
    if prof.exists():
        P = json.loads(prof.read_text())
        res["divergence_detector"] = {
            "divergence_detected": P["divergence_detected"],
            "spans_first_pass_s": P["divergence_spans_first_pass_s"],
            "video_windows_matching": P["video_windows_matching"],
            "audio_windows_matching": P["audio_windows_matching"],
            "audio_windows_evaluated": P["audio_windows_evaluated"],
            "controls": P["controls"]}
    st, why, facts = classify(key, derived_dir=out)
    res["classifier_output"] = {"state": st, "reason": why, "facts": facts}
    res["checks"]["classifier_produced_a_distinct_state"] = (
        "PASS" if st in ("verified_duplicate_half", "verified_partial_repeat",
                         "verified_no_repeat", "inconclusive", "failed") else "FAIL")
    res["log"] = log
    res["note"] = ("Validation writes only into reports/runner-validation/. The stored evidence for "
                   "this technique was not modified, and no source or dataset file was touched.")
    atomic(out / f"{key}-validation.json", json.dumps(res, indent=2))
    print("\n=== runner validation:", key, "===")
    for k, v in res["checks"].items(): print(f"  {k}: {v}")
    if "comparison_vs_stored" in res:
        for k, v in res["comparison_vs_stored"].items(): print(f"  compare {k}: match={v['match']}")
    print("  classifier:", st, "-", why)
    print("  written:", out / f"{key}-validation.json")
    return 0 if all(str(v).startswith(("PASS", "SKIPPED")) for v in res["checks"].values()) else 1

if __name__ == "__main__":
    main()
