#!/usr/bin/env python3
"""Localise a repeat instead of scoring it with one number, and detect the
picture-duplicates-but-audio-does-not signature found in tears_98bpm.

A single whole-span correlation cannot tell "no repeat" from "a repeat covering
part of the span" from "a repeat with a wandering offset", and it is blind to a
short divergent stretch. This walks windows across chapter 2 and reports per window:
  * video frame similarity at the detected offset;
  * isolated-scratch audio ncc at the best FRACTIONAL lag (integer lag under-reports
    whenever the offset is not a whole number of audio samples);
  * the audio's own best lag, so a moving offset or a splice is visible.

A window where the video still matches but the audio does not means the two passes
carry the same picture and different sound. That is an audio/video pairing problem in
the source and is reported as a divergence, never silently averaged away.

Usage: repeat_profile.py <key> [--out PATH] [--window-s 1.0] [--max-lag 32]
"""
import argparse, json, os, subprocess, sys, tempfile
from pathlib import Path
import numpy as np

ANALYSIS_VERSION = "repeat_profile/2"
EV = Path(__file__).resolve().parent.parent
SRC = Path("/Volumes/Untitled/CXLrip")
SC = Path(os.environ.get("BATCH_SCRATCH", "/tmp/cxl-batch"))
SR = 48000; VW, VH = 360, 240; FRAME_S = 1001 / 30000
VIDEO_MATCH = 0.995          # video counts as duplicated above this
AUDIO_MATCH = 0.90           # audio counts as duplicated above this

ap = argparse.ArgumentParser()
ap.add_argument("key"); ap.add_argument("--out", default=None)
ap.add_argument("--window-s", type=float, default=1.0)
ap.add_argument("--max-lag", type=float, default=32.0)
a = ap.parse_args()

R = json.load(open(EV / "techniques" / f"{a.key}.json"))
ch2 = R["chapter2"]; t_ref = R["repeat_within_title"]["reference_title"]
off_f = R["repeat_within_title"]["best_nonlocal_offset"]["offset_frames"]
off_s = off_f * FRAME_S; off_exact = off_s * SR
nA = R["audio"]["n_streams"]

def atomic(path, text):
    path = Path(path); path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=".tmp-")
    with os.fdopen(fd, "w") as fh: fh.write(text)
    os.replace(tmp, path)

def gray_full(title):
    dst = SC / "grayfull" / f"{title}.gray"
    if not dst.exists() or dst.stat().st_size == 0:
        dst.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-i", str(SRC / f"{title}.mkv"),
                        "-map", "0:v:0", "-vf", f"scale={VW}:{VH}:flags=bicubic,format=gray",
                        "-fps_mode", "passthrough", "-f", "rawvideo", str(dst)], check=True)
    return np.fromfile(dst, dtype=np.uint8).reshape(-1, VH, VW).astype(np.float32)

def shift(x, frac):
    n = len(x); X = np.fft.rfft(x); f = np.fft.rfftfreq(n, 1.0)
    return np.fft.irfft(X * np.exp(-2j * np.pi * f * frac), n)

def nc(u, v):
    n = min(len(u), len(v))
    if n == 0: return 0.0
    u = u[:n] - u[:n].mean(); v = v[:n] - v[:n].mean()
    d = np.linalg.norm(u) * np.linalg.norm(v)
    return float(u @ v / d) if d > 0 else 0.0

f = gray_full(t_ref)
pts = np.array([float(x["pts_time"]) for x in json.loads(subprocess.run(
    ["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "frame=pts_time",
     "-of", "json", str(SRC / f"{t_ref}.mkv")], capture_output=True, text=True).stdout)["frames"]])
D = f.reshape(len(f), -1); D = D - D.mean(1, keepdims=True)
D /= (np.linalg.norm(D, axis=1, keepdims=True) + 1e-9)
i_lo = int(np.argmin(np.abs(pts - ch2[0])))
adj = float(np.mean([D[i] @ D[i+1] for i in range(i_lo, min(i_lo+200, len(D)-1))]))
rnd = float(np.mean([D[i] @ D[(i+457) % len(D)] for i in range(i_lo, min(i_lo+200, len(D)))]))

iso = (np.fromfile(SC / "pcm" / f"{t_ref}-a1.s16le", dtype="<i2").reshape(-1, 2).mean(axis=1).astype(np.float64)
       if nA == 3 else None)
