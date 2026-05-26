#!/usr/bin/env bash
#
# Rebuilds baby_reel_callresponse.wav AND authors baby_reel.json
# + baby_scratch.json from four clean per-demo takes:
#   ~/Downloads/Baby1.mp4 .. Baby4.mp4
#
# Pipeline:
#   1. For each take: decode mono 44.1 kHz, RMS-detect onsets
#      (window 2048 / hop 1024 / threshold max(0.04, mean+0.6σ)) and
#      validate the detected count matches the per-demo target
#      (19 / 19 / 13 / 24). Abort with a per-take report on mismatch
#      — no silent count drift reaches the JSON.
#   2. Trim each take to [first_onset - 0.05, last_offset + 0.05].
#   3. Concat
#        Baby1_trim + 5.393s + Baby2_trim + 5.393s + Baby3_trim +
#        5.393s + Baby4_trim + 5.393s
#      into baby_reel_callresponse.wav (mono 44.1 kHz PCM16, ≈ 41.4s).
#      5.393s = two musical measures at 89 BPM.
#   4. Author baby_reel.json — 4 demo segments + 4 copy segments,
#      strict F/B alternation from forward per demo (polarity resets
#      per demo), faderState "open" throughout, final stroke per demo
#      extended to (demo_end - 0.02s) as the long let-go drag,
#      copy segments contain no strokes.
#   5. Author baby_scratch.json — Baby2's 19 strokes shifted so the
#      first onset sits at t=0, same alternation / let-go / fader rules.
#
# Idempotent. Does not modify source files. Aborts on any onset-count
# mismatch. Retired: demo_baby_scratch.mov is no longer touched.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OUT_AUDIO="$REPO_ROOT/ScratchLab/Resources/CoachDemoAudio/baby_reel_callresponse.wav"
OUT_REEL_JSON="$REPO_ROOT/ScratchLab/Resources/CoachDemoAudio/baby_reel.json"
OUT_SCRATCH_JSON="$REPO_ROOT/ScratchLab/Resources/Notation/baby_scratch.json"

BABY1="$HOME/Downloads/Baby1.mp4"
BABY2="$HOME/Downloads/Baby2.mp4"
BABY3="$HOME/Downloads/Baby3.mp4"
BABY4="$HOME/Downloads/Baby4.mp4"

for f in "$BABY1" "$BABY2" "$BABY3" "$BABY4"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: source not found: $f" >&2
    exit 2
  fi
done

echo "Sources:"
for f in "$BABY1" "$BABY2" "$BABY3" "$BABY4"; do echo "  $f"; done
echo
echo "Outputs:"
echo "  $OUT_AUDIO"
echo "  $OUT_REEL_JSON"
echo "  $OUT_SCRATCH_JSON"
echo

python3 - "$BABY1" "$BABY2" "$BABY3" "$BABY4" \
           "$OUT_AUDIO" "$OUT_REEL_JSON" "$OUT_SCRATCH_JSON" <<'PY'
import os, sys, math, json, wave, struct, statistics, subprocess, tempfile

(baby1, baby2, baby3, baby4,
 out_audio, out_reel_json, out_scratch_json) = sys.argv[1:8]

SR        = 44100
WIN       = 2048
HOP       = 1024
PRE_PAD   = 0.05
POST_PAD  = 0.05
BPM       = 89
SILENCE   = 2.0 * 4.0 * 60.0 / BPM    # 5.393s — two measures at 89 BPM
TARGETS   = [19, 19, 13, 24]
TAKES     = [baby1, baby2, baby3, baby4]
LET_GO_TAIL = 0.02

# Detected-onset overrides — indices into the RMS detector's output that
# we know are doubled triggers off a single attack (40 ms hysteresis can
# still let through a second hit when the second peak sits ~120 ms after
# the first). Dropped before per-take count validation. Anchored to the
# specific recording cut; revisit if the take is re-recorded.
DROP_ONSETS_BY_BASENAME = {
    "Baby3.mp4": [2],   # 0.697s — double trigger off the 0.580s attack
}

def decode_mono(path):
    fd, tmp = tempfile.mkstemp(suffix='.wav'); os.close(fd)
    subprocess.run(
        ['ffmpeg', '-y', '-v', 'error', '-i', path,
         '-vn', '-ac', '1', '-ar', str(SR), '-c:a', 'pcm_s16le', tmp],
        check=True,
    )
    wf = wave.open(tmp, 'rb')
    raw = wf.readframes(wf.getnframes())
    wf.close()
    os.remove(tmp)
    return [s / 32768.0 for s in struct.unpack(f'<{len(raw)//2}h', raw)]

def compute_rms(samples):
    return [
        math.sqrt(sum(x * x for x in samples[i:i + WIN]) / WIN)
        for i in range(0, len(samples) - WIN + 1, HOP)
    ]

def threshold(rms):
    mn = statistics.mean(rms)
    sd = statistics.stdev(rms) if len(rms) > 1 else 0.0
    return max(0.04, mn + 0.6 * sd)

