#!/usr/bin/env python3
"""Strict, deterministic QA for the six unapproved CXL beat pilots."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import struct
import wave
from pathlib import Path

EXPECTED_IDS = {
    "boom_bap_straight_80": ("boom-bap", 80, "straight"),
    "boom_bap_swing_90": ("boom-bap", 90, "swing"),
    "funk_break_straight_90": ("funk-break", 90, "straight"),
    "funk_light_swing_100": ("funk", 100, "lightSwing"),
    "electro_straight_110": ("electro", 110, "straight"),
    "half_time_80": ("half-time", 80, "halfTime"),
}
EXPECTED_FILES = {
    "manifest.json", "rights_receipt.json", "production_master.wav",
    "sparse_analysis.wav", "beat_only.wav",
}
SHA_KEYS = ("productionMaster", "sparseAnalysisMix", "rightsReceipt")
PEAK_CEILING = 10 ** (-1.0 / 20.0) + (1.0 / 32768.0)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def probe_wav(path: Path) -> dict[str, float | int]:
    with wave.open(str(path), "rb") as wav:
        if wav.getcomptype() != "NONE" or wav.getsampwidth() != 2:
            raise ValueError(f"{path}: must be readable PCM16")
        channels = wav.getnchannels()
        rate = wav.getframerate()
        frames = wav.getnframes()
        values = struct.unpack(f"<{frames * channels}h", wav.readframes(frames))
    samples = [value / 32768.0 for value in values]
    mean = sum(samples) / max(1, len(samples))
    peak = max((abs(value) for value in samples), default=0.0)
    rms = math.sqrt(sum(value * value for value in samples) / max(1, len(samples)))
    ac_rms = math.sqrt(sum((value - mean) ** 2 for value in samples) / max(1, len(samples)))
    return {"channels": channels, "rate": rate, "frames": frames,
            "peak": peak, "rms": rms, "dc": mean, "ac_rms": ac_rms}


def validate(root: Path) -> list[str]:
    errors: list[str] = []
    actual_ids = {item.name for item in root.iterdir() if item.is_dir()} if root.is_dir() else set()
    if actual_ids != set(EXPECTED_IDS):
        errors.append(f"candidate set mismatch: expected={sorted(EXPECTED_IDS)} actual={sorted(actual_ids)}")
    for candidate_id, (family, bpm, feel) in EXPECTED_IDS.items():
        directory = root / candidate_id
        if not directory.is_dir():
            continue
        files = {item.name for item in directory.iterdir() if item.is_file()}
        if files != EXPECTED_FILES:
            errors.append(f"{candidate_id}: unlisted/missing files expected={sorted(EXPECTED_FILES)} actual={sorted(files)}")
            continue
        try:
            manifest = json.loads((directory / "manifest.json").read_text())
            receipt = json.loads((directory / "rights_receipt.json").read_text())
        except Exception as exc:
            errors.append(f"{candidate_id}: unreadable JSON: {exc}")
            continue

        recipe = manifest.get("recipe", {})
        expected_fields = {
            "schemaVersion": "scratchlab_cxl_beat_pilot_manifest_v1",
            "approvalState": "unapproved_pilot_candidate",
        }
        for key, expected in expected_fields.items():
            if manifest.get(key) != expected:
                errors.append(f"{candidate_id}: {key} mismatch")
        if (recipe.get("id"), recipe.get("family"), recipe.get("bpm"), recipe.get("feel")) != (candidate_id, family, bpm, feel):
            errors.append(f"{candidate_id}: recipe identity mismatch")
        if receipt != {
            "candidateID": candidate_id,
            "externalRecordingUsed": False,
            "rightsState": "procedurallyGeneratedOriginal",
            "schemaVersion": "scratchlab_cxl_beat_rights_v1",
            "source": "ScratchLabBeatEngine deterministic procedural synthesis",
        }:
            errors.append(f"{candidate_id}: rights receipt mismatch")

        artifacts = [manifest.get(key, {}) for key in SHA_KEYS] + manifest.get("stems", [])
        for artifact in artifacts:
            file_name = artifact.get("fileName", "")
            if not file_name or Path(file_name).name != file_name:
                errors.append(f"{candidate_id}: unsafe/empty artifact filename {file_name!r}")
                continue
            path = directory / file_name
            if not path.is_file() or sha256(path) != artifact.get("sha256"):
                errors.append(f"{candidate_id}: hash mismatch for {file_name}")

        probes: dict[str, dict[str, float | int]] = {}
        for file_name in ("production_master.wav", "sparse_analysis.wav", "beat_only.wav"):
            try:
                probe = probe_wav(directory / file_name)
                probes[file_name] = probe
                if probe["rate"] != 48_000 or probe["channels"] != 2:
                    errors.append(f"{candidate_id}: {file_name} must be 48 kHz stereo PCM")
                if probe["peak"] > PEAK_CEILING:
                    errors.append(f"{candidate_id}: {file_name} exceeds -1 dBFS generated ceiling")
                if probe["ac_rms"] < 1e-5 or abs(probe["dc"]) > 0.02:
                    errors.append(f"{candidate_id}: {file_name} is silent or DC-faulted")
            except Exception as exc:
                errors.append(str(exc))
        if len(probes) == 3:
            frame_counts = {probe["frames"] for probe in probes.values()}
            if frame_counts != {manifest.get("totalFrameCount")}:
                errors.append(f"{candidate_id}: master/analysis/stem frame mismatch")
        count_in = manifest.get("countInFrameCount")
        loop_start = manifest.get("loopStartFrame")
        loop_frames = manifest.get("loopFrameCount")
        total = manifest.get("totalFrameCount")
        if not all(isinstance(value, int) for value in (count_in, loop_start, loop_frames, total)):
            errors.append(f"{candidate_id}: frame boundaries missing")
        elif loop_start != count_in or loop_frames <= 0 or total != count_in + loop_frames:
            errors.append(f"{candidate_id}: invalid count-in/loop frame boundaries")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path)
    args = parser.parse_args()
    errors = validate(args.root)
    if errors:
        for error in errors:
            print(f"FAIL: {error}")
        print(f"CXL_BEAT_QA FAIL candidates={len(EXPECTED_IDS)} errors={len(errors)}")
        return 1
    print(f"CXL_BEAT_QA PASS candidates={len(EXPECTED_IDS)} files={len(EXPECTED_IDS) * len(EXPECTED_FILES)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
