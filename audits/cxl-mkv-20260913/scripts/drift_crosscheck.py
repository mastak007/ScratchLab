#!/usr/bin/env python3
"""Cross-check an apparent audio/video drift using the title's own repeat.

If chapter 2 repeats itself, the video repeat offset and the audio repeat offset must
agree.  Progressive A/V drift would make them differ.  This is independent of the
motion-envelope method and far more precise, so it can falsify a drift the envelope
method appears to show.

Usage: python3 scripts/drift_crosscheck.py <technique_key>
"""
import json, os, subprocess, sys
from pathlib import Path
import numpy as np
EV = Path(__file__).resolve().parent.parent
SRC = Path("/Volumes/Untitled/CXLrip")
SC = Path(os.environ.get("BATCH_SCRATCH", "/tmp/cxl-batch"))
SR = 48000
key = sys.argv[1]
R = json.load(open(EV / "techniques" / f"{key}.json"))
ch2 = R["chapter2"]
t_ref = R["repeat_within_title"]["reference_title"]
off_f = R["repeat_within_title"]["best_nonlocal_offset"]["offset_frames"]
off_s = off_f * 1001 / 30000

iso = np.fromfile(SC / "pcm" / f"{t_ref}-a1.s16le", dtype="<i2").reshape(-1, 2).mean(axis=1).astype(np.float64)
n = int((ch2[1] - ch2[0] - off_s) * SR)
s0 = int(ch2[0] * SR)
x = iso[s0:s0 + n]
def nc(u, v):
    n = min(len(u), len(v))          # the tail can run short at extreme lags
    if n == 0: return 0.0
    u = u[:n] - u[:n].mean(); v = v[:n] - v[:n].mean()
    return float(u @ v / (np.linalg.norm(u) * np.linalg.norm(v) + 1e-12))
scan = {}
for d in range(-960, 961, 1):              # +-20 ms at sample resolution
    st = s0 + int(round(off_s * SR)) + d
    scan[d] = nc(x, iso[st:st + n])
bd = max(scan, key=scan.get)
res = {
  "technique": key, "reference_title": t_ref,
  "video_repeat_offset_frames": off_f, "video_repeat_offset_s": round(off_s, 6),
  "video_repeat_mean_similarity": R["repeat_within_title"]["best_nonlocal_offset"]["mean_similarity"],
  "audio_repeat_extra_lag_samples": bd,
  "audio_repeat_extra_lag_ms": round(bd / SR * 1000, 4),
  "audio_repeat_ncc_at_best": round(scan[bd], 6),
  "audio_repeat_ncc_at_video_offset": round(scan[0], 6),
  "window_s": round(n / SR, 3),
  "verdict": None,
  "caveat": "This compares the audio timeline with the video timeline across the title's own "
            "repeat. It constrains RELATIVE timing over the repeated span and can rule out "
            "progressive drift. It does NOT measure absolute audio/video synchronisation, and a "
            "constant absolute offset would be invisible to it. Where the repeat offset is not a "
            "whole number of audio samples, use scripts/fractional_lag_repeat.py instead - integer "
            "lag alone under-reports the match.",
}
res["verdict"] = (
  "No A/V drift: over %.1f s the audio repeats at the video's own repeat offset to within "
  "%.2f ms (%d samples). A drift of even one frame (33.4 ms) would have shown here."
  % (n / SR, abs(bd) / SR * 1000, bd)) if abs(bd) < 480 else (
  "Audio and video repeat offsets differ by %.2f ms - investigate." % (bd / SR * 1000))
(EV / "techniques" / f"{key}.drift-crosscheck.json").write_text(json.dumps(res, indent=2))
print(json.dumps(res, indent=2))