def detect_onsets(rms, thr):
    """Attack-edge detector with hysteresis. Reports the first frame
    where RMS crosses above thr after at least `quiet_frames` of
    being below it. Tight Baby Scratch doubles can sit ~50 ms apart,
    so the quiet window is intentionally narrow."""
    quiet_frames_needed = max(2, int(0.040 * SR / HOP))   # ~40 ms
    onsets = []
    above = False
    quiet_count = quiet_frames_needed
    for i, r in enumerate(rms):
        if r >= thr:
            if not above and quiet_count >= quiet_frames_needed:
                onsets.append(i)
            above = True
            quiet_count = 0
        else:
            above = False
            quiet_count += 1
    return onsets

def last_offset_frame(rms, thr):
    for i in range(len(rms) - 1, -1, -1):
        if rms[i] >= thr:
            return i
    return None

def frame_to_seconds(frame):
    return frame * HOP / SR

def speed_for(duration):
    if duration < 0.15:
        return "fast"
    if duration < 0.40:
        return "medium"
    return "slow"

def make_strokes(onsets_sec, take_end_sec, segment_offset_sec):
    n = len(onsets_sec)
    out = []
    for i, t in enumerate(onsets_sec):
        is_last = (i == n - 1)
        if is_last:
            start = t
            end = max(start + 0.30, take_end_sec - LET_GO_TAIL)
            speed = "slow"
        else:
            start = t
            nxt = onsets_sec[i + 1]
            end = min(nxt, t + 0.500)
            speed = speed_for(end - start)
        direction = "forward" if (i % 2 == 0) else "backward"
        out.append({
            "startTime":           round(start + segment_offset_sec, 4),
            "endTime":             round(end   + segment_offset_sec, 4),
            "direction":           direction,
            "speedClassification": speed,
            "faderState":          "open",
        })
    return out

# --- Per-take onset detection -------------------------------------------
print("=== Per-take onset detection ===")
detected = []
abort = False
for path, target in zip(TAKES, TARGETS):
    samples = decode_mono(path)
    rms = compute_rms(samples)
    thr = threshold(rms)
    onset_frames = detect_onsets(rms, thr)
    onsets_full = [frame_to_seconds(f) for f in onset_frames]
    last_off_frame = last_offset_frame(rms, thr)
    if not onsets_full or last_off_frame is None:
        print(f"  {os.path.basename(path)}: NO ONSETS DETECTED — abort")
        abort = True
        continue
    basename = os.path.basename(path)
    drop_set = set(DROP_ONSETS_BY_BASENAME.get(basename, []))
    if drop_set:
        kept = [t for i, t in enumerate(onsets_full) if i not in drop_set]
        dropped_ts = [t for i, t in enumerate(onsets_full) if i in drop_set]
        print(f"  {basename}: dropping {len(drop_set)} known-double onset(s): "
              + ", ".join(f"{t:.3f}" for t in dropped_ts))
        onsets_full = kept
    first_onset = onsets_full[0]
    last_offset = frame_to_seconds(last_off_frame) + WIN / SR
    trim_start  = max(0.0, first_onset - PRE_PAD)
    trim_end    = min(len(samples) / SR, last_offset + POST_PAD)
    trimmed_dur = trim_end - trim_start
    onsets_trim = [o - trim_start for o in onsets_full]
    print(f"  {os.path.basename(path)}: detected {len(onsets_full)} / target {target}")
    print(f"    first_onset={first_onset:.3f}s  "
          f"last_offset={last_offset:.3f}s  "
          f"trimmed={trimmed_dur:.3f}s  thr={thr:.4f}")
    if len(onsets_full) != target:
        print(f"    ONSET COUNT MISMATCH — all onsets: "
              + ", ".join(f"{t:.3f}" for t in onsets_full))
        abort = True
    detected.append({
        "path":           path,
        "trim_start":     trim_start,
        "trim_end":       trim_end,
        "trimmed_dur":    trimmed_dur,
        "onsets_in_trim": onsets_trim,
    })

if abort:
    print()
    print("Aborting before any output file is written. Re-tune the detector,")
    print("re-perform the take, or supply a manual onset list, then re-run.")
    sys.exit(3)

# --- Trim each take -----------------------------------------------------
trimmed_paths = []
for i, d in enumerate(detected, start=1):
    fd, trim_wav = tempfile.mkstemp(prefix=f"baby{i}_trim_", suffix='.wav')
    os.close(fd)
    subprocess.run([
        'ffmpeg', '-y', '-v', 'error',
        '-ss', f"{d['trim_start']:.6f}",
        '-to', f"{d['trim_end']:.6f}",
        '-i', d['path'],
        '-vn', '-ac', '1', '-ar', str(SR), '-c:a', 'pcm_s16le', trim_wav,
    ], check=True)
    trimmed_paths.append(trim_wav)

