#!/usr/bin/env python3
"""Resolve a repeat whose offset is not a whole number of audio samples.

A video repeat of N frames lands at N*1001/30000*48000 = N*1601.6 audio samples,
which is fractional whenever N is not a multiple of 5. Integer-lag correlation then
under-reports the match, and the apparent best integer lag can wander by a few
samples along a span when the authored copy contains a splice. This measures the
best FRACTIONAL lag per window using an FFT phase shift, which is the honest way to
ask whether the audio repeats.

--discover additionally finds the audio's OWN best repeat offset by normalised FFT
cross-correlation, without taking the offset from the video. The runner compares the
two; they must agree, and neither is assumed to be half the chapter duration.

Nothing here measures absolute audio/video synchronisation. A repeat offset is a
relative measurement inside one timeline.

Usage:
  fractional_lag_repeat.py <key> <title> <ch2start> <ch2end> <offset_frames>
                           [--out PATH] [--discover] [--probe-s 6] [--max-lag 32]
"""
import argparse, json, os, sys, tempfile
from pathlib import Path
import numpy as np

ANALYSIS_VERSION = "fractional_lag_repeat/2"
EV = Path(__file__).resolve().parent.parent
SC = Path(os.environ.get("BATCH_SCRATCH", "/tmp/cxl-batch"))
SR = 48000
FRAME_S = 1001 / 30000

ap = argparse.ArgumentParser()
ap.add_argument("key"); ap.add_argument("title")
ap.add_argument("ch2start", type=float); ap.add_argument("ch2end", type=float)
ap.add_argument("offset_frames", type=int)
ap.add_argument("--out", default=None)
ap.add_argument("--discover", action="store_true")
ap.add_argument("--probe-s", type=float, default=6.0)
ap.add_argument("--max-lag", type=float, default=32.0)
a = ap.parse_args()

off_exact = a.offset_frames * FRAME_S * SR
iso_path = SC / "pcm" / f"{a.title}-a1.s16le"
if not iso_path.exists():
    print(f"MISSING CACHE: {iso_path}", file=sys.stderr); sys.exit(3)
iso = np.fromfile(iso_path, dtype="<i2").reshape(-1, 2).mean(axis=1).astype(np.float64)

def atomic(path, text):
    path = Path(path); path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=".tmp-")
    with os.fdopen(fd, "w") as fh: fh.write(text)
    os.replace(tmp, path)

def shift(x, frac):
    n = len(x); X = np.fft.rfft(x); f = np.fft.rfftfreq(n, 1.0)
    return np.fft.irfft(X * np.exp(-2j * np.pi * f * frac), n)

def nc(u, v):
    n = min(len(u), len(v))
    if n == 0: return 0.0
    u = u[:n] - u[:n].mean(); v = v[:n] - v[:n].mean()
    d = np.linalg.norm(u) * np.linalg.norm(v)
    return float(u @ v / d) if d > 0 else 0.0

def discover(seg, probe_s):
    """Best non-trivial self-match of `seg`, all integer lags, normalised."""
    n = int(probe_s * SR)
    if len(seg) < 3 * n: return None
    p = seg[:n] - seg[:n].mean()
    N = 1 << int(np.ceil(np.log2(len(seg) + n)))
    cc = np.fft.irfft(np.fft.rfft(seg, N) * np.conj(np.fft.rfft(p, N)))[:len(seg) - n + 1]
    cs = np.concatenate([[0.0], np.cumsum(seg ** 2)])
    cm = np.concatenate([[0.0], np.cumsum(seg)])
    e = cs[n:] - cs[:-n]; m = (cm[n:] - cm[:-n]) / n
    r = cc / np.maximum(np.sqrt(np.maximum(e - n * m * m, 1e-9)) * np.linalg.norm(p), 1e-9)
    r[:int(2 * SR)] = -1
    k = int(np.argmax(r))
    top = np.argsort(r)[::-1][:2000]; keep = []
    for i in top:
        if all(abs(i - j) > SR for j in keep): keep.append(int(i))
        if len(keep) == 3: break
    return {"best_offset_s": round(k / SR, 6), "best_offset_frames_nearest": int(round(k / SR / FRAME_S)),
            "ncc": round(float(r[k]), 5), "probe_s": probe_s,
            "top_distinct_peaks": [{"offset_s": round(i / SR, 6), "ncc": round(float(r[i]), 5)} for i in keep]}