base = int(np.floor(off_exact)); frac0 = off_exact - base
PAD = int(a.max_lag) + 8
W = int(a.window_s * SR)

rows = []
t = ch2[0]
while t + a.window_s <= ch2[0] + off_s:
    i0 = int(np.argmin(np.abs(pts - t)))
    nfr = max(1, int(a.window_s / FRAME_S))
    vs = [float(D[i] @ D[i + off_f]) for i in range(i0, i0 + nfr) if i + off_f < len(D)]
    row = {"t_s": round(t, 3), "video_sim": round(float(np.mean(vs)), 5) if vs else None}
    if iso is not None:
        p0 = int(t * SR)
        if p0 + base + W + PAD <= len(iso):
            w = iso[p0:p0 + W]; rms = float(np.sqrt((w ** 2).mean()))
            row["iso_rms"] = round(rms, 0)
            if rms >= 200:
                braw = iso[p0 + base - PAD:p0 + base + W + PAD]
                best = (-2.0, 0.0)
                for d in np.arange(-a.max_lag, a.max_lag + 0.01, 0.25):
                    c = nc(w, shift(braw, frac0 + d)[PAD:PAD + W])
                    if c > best[0]: best = (c, float(d))
                row["iso_ncc_integer_lag"] = round(nc(w, iso[p0+base:p0+base+W]), 4)
                row["iso_ncc_best_fractional"] = round(best[0], 4)
                row["iso_best_lag_samples"] = round(best[1], 3)
            else:
                row["iso_skipped"] = "pause: below the 200 RMS activity threshold"
    rows.append(row)
    t += a.window_s

div = [r for r in rows if r.get("video_sim", 0) >= VIDEO_MATCH
       and "iso_ncc_best_fractional" in r and r["iso_ncc_best_fractional"] < AUDIO_MATCH]
# merge adjacent divergent windows into spans
spans = []
for r in div:
    if spans and abs(r["t_s"] - spans[-1][1]) < a.window_s * 1.5: spans[-1][1] = r["t_s"] + a.window_s
    else: spans.append([r["t_s"], r["t_s"] + a.window_s])

out = {
  "analysis_version": ANALYSIS_VERSION, "technique": a.key, "reference_title": t_ref,
  "chapter2": ch2, "offset_frames": off_f, "offset_s": round(off_s, 6),
  "params": {"window_s": a.window_s, "max_lag_samples": a.max_lag,
             "video_match_threshold": VIDEO_MATCH, "audio_match_threshold": AUDIO_MATCH,
             "activity_rms_threshold": 200},
  "controls": {"adjacent_frame_similarity": round(adj, 5), "random_pair_similarity": round(rnd, 5)},
  "windows": len(rows),
  "video_windows_matching": len([r for r in rows if (r.get("video_sim") or 0) >= VIDEO_MATCH]),
  "audio_windows_evaluated": len([r for r in rows if "iso_ncc_best_fractional" in r]),
  "audio_windows_matching": len([r for r in rows if r.get("iso_ncc_best_fractional", 0) >= AUDIO_MATCH]),
  "divergence_windows_video_ok_audio_not": [r["t_s"] for r in div],
  "divergence_spans_first_pass_s": [[round(x, 3), round(y, 3)] for x, y in spans],
  "divergence_spans_second_pass_s": [[round(x + off_s, 3), round(y + off_s, 3)] for x, y in spans],
  "divergence_detected": bool(spans),
  "interpretation": ("Windows where the picture still duplicates but the isolated scratch does not. "
                     "In those the two passes carry the same image and different sound, so at least "
                     "one pass has picture and audio that do not correspond. This does NOT say which "
                     "pass is faithful, and it is not a statement about absolute A/V sync."),
  "profile": rows,
}
atomic(a.out or (EV / "techniques" / f"{a.key}.repeat-profile.json"), json.dumps(out, indent=2))
print(f"{a.key}: offset {off_f} fr ({off_s:.4f}s), {len(rows)} x {a.window_s}s windows")
print(f"  controls: adjacent {adj:.5f}, random {rnd:.5f}")
print(f"  video matching {out['video_windows_matching']}/{len(rows)}   "
      f"audio matching {out['audio_windows_matching']}/{out['audio_windows_evaluated']} evaluated")
print(f"  DIVERGENCE spans (video ok, audio not): {out['divergence_spans_first_pass_s'] or 'none'}")
if spans: print(f"  second-pass counterparts: {out['divergence_spans_second_pass_s']}")