# --- Silence WAV (one shared instance) ----------------------------------
fd, silence_wav = tempfile.mkstemp(prefix='silence_', suffix='.wav')
os.close(fd)
subprocess.run([
    'ffmpeg', '-y', '-v', 'error',
    '-f', 'lavfi',
    '-i', f'anullsrc=channel_layout=mono:sample_rate={SR}',
    '-t', f"{SILENCE:.6f}",
    '-c:a', 'pcm_s16le', silence_wav,
], check=True)

# --- Concat sequence -----------------------------------------------------
sequence = []
for tp in trimmed_paths:
    sequence.append(tp)
    sequence.append(silence_wav)

fd, concat_list = tempfile.mkstemp(prefix='concat_', suffix='.txt')
os.close(fd)
with open(concat_list, 'w') as f:
    for s in sequence:
        f.write(f"file '{s}'\n")

os.makedirs(os.path.dirname(out_audio), exist_ok=True)
subprocess.run([
    'ffmpeg', '-y', '-v', 'error',
    '-f', 'concat', '-safe', '0', '-i', concat_list,
    '-ar', str(SR), '-ac', '1', '-c:a', 'pcm_s16le',
    out_audio,
], check=True)

wf = wave.open(out_audio, 'rb')
audio_duration = wf.getnframes() / wf.getframerate()
wf.close()

for p in trimmed_paths + [silence_wav, concat_list]:
    try:
        os.remove(p)
    except OSError:
        pass

# --- Assemble baby_reel.json --------------------------------------------
segments = []
strokes_all = []
cursor = 0.0
for demo_idx, d in enumerate(detected):
    demo_start = cursor
    demo_end   = cursor + d['trimmed_dur']
    segments.append({
        "kind":      "demo",
        "startTime": round(demo_start, 4),
        "endTime":   round(demo_end,   4),
        "label":     f"Demo {demo_idx + 1}",
    })
    strokes_all.extend(make_strokes(
        d['onsets_in_trim'],
        take_end_sec      = d['trimmed_dur'],
        segment_offset_sec = demo_start,
    ))
    cursor = demo_end
    copy_start = cursor
    copy_end   = cursor + SILENCE
    segments.append({
        "kind":      "copy",
        "startTime": round(copy_start, 4),
        "endTime":   round(copy_end,   4),
        "label":     f"Your turn {demo_idx + 1}",
    })
    cursor = copy_end

reel = {
    "version":       1,
    "timelineID":    "baby_reel_v7_baby1to4_19_19_13_24_letgo",
    "scratchID":     "baby",
    "audioFile":     os.path.basename(out_audio),
    "audioDuration": round(audio_duration, 3),
    "bpm":           BPM,
    "segments":      segments,
    "strokes":       strokes_all,
}
os.makedirs(os.path.dirname(out_reel_json), exist_ok=True)
with open(out_reel_json, 'w') as f:
    json.dump(reel, f, indent=2)
    f.write("\n")

# --- Assemble baby_scratch.json (Baby2 loop source) ---------------------
# Strokes are shifted back by PRE_PAD so the first stroke sits at exactly
# t=0 and the last stroke's endTime defines phraseEnd. This gives the
# practice lane a seamless loop tile (no leading silence band between
# repetitions) — matches the previous baby_scratch.json convention.
baby2 = detected[1]
scratch_strokes = make_strokes(
    baby2['onsets_in_trim'],
    take_end_sec       = baby2['trimmed_dur'],
    segment_offset_sec = 0.0,
)
for s in scratch_strokes:
    s["startTime"] = round(s["startTime"] - PRE_PAD, 4)
    s["endTime"]   = round(s["endTime"]   - PRE_PAD, 4)
phrase_end = scratch_strokes[-1]["endTime"]
scratch = {
    "demoEnd":      phrase_end,
    "demoStart":    0,
    "phraseEnd":    phrase_end,
    "phraseStart":  0,
    "scratchID":    "baby",
    "strokes":      scratch_strokes,
    "timingBasis":  "audio_peak_detect_baby2_v1",
    "version":      1,
}
os.makedirs(os.path.dirname(out_scratch_json), exist_ok=True)
with open(out_scratch_json, 'w') as f:
    json.dump(scratch, f, indent=2)
    f.write("\n")

# --- Summary ------------------------------------------------------------
print()
print("=== Summary ===")
for i, seg in enumerate(segments):
    print(f"  segment[{i}] {seg['kind']:4} {seg['label']:14} "
          f"{seg['startTime']:7.3f} → {seg['endTime']:7.3f}")
print(f"  audio duration : {audio_duration:.3f}s")
print(f"  reel strokes   : {len(strokes_all)} (expected {sum(TARGETS)})")
print(f"  baby2 strokes  : {len(scratch_strokes)} (expected 19)")
print(f"  output audio   : {out_audio}")
print(f"  output reel    : {out_reel_json}")
print(f"  output scratch : {out_scratch_json}")
PY

echo
echo "Done."
afinfo "$OUT_AUDIO" | head -8