s0 = int(a.ch2start * SR); s1 = int(min(a.ch2end, len(iso) / SR) * SR)
out = {"analysis_version": ANALYSIS_VERSION, "technique": a.key, "title": a.title,
       "chapter2": [a.ch2start, a.ch2end],
       "offset_frames": a.offset_frames, "offset_exact_samples": round(off_exact, 3),
       "offset_is_whole_samples": abs(off_exact - round(off_exact)) < 1e-6,
       "half_chapter_offset_frames": int(round((a.ch2end - a.ch2start) / 2 / FRAME_S)),
       "params": {"probe_s": a.probe_s, "max_lag_samples": a.max_lag, "window_s": 1.0,
                  "active_rms_threshold": 200}}
out["offset_equals_half_chapter"] = out["offset_frames"] == out["half_chapter_offset_frames"]

if a.discover:
    out["audio_discovered_offset"] = discover(iso[s0:s1], a.probe_s)
    d = out["audio_discovered_offset"]
    if d:
        out["audio_vs_supplied_offset_delta_ms"] = round((d["best_offset_s"] - a.offset_frames * FRAME_S) * 1000, 3)

base = int(np.floor(off_exact)); frac0 = off_exact - base
PAD = int(a.max_lag) + 8
rows = []
t = a.ch2start
while t + 1.0 <= a.ch2start + off_exact / SR and int(t * SR) + base + SR + PAD <= len(iso):
    p0 = int(t * SR); n = SR
    w = iso[p0:p0 + n]
    if np.sqrt((w ** 2).mean()) < 200:      # pauses: correlation there is hum-dominated
        t += 1.0; continue
    braw = iso[p0 + base - PAD:p0 + base + n + PAD]
    best = (-2.0, 0.0)
    for d in np.arange(-a.max_lag, a.max_lag + 0.01, 0.25):
        c = nc(w, shift(braw, frac0 + d)[PAD:PAD + n])
        if c > best[0]: best = (c, float(d))
    for d in np.arange(best[1] - 0.3, best[1] + 0.31, 0.02):
        c = nc(w, shift(braw, frac0 + d)[PAD:PAD + n])
        if c > best[0]: best = (c, float(d))
    rows.append({"t_s": round(t, 3),
                 "ncc_integer_lag": round(nc(w, iso[p0 + base:p0 + base + n]), 4),
                 "ncc_best_fractional": round(best[0], 4),
                 "extra_lag_samples": round(best[1], 3),
                 "lag_hit_search_bound": abs(abs(best[1]) - a.max_lag) < 0.26,
                 "rms": round(float(np.sqrt((w ** 2).mean())), 0)})
    t += 1.0

if not rows:
    out["error"] = "no active windows found"
    atomic(a.out or (EV / "techniques" / f"{a.key}.fractional-lag.json"), json.dumps(out, indent=2))
    print(f"{a.key}: NO ACTIVE WINDOWS"); sys.exit(4)

ints = [r["ncc_integer_lag"] for r in rows]
fr = [r["ncc_best_fractional"] for r in rows]
lg = [r["extra_lag_samples"] for r in rows]
poor = [r for r in rows if r["ncc_best_fractional"] < 0.90]
out.update({
  "active_windows": len(rows),
  "ncc_integer_lag": {"min": min(ints), "median": float(np.median(ints)), "max": max(ints)},
  "ncc_best_fractional": {"min": min(fr), "median": float(np.median(fr)), "max": max(fr)},
  "extra_lag_samples": {"min": min(lg), "median": float(np.median(lg)), "max": max(lg),
                        "spread": round(max(lg) - min(lg), 3)},
  "any_lag_hit_search_bound": any(r["lag_hit_search_bound"] for r in rows),
  "windows_below_0.90": [r["t_s"] for r in poor],
  "n_windows_below_0.90": len(poor),
  "caveat": "Relative timing within one audio timeline. Not absolute audio/video sync, and no "
            "statement about speech.",
  "windows": rows})
atomic(a.out or (EV / "techniques" / f"{a.key}.fractional-lag.json"), json.dumps(out, indent=2))
print(f"{a.key} {a.title}: offset {a.offset_frames} fr = {off_exact:.1f} samples "
      f"(whole: {out['offset_is_whole_samples']}, == half chapter: {out['offset_equals_half_chapter']})")
if a.discover and out.get("audio_discovered_offset"):
    d = out["audio_discovered_offset"]
    print(f"  audio-discovered offset {d['best_offset_s']:.4f}s (ncc {d['ncc']:.4f}), "
          f"delta vs supplied {out['audio_vs_supplied_offset_delta_ms']:+.2f} ms")
print(f"  windows {len(rows)}  int-lag ncc {min(ints):.3f}/{np.median(ints):.3f}/{max(ints):.3f}  "
      f"frac ncc {min(fr):.3f}/{np.median(fr):.3f}/{max(fr):.3f}  "
      f"lag {min(lg):+.2f}..{max(lg):+.2f}  below0.90: {len(poor)}")
