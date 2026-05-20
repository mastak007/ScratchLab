#!/usr/bin/env python3
"""Local-only Baby Scratch candidate extractor for a YouTube media folder.

Walks a local input folder, scores fixed-length windows for scratch-heavy
repeated-transient activity, and exports the top non-overlapping candidates as
WAV (and optionally MP4) clips alongside a JSON manifest. The manifest is for
human review only -- it never marks anything approved for training and never
stores absolute paths or provenance fields.
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass, asdict
from pathlib import Path
from typing import Any


SCHEMA_VERSION = 1
PURPOSE = "local_candidate_review"
REVIEW_LABEL = "candidate_baby_scratch"
MANIFEST_FILENAME = "candidate_manifest.json"
WAV_SUBDIR = "wav"
VIDEO_SUBDIR = "video"

MEDIA_EXTENSIONS = frozenset(
    {".mp4", ".mov", ".m4v", ".mkv", ".webm", ".wav", ".aif", ".aiff", ".mp3", ".m4a", ".flac"}
)
VIDEO_EXTENSIONS = frozenset({".mp4", ".mov", ".m4v", ".mkv", ".webm"})

FORBIDDEN_TOKENS: tuple[str, ...] = (
    "/Users/",
    "Karl Watson",
    "karlwatson",
    "MakeMKV",
    "sourceMKV",
    "processed_makemkv",
    "QBERT",
    "Qbert",
    "SXRATCH",
    "SOURCE_ID",
    "rightsStatus",
    "reviewStatus",
)

MISSING_DEPS_HINT = (
    "Install required dependencies before running this script:\n"
    "  brew install ffmpeg\n"
    "  python3 -m pip install librosa soundfile numpy"
)


@dataclass
class Candidate:
    clip_id: str
    source_file: str
    source_stem: str
    start_time: float
    end_time: float
    duration: float
    bpm_estimate: float | None
    bars_estimate: float
    score: float
    onset_count: int
    onset_rate_per_second: float
    silence_ratio: float
    median_centroid: float
    exported_wav: str
    exported_video: str | None
    review_label: str = REVIEW_LABEL
    approved_for_training: bool = False


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Scan a local YouTube media folder for Baby Scratch candidate clips "
            "of at least N bars and export them for offline review."
        )
    )
    parser.add_argument("--input", required=True, type=Path, help="Input folder to scan recursively.")
    parser.add_argument("--output", required=True, type=Path, help="Output folder for candidate clips and manifest.")
    parser.add_argument("--min-bars", type=int, default=8, help="Minimum candidate length in bars (default: 8).")
    parser.add_argument("--beats-per-bar", type=int, default=4, help="Beats per bar (default: 4).")
    parser.add_argument(
        "--fallback-min-seconds",
        type=float,
        default=16.0,
        help="Conservative minimum window duration when BPM cannot be estimated (default: 16.0).",
    )
    parser.add_argument(
        "--absolute-min-seconds",
        type=float,
        default=8.0,
        help="Hard floor on window duration regardless of BPM (default: 8.0).",
    )
    parser.add_argument(
        "--hop-seconds",
        type=float,
        default=1.0,
        help="Stride between candidate windows during scoring (default: 1.0).",
    )
    parser.add_argument(
        "--score-threshold",
        type=float,
        default=0.30,
        help="Minimum score required to keep a candidate (default: 0.30).",
    )
    parser.add_argument(
        "--min-onsets",
        type=int,
        default=12,
        help="Minimum onset count required inside a candidate window (default: 12).",
    )
    parser.add_argument(
        "--max-clips-per-file",
        type=int,
        default=5,
        help="Maximum number of candidates to export per source file (default: 5).",
    )
    parser.add_argument(
        "--analysis-sample-rate",
        type=int,
        default=22050,
        help="Sample rate (Hz) used for analysis (default: 22050).",
    )
    parser.add_argument(
        "--export-video",
        action="store_true",
        help="Also export matching MP4 clips for video-bearing source files.",
    )
    return parser.parse_args(argv)


def require_dependencies() -> tuple[Any, Any, Any]:
    missing: list[str] = []
    if shutil.which("ffmpeg") is None:
        missing.append("ffmpeg")
    if shutil.which("ffprobe") is None:
        missing.append("ffprobe")
    try:
        import numpy as np  # noqa: F401
    except ImportError:
        missing.append("python:numpy")
    try:
        import soundfile  # noqa: F401
    except ImportError:
        missing.append("python:soundfile")
    try:
        import librosa  # noqa: F401
    except ImportError:
        missing.append("python:librosa")
    if missing:
        sys.stderr.write("Missing dependencies: " + ", ".join(missing) + "\n")
        sys.stderr.write(MISSING_DEPS_HINT + "\n")
        raise SystemExit(2)
    import numpy as np
    import soundfile
    import librosa
    try:
        import librosa.feature.rhythm  # noqa: F401  (registers lazy-loaded submodule)
    except ImportError:
        pass
    return np, soundfile, librosa


def discover_media(input_root: Path) -> list[Path]:
    files: list[Path] = []
    for path in sorted(input_root.rglob("*")):
        if not path.is_file():
            continue
        if path.suffix.lower() in MEDIA_EXTENSIONS:
            files.append(path)
    return files


def probe_duration(path: Path) -> float | None:
    proc = subprocess.run(
        [
            "ffprobe",
            "-v",
            "error",
            "-show_entries",
            "format=duration",
            "-of",
            "default=noprint_wrappers=1:nokey=1",
            str(path),
        ],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        return None
    raw = proc.stdout.strip()
    if not raw:
        return None
    try:
        return float(raw)
    except ValueError:
        return None


def has_video_stream(path: Path) -> bool:
    if path.suffix.lower() not in VIDEO_EXTENSIONS:
        return False
    proc = subprocess.run(
        [
            "ffprobe",
            "-v",
            "error",
            "-select_streams",
            "v:0",
            "-show_entries",
            "stream=codec_type",
            "-of",
            "default=noprint_wrappers=1:nokey=1",
            str(path),
        ],
        capture_output=True,
        text=True,
    )
    return proc.returncode == 0 and proc.stdout.strip() == "video"


def extract_analysis_audio(source: Path, sample_rate: int, dest: Path) -> bool:
    proc = subprocess.run(
        [
            "ffmpeg",
            "-y",
            "-loglevel",
            "error",
            "-i",
            str(source),
            "-vn",
            "-ac",
            "1",
            "-ar",
            str(sample_rate),
            "-c:a",
            "pcm_s16le",
            "-map_metadata",
            "-1",
            "-map_chapters",
            "-1",
            str(dest),
        ],
        capture_output=True,
        text=True,
    )
    return proc.returncode == 0 and dest.exists() and dest.stat().st_size > 0


def estimate_bpm(librosa, np, audio, sample_rate: int) -> float | None:
    tempo_fn = getattr(getattr(librosa, "feature", None), "rhythm", None)
    tempo_fn = getattr(tempo_fn, "tempo", None) or librosa.beat.tempo
    try:
        tempo = tempo_fn(y=audio, sr=sample_rate, aggregate=np.median)
    except Exception:
        return None
    if tempo is None or len(tempo) == 0:
        return None
    bpm = float(tempo[0])
    if not (40.0 <= bpm <= 220.0):
        return None
    return bpm


def compute_min_window_seconds(
    bpm: float | None,
    min_bars: int,
    beats_per_bar: int,
    fallback_min_seconds: float,
    absolute_min_seconds: float,
) -> float:
    if bpm is None or bpm <= 0.0:
        return max(fallback_min_seconds, absolute_min_seconds)
    bar_seconds = (60.0 / bpm) * beats_per_bar
    return max(min_bars * bar_seconds, absolute_min_seconds)


@dataclass
class WindowScore:
    start: float
    end: float
    score: float
    onset_count: int
    onset_rate: float
    silence_ratio: float
    median_centroid: float
    repetition: float


def analyse_track(librosa, np, audio, sample_rate: int):
    hop_length = 512
    onset_env = librosa.onset.onset_strength(y=audio, sr=sample_rate, hop_length=hop_length)
    onset_frames = librosa.onset.onset_detect(
        onset_envelope=onset_env, sr=sample_rate, hop_length=hop_length, units="frames"
    )
    onset_times = librosa.frames_to_time(onset_frames, sr=sample_rate, hop_length=hop_length)
    rms = librosa.feature.rms(y=audio, frame_length=2048, hop_length=hop_length)[0]
    rms_times = librosa.frames_to_time(np.arange(len(rms)), sr=sample_rate, hop_length=hop_length)
    centroid = librosa.feature.spectral_centroid(y=audio, sr=sample_rate, hop_length=hop_length)[0]
    return {
        "onset_times": onset_times,
        "rms": rms,
        "rms_times": rms_times,
        "centroid": centroid,
    }


def score_window(
    np,
    features: dict[str, Any],
    silence_threshold: float,
    start: float,
    end: float,
) -> WindowScore:
    duration = end - start
    onset_times = features["onset_times"]
    rms = features["rms"]
    rms_times = features["rms_times"]
    centroid = features["centroid"]

    in_window = (onset_times >= start) & (onset_times < end)
    onsets_in = onset_times[in_window]
    onset_count = int(onsets_in.size)
    onset_rate = onset_count / max(1e-6, duration)

    rms_mask = (rms_times >= start) & (rms_times < end)
    rms_in = rms[rms_mask]
    if rms_in.size:
        silence_ratio = float((rms_in < silence_threshold).mean())
    else:
        silence_ratio = 1.0

    centroid_in = centroid[rms_mask]
    if centroid_in.size:
        median_centroid = float(np.median(centroid_in))
    else:
        median_centroid = 0.0

    if onsets_in.size >= 2:
        intervals = np.diff(onsets_in)
        mean_iv = float(intervals.mean())
        if mean_iv > 0:
            cv = float(intervals.std() / mean_iv)
        else:
            cv = 1.0
        repetition = 1.0 / (1.0 + cv)
    else:
        repetition = 0.0

    onset_component = min(1.0, onset_rate / 6.0)
    centroid_component = min(1.0, median_centroid / 3500.0)
    silence_component = max(0.0, 1.0 - silence_ratio)

    score = (
        (0.40 * onset_component)
        + (0.20 * centroid_component)
        + (0.25 * silence_component)
        + (0.15 * repetition)
    )
    return WindowScore(
        start=start,
        end=end,
        score=float(score),
        onset_count=onset_count,
        onset_rate=onset_rate,
        silence_ratio=silence_ratio,
        median_centroid=median_centroid,
        repetition=repetition,
    )


def select_candidates(
    np,
    features: dict[str, Any],
    track_duration: float,
    min_window_seconds: float,
    hop_seconds: float,
    score_threshold: float,
    min_onsets: int,
    max_clips: int,
) -> list[WindowScore]:
    if track_duration < min_window_seconds:
        return []

    rms = features["rms"]
    if rms.size == 0:
        return []
    silence_threshold = max(float(np.percentile(rms, 25)) * 0.5, 0.005)

    starts = np.arange(0.0, track_duration - min_window_seconds + 1e-6, hop_seconds)
    scored: list[WindowScore] = []
    for start in starts:
        end = float(start) + min_window_seconds
        ws = score_window(np, features, silence_threshold, float(start), end)
        if ws.onset_count < min_onsets:
            continue
        if ws.score < score_threshold:
            continue
        scored.append(ws)

    scored.sort(key=lambda w: w.score, reverse=True)
    chosen: list[WindowScore] = []
    for window in scored:
        overlaps = any(window.end > c.start and window.start < c.end for c in chosen)
        if overlaps:
            continue
        chosen.append(window)
        if len(chosen) >= max_clips:
            break

    chosen.sort(key=lambda w: w.start)
    return chosen


def export_wav_clip(source: Path, start: float, duration: float, dest: Path) -> bool:
    proc = subprocess.run(
        [
            "ffmpeg",
            "-y",
            "-loglevel",
            "error",
            "-ss",
            f"{start:.3f}",
            "-i",
            str(source),
            "-t",
            f"{duration:.3f}",
            "-vn",
            "-ac",
            "2",
            "-ar",
            "44100",
            "-c:a",
            "pcm_s16le",
            "-map_metadata",
            "-1",
            "-map_chapters",
            "-1",
            "-fflags",
            "+bitexact",
            "-flags:a",
            "+bitexact",
            str(dest),
        ],
        capture_output=True,
        text=True,
    )
    return proc.returncode == 0 and dest.exists() and dest.stat().st_size > 0


def export_video_clip(source: Path, start: float, duration: float, dest: Path) -> bool:
    proc = subprocess.run(
        [
            "ffmpeg",
            "-y",
            "-loglevel",
            "error",
            "-ss",
            f"{start:.3f}",
            "-i",
            str(source),
            "-t",
            f"{duration:.3f}",
            "-map",
            "0:v:0",
            "-map",
            "0:a:0?",
            "-c:v",
            "libx264",
            "-preset",
            "veryfast",
            "-crf",
            "22",
            "-c:a",
            "aac",
            "-b:a",
            "160k",
            "-map_metadata",
            "-1",
            "-map_chapters",
            "-1",
            "-movflags",
            "+faststart",
            str(dest),
        ],
        capture_output=True,
        text=True,
    )
    return proc.returncode == 0 and dest.exists() and dest.stat().st_size > 0


def find_forbidden_tokens(payload: Any) -> list[str]:
    text = json.dumps(payload, ensure_ascii=False)
    return [token for token in FORBIDDEN_TOKENS if token in text]


def safe_clip_id(stem: str, index: int) -> str:
    cleaned = "".join(ch if ch.isalnum() or ch in ("-", "_") else "_" for ch in stem)
    cleaned = cleaned.strip("_") or "clip"
    return f"{cleaned[:80]}__c{index:02d}"


def process_file(
    source: Path,
    output_root: Path,
    args: argparse.Namespace,
    np,
    soundfile,
    librosa,
    workspace: Path,
) -> list[Candidate]:
    duration = probe_duration(source)
    if duration is None or duration <= 0.0:
        print(f"  skip: ffprobe could not read duration -> {source.name}")
        return []

    analysis_path = workspace / (source.stem + "__analysis.wav")
    if not extract_analysis_audio(source, args.analysis_sample_rate, analysis_path):
        print(f"  skip: ffmpeg analysis extraction failed -> {source.name}")
        return []

    audio, sr = soundfile.read(str(analysis_path), dtype="float32", always_2d=False)
    if audio.ndim > 1:
        audio = audio.mean(axis=1)
    if sr != args.analysis_sample_rate:
        # soundfile already returned the file's sample rate, which we asked for
        pass
    track_duration = float(audio.shape[0]) / float(sr)

    bpm = estimate_bpm(librosa, np, audio, sr)
    min_window_seconds = compute_min_window_seconds(
        bpm,
        args.min_bars,
        args.beats_per_bar,
        args.fallback_min_seconds,
        args.absolute_min_seconds,
    )
    if track_duration < min_window_seconds:
        print(
            f"  skip: track shorter than minimum window "
            f"({track_duration:.1f}s < {min_window_seconds:.1f}s) -> {source.name}"
        )
        try:
            analysis_path.unlink()
        except OSError:
            pass
        return []

    features = analyse_track(librosa, np, audio, sr)
    chosen = select_candidates(
        np,
        features,
        track_duration,
        min_window_seconds,
        args.hop_seconds,
        args.score_threshold,
        args.min_onsets,
        args.max_clips_per_file,
    )
    try:
        analysis_path.unlink()
    except OSError:
        pass

    if not chosen:
        print(f"  no candidates met threshold -> {source.name}")
        return []

    wav_root = output_root / WAV_SUBDIR
    wav_root.mkdir(parents=True, exist_ok=True)
    video_root = output_root / VIDEO_SUBDIR if args.export_video else None
    if video_root is not None:
        video_root.mkdir(parents=True, exist_ok=True)

    has_video = args.export_video and has_video_stream(source)
    candidates: list[Candidate] = []
    for index, window in enumerate(chosen, start=1):
        clip_id = safe_clip_id(source.stem, index)
        clip_duration = window.end - window.start
        wav_path = wav_root / f"{clip_id}.wav"
        if not export_wav_clip(source, window.start, clip_duration, wav_path):
            print(f"  warn: WAV export failed for {clip_id}")
            continue
        exported_video_rel: str | None = None
        if has_video and video_root is not None:
            video_path = video_root / f"{clip_id}.mp4"
            if export_video_clip(source, window.start, clip_duration, video_path):
                exported_video_rel = f"{VIDEO_SUBDIR}/{video_path.name}"
            else:
                print(f"  warn: video export failed for {clip_id}")

        bars_estimate = (
            (clip_duration * bpm) / (60.0 * args.beats_per_bar) if bpm else 0.0
        )
        candidates.append(
            Candidate(
                clip_id=clip_id,
                source_file=source.name,
                source_stem=source.stem,
                start_time=round(window.start, 3),
                end_time=round(window.end, 3),
                duration=round(clip_duration, 3),
                bpm_estimate=round(bpm, 2) if bpm else None,
                bars_estimate=round(bars_estimate, 3),
                score=round(window.score, 4),
                onset_count=window.onset_count,
                onset_rate_per_second=round(window.onset_rate, 3),
                silence_ratio=round(window.silence_ratio, 4),
                median_centroid=round(window.median_centroid, 2),
                exported_wav=f"{WAV_SUBDIR}/{wav_path.name}",
                exported_video=exported_video_rel,
            )
        )
        print(
            f"  candidate {clip_id}: "
            f"start={window.start:.2f}s dur={clip_duration:.2f}s "
            f"score={window.score:.3f} onsets={window.onset_count}"
        )
    return candidates


def build_manifest(input_root: Path, candidates: list[Candidate]) -> dict[str, Any]:
    return {
        "schema_version": SCHEMA_VERSION,
        "purpose": PURPOSE,
        "input_folder_name": input_root.name,
        "candidate_count": len(candidates),
        "candidates": [asdict(c) for c in candidates],
    }


def write_manifest(output_root: Path, manifest: dict[str, Any]) -> Path:
    forbidden = find_forbidden_tokens(manifest)
    if forbidden:
        raise SystemExit(
            "Refusing to write manifest: forbidden tokens found -> " + ", ".join(forbidden)
        )
    output_root.mkdir(parents=True, exist_ok=True)
    target = output_root / MANIFEST_FILENAME
    tmp = target.with_suffix(target.suffix + ".tmp")
    tmp.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    tmp.replace(target)
    return target


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    input_root: Path = args.input.expanduser().resolve()
    output_root: Path = args.output.expanduser().resolve()
    if not input_root.is_dir():
        sys.stderr.write(f"Input folder does not exist or is not a directory: {input_root}\n")
        return 2

    np, soundfile, librosa = require_dependencies()

    media_files = discover_media(input_root)
    print(f"Scanning {len(media_files)} media file(s) under {input_root.name}/")
    if not media_files:
        manifest = build_manifest(input_root, [])
        path = write_manifest(output_root, manifest)
        print(f"Wrote empty manifest to {path}")
        return 0

    all_candidates: list[Candidate] = []
    with tempfile.TemporaryDirectory(prefix="ytbaby_") as ws:
        workspace = Path(ws)
        for index, source in enumerate(media_files, start=1):
            print(f"[{index}/{len(media_files)}] {source.name}")
            try:
                file_candidates = process_file(
                    source, output_root, args, np, soundfile, librosa, workspace
                )
            except Exception as exc:
                print(f"  error: {exc}")
                continue
            all_candidates.extend(file_candidates)

    manifest = build_manifest(input_root, all_candidates)
    path = write_manifest(output_root, manifest)
    print(f"Wrote manifest with {len(all_candidates)} candidate(s) to {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
