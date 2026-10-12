"""POC schema adapter owned by ingest_media_scratch's offline CLI.

No detector, media access, gate computation, clock inference or approval. The
original reports remain authoritative; this is their bounded inspection view.
"""
from __future__ import annotations

import argparse
import csv
import json
import math
import os
from pathlib import Path, PurePosixPath
import sys
import tempfile


REFERENCE = "reference.json"
TRAJECTORY = "trajectory.csv"
FUSION = "audio_evidence_poc_v2/audio_fusion.csv"
AUDIO = "audio_evidence_poc_v2/audio_turnaround_evidence.json"
LAG = "av_lag_poc/av_lag_report.json"
SCHEMA = "scratchlab_derived_reference_inspection_v1"
SEMANTICS = "beat_removed_program_audio_may_include_speech"


class EvidenceError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise EvidenceError(message)


def text(value, field):
    require(isinstance(value, str) and bool(value.strip()), f"{field}: nonempty string required")
    return value  # Preserve producer vocabulary, including case and whitespace.


def number(value, field, minimum=None, maximum=None):
    require(type(value) in (int, float), f"{field}: number required")
    require(math.isfinite(value), f"{field}: finite number required")
    require(minimum is None or value >= minimum, f"{field}: below minimum {minimum}")
    require(maximum is None or value <= maximum, f"{field}: above maximum {maximum}")
    return value


def integer(value, field, minimum=0):
    require(type(value) is int and minimum <= value <= 2**63 - 1,
            f"{field}: integer in {minimum}...Int64.max required")
    return value


def literal(value, expected, field):
    require(type(value) is type(expected) and value == expected, f"{field}: expected {expected!r}")
    return value


def choice(value, choices, field):
    require(isinstance(value, str) and value in choices, f"{field}: expected one of {choices}")
    return value


def objects(value, field):
    require(isinstance(value, list) and all(isinstance(v, dict) for v in value),
            f"{field}: array of objects required")
    return value


def mapping(value, field):
    require(isinstance(value, dict), f"{field}: object required")
    return value


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, f"duplicate JSON key: {key}")
        result[key] = value
    return result


def read_json(root, name):
    def invalid_constant(value):
        raise EvidenceError(f"{name}: nonfinite JSON number {value}")
    with (root / name).open(encoding="utf-8") as stream:
        result = json.load(stream, object_pairs_hook=unique_object, parse_constant=invalid_constant)
    require(isinstance(result, dict), f"{name}: object required")
    return result


def read_csv(root, name, required):
    with (root / name).open(encoding="utf-8", newline="") as stream:
        reader = csv.DictReader(stream, strict=True)
        headers = reader.fieldnames or []
        require(len(headers) == len(set(headers)), f"{name}: duplicate column")
        require(set(required) <= set(headers), f"{name}: missing columns {sorted(set(required) - set(headers))}")
        rows = list(reader)
    require(bool(rows), f"{name}: no evidence rows")
    require(all(None not in row and None not in row.values() for row in rows), f"{name}: malformed row width")
    return rows


def csv_number(row, key, optional=False, minimum=None, maximum=None):
    value = row[key]
    if optional and value == "":
        return None
    try:
        return number(float(value), key, minimum, maximum)
    except ValueError as error:
        raise EvidenceError(f"{key}: invalid CSV number {value!r}") from error


def csv_integer(row, key):
    value = row[key]
    require(value.isascii() and value.isdigit(), f"{key}: nonnegative CSV integer required")
    return integer(int(value), key)


def csv_bool(row, key):
    return choice(row[key], ("True", "False"), key) == "True"


def increasing(frames, field):
    require(all(a < b for a, b in zip(frames, frames[1:])), f"{field}: frames must be unique and increasing")


def same(actual, expected, field, tolerance=0):
    matches = actual == expected
    if tolerance and actual is not None and expected is not None:
        matches = abs(actual - expected) <= tolerance
    require(matches, f"{field}: conflicts with authoritative vision/source evidence")


def produce(root: Path, performance_id: str | None = None, video_only: bool = False) -> dict:
    """Read fixed existing evidence files, returning an unapproved document.

    A supplied performance identity is an operator assertion, not authentication.
    Embedded identities take precedence and conflicts are rejected.
    """
    try:
        return _produce(root, performance_id, video_only)
    except (KeyError, TypeError) as error:
        raise EvidenceError(f"missing/malformed mandatory evidence field: {error}") from error


def _produce(root, performance_id, video_only):
    reference = read_json(root, REFERENCE)
    literal(reference["schemaVersion"], 1, "reference.schemaVersion")
    literal(reference["platterSource"], "videoDerived", "reference.platterSource")
    for flag in ("hardwareGroundTruth", "canonicalReference"):
        literal(reference[flag], False, f"reference.{flag}")
    origin = mapping(reference["source"], "reference.source")
    meta = mapping(origin["datasetMetadata"], "source.datasetMetadata")  # Existing sidecar.
    manifest = mapping(origin.get("manifest", {}), "source.manifest")
    identities = [obj["performanceID"] for obj in (origin, meta, manifest)
                  if "performanceID" in obj]
    if performance_id is not None:
        identities.append(performance_id)
    require(bool(identities), "performanceID missing: supply --performance-id for this source performance")
    for identity in identities:
        text(identity, "performanceID")
        same(identity, identities[0], "performanceID")
    source = {key: text(meta[key], f"source.{key}") for key in
              ("sourceCollection", "sourceMKV", "sourceFolder", "datasetItemID", "labelSource", "scratchType")}
    source.update(performanceID=identities[0], cameraAngle=text(origin["angle"], "source.angle"),
                  videoFile=text(origin["video"], "source.video"), archive=text(origin["input"], "source.input"),
                  ingestSourceType=text(meta["sourceType"], "source.sourceType"))
    for key in ("performer", "bpmSource", "trainingUse"):
        if meta.get(key) is not None:
            source[key] = text(meta[key], f"source.{key}")
    if meta.get("bpm") is not None:
        source["bpm"] = number(meta["bpm"], "source.bpm", 0)
        require(source["bpm"] > 0 and "bpmSource" in source, "positive BPM requires bpmSource")
    for key, expected in (("cameraAngle", source["cameraAngle"]), ("linkedVideoFile", source["videoFile"])):
        same(meta[key], expected, f"datasetMetadata.{key}")
    video = mapping(reference["video"], "reference.video")
    fps = number(video["analysisFPS"], "video.analysisFPS", 0)
    start = number(video["analysisStartSeconds"], "video.analysisStartSeconds", 0)
    duration = number(video["analysisDurationSeconds"], "video.analysisDurationSeconds", 0)
    require(fps > 0 and duration > 0 and math.isfinite(start + duration), "invalid canonical timebase")
    require(math.isfinite(1000 / fps) and 1 / fps > 0, "invalid canonical frame duration")
    forward_sign = number(mapping(reference["tracking"], "reference.tracking")["forwardSign"], "tracking.forwardSign")
    require(forward_sign in (-1, 1), "tracking.forwardSign must be -1 or 1")

    def frame_time(frame, timestamp):
        require(frame / fps < duration and abs(timestamp - (start + frame / fps)) <= 0.00000051,
                f"frame {frame}: timestamp outside reference.json timebase")

    samples = []
    for row in read_csv(root, TRAJECTORY, ("frame", "timestamp_s", "smoothed_angle_deg",
            "signed_velocity_deg_s_forward_positive", "direction", "visual_confidence", "interpolated")):
        sample = dict(frame=csv_integer(row, "frame"), timestampSeconds=csv_number(row, "timestamp_s"),
                      angleDegrees=csv_number(row, "smoothed_angle_deg", optional=True),
                      angularVelocityDegreesPerSecond=csv_number(row, "signed_velocity_deg_s_forward_positive", optional=True),
                      direction=choice(row["direction"], ("FORWARD", "REVERSE", "STILL", "UNKNOWN"), "direction"),
                      visualConfidence=csv_number(row, "visual_confidence", minimum=0, maximum=1),
                      interpolated=csv_bool(row, "interpolated"))
        frame_time(sample["frame"], sample["timestampSeconds"])
        require(sample["direction"] == "UNKNOWN" or (sample["angleDegrees"] is not None
                and sample["angularVelocityDegreesPerSecond"] is not None), "known direction requires angle/velocity")
        samples.append(sample)
    increasing([s["frame"] for s in samples], "trajectory")
    by_frame = {s["frame"]: s for s in samples}
    turns = []
    for event in objects(reference["turnarounds"], "reference.turnarounds"):
        frame = integer(event["frame"], "turnaround.frame")
        timestamp = number(event["timeSeconds"], "turnaround.timeSeconds")
        frame_time(frame, timestamp)
        require(frame in by_frame, f"turnaround {frame}: missing vision sample")
        turns.append(dict(frame=frame, timestampSeconds=timestamp,
                          directionChange=choice(event["kind"], ("FORWARD_TO_REVERSE", "REVERSE_TO_FORWARD"), "turnaround.kind"),
                          visualConfidence=by_frame[frame]["visualConfidence"], audioAvailability="unavailable"))
    increasing([t["frame"] for t in turns], "turnarounds")
    document = dict(schemaVersion=SCHEMA, sourceType="videoDerived", hardwareGroundTruth=False,
                    canonicalReference=False, source=source, samples=samples, turnarounds=turns, avLag=[],
                    timebase=dict(analysisFramesPerSecond=fps, sourceStartSeconds=start,
                                  analysisDurationSeconds=duration, referenceMetadataFile=REFERENCE),
                    trajectoryProvenance=dict(sourceType="videoDerived", trajectoryFile=TRAJECTORY,
                        referenceMetadataFile=REFERENCE, method="scratchlab_platter_poc.py; tracking in reference.json",
                        angleConvention="smoothed_angle_deg; counterclockwise positive",
                        velocityConvention=f"signed_velocity_deg_s_forward_positive; tracking.forwardSign={forward_sign:g}"),
                    review=dict(state="needsReview", notes="Offline projection of existing POC evidence; no approval granted.",
                                evidenceFiles=[]))
    if not video_only:
        for key in ("audioStreamRole", "beatMode"):
            literal(meta[key], "noBeat", f"source.datasetMetadata.{key}")
        add_audio(document, root, by_frame)
    return document


def add_audio(document, root, by_frame):
    evidence = read_json(root, AUDIO)
    literal(evidence["schemaVersion"], 2, "audio.schemaVersion")
    for flag in ("hardwareGroundTruth", "canonicalReference", "modifiesVisionTrajectory"):
        literal(evidence[flag], False, f"audio.{flag}")
    source, time = document["source"], document["timebase"]
    audio_source = mapping(evidence["source"], "audio.source")
    analysis = mapping(evidence["analysis"], "audio.analysis")
    for key, expected in (("reference", REFERENCE), ("trajectory", TRAJECTORY), ("zip", source["archive"]),
                          ("angle", source["cameraAngle"]), ("audioRole", "noBeat"), ("audioSemantics", SEMANTICS)):
        same(audio_source[key], expected, f"audio.source.{key}")
    for key, expected in (("startSeconds", time["sourceStartSeconds"]), ("durationSeconds", time["analysisDurationSeconds"]),
                          ("analysisFPS", time["analysisFramesPerSecond"]),
                          ("frameDurationMilliseconds", 1000 / time["analysisFramesPerSecond"])):
        same(number(analysis[key], f"audio.analysis.{key}"), expected, f"audio.analysis.{key}", 1e-9)
    gate = mapping(analysis["activityGate"], "audio.analysis.activityGate")
    frames = []
    for row in read_csv(root, FUSION, ("frame", "timestamp_s", "vision_velocity_deg_s", "vision_direction",
            "visual_confidence", "vision_interpolated", "audio_evidence_available", "audio_evidence_availability",
            "audio_rms", "audio_spectral_flux", "audio_motion_norm")):
        frame = csv_integer(row, "frame")
        require(frame in by_frame, f"audio frame {frame}: missing vision sample")
        vision = by_frame[frame]
        for key, expected in (("timestamp_s", vision["timestampSeconds"]),
                              ("vision_velocity_deg_s", vision["angularVelocityDegreesPerSecond"]),
                              ("visual_confidence", vision["visualConfidence"])):
            same(csv_number(row, key, optional=key == "vision_velocity_deg_s"), expected, f"audio.{key}", 1e-9)
        same(row["vision_direction"], vision["direction"], "audio.vision_direction")
        same(csv_bool(row, "vision_interpolated"), vision["interpolated"], "audio.vision_interpolated")
        active = csv_bool(row, "audio_evidence_available")  # Recorded padded gate, NOT vision_activity_raw.
        availability = choice(row["audio_evidence_availability"], ("available", "inactive_platter", "unavailable"), "audio availability")
        same(active, availability == "available", "audio availability/gate")
        rms = csv_number(row, "audio_rms", optional=True, minimum=0)
        flux = csv_number(row, "audio_spectral_flux", optional=True, minimum=0)
        motion = csv_number(row, "audio_motion_norm", optional=True, minimum=0, maximum=1)
        require(active or motion is None, f"audio frame {frame}: inactive/unavailable audio has motion evidence")
        require(not active or rms is not None, f"audio frame {frame}: available audio requires RMS")
        frames.append(dict(frame=frame, visionActive=active, availability=availability, rms=rms,
                           spectralFlux=flux, motionNorm=motion))
    same([f["frame"] for f in frames], list(by_frame), "audio frame sequence")
    audio_by_frame = {f["frame"]: f for f in frames}
    events = objects(evidence["events"], "audio.events")
    same([integer(e["visionFrame"], "audio.visionFrame") for e in events],
         [t["frame"] for t in document["turnarounds"]], "audio turnaround sequence")
    for event, turn in zip(events, document["turnarounds"]):
        for key, expected in (("visionTimeSeconds", turn["timestampSeconds"]), ("kind", turn["directionChange"]),
                              ("visualConfidence", turn["visualConfidence"]),
                              ("visionVelocityDegPerSecond", by_frame[turn["frame"]]["angularVelocityDegreesPerSecond"])):
            same(event[key], expected, f"audio.event.{key}")
        availability = event["audioEvidenceAvailability"]
        same(availability, audio_by_frame[turn["frame"]]["availability"], "audio.event.availability")
        turn["audioAvailability"] = availability
        support_keys = {"measuredLagFields": "audioTroughDeltaFields", "measuredLagMilliseconds": "audioTroughDeltaMilliseconds",
                        "troughRMS": "audioTroughRMS", "localBaselineRMS": "audioLocalBaselineRMS", "troughRatio": "audioTroughRatio"}
        if availability == "available":
            support = {key: number(event[value], f"audio.event.{value}", None if key.startswith("measured") else 0)
                       for key, value in support_keys.items()}
            same(support["measuredLagMilliseconds"], support["measuredLagFields"] * 1000 / time["analysisFramesPerSecond"],
                 "audio.event.lag", 1e-6)
            turn["audioSupport"] = support
        else:
            require(all(event.get(key) is None for key in support_keys.values()), "unavailable turnaround has audio support")
    document["sourceType"] = "videoAudioDerived"
    document["audio"] = dict(sourceFile=text(audio_source["audioMember"], "audio.source.audioMember"),
        evidenceFile=AUDIO, role="noBeat", semantics=SEMANTICS, modifiesVisionTrajectory=False,
        activityGateBasis=text(gate["basis"], "audio.activityGate.basis"),
        activityPadFields=integer(gate["padFields"], "audio.activityGate.padFields"), frames=frames)
    lag = read_json(root, LAG)
    literal(lag["schemaVersion"], 1, "avLag.schemaVersion")
    literal(lag["modifiesVisionTrajectory"], False, "avLag.modifiesVisionTrajectory")
    # Compare recorded provenance strings only; do not resolve historical media paths.
    expected_csv = str(PurePosixPath(text(audio_source["pocFolder"], "audio.source.pocFolder")) / FUSION)
    same(lag["sourceCSV"], expected_csv, "avLag.sourceCSV")
    reported_fps = number(lag["analysisFPS"], "avLag.analysisFPS", 0)
    require(reported_fps > 0, "avLag.analysisFPS must be positive")
    features = lag["features"]
    require(isinstance(features, dict) and bool(features), "avLag.features required")
    for feature, subsets in sorted(features.items()):
        text(feature, "avLag.feature")
        require(isinstance(subsets, dict) and bool(subsets), "avLag.subsets required")
        for subset, measurements in sorted(subsets.items()):
            text(subset, "avLag.subset")
            best = mapping(mapping(measurements, "avLag.measurements")["bestPearson"], "avLag.bestPearson")
            # Other peaks/curves stay in the referenced report.
            fields = number(best["lagFields"], "avLag.lagFields")
            require(math.isfinite(fields * 1000 / time["analysisFramesPerSecond"]), "invalid AV lag duration")
            document["avLag"].append(dict(evidenceFile=LAG, feature=feature, subset=subset, lagFields=fields,
                pairs=integer(best["pairs"], "avLag.pairs", 1), pearson=number(best["pearson"], "avLag.pearson", -1, 1),
                spearman=number(best["spearman"], "avLag.spearman", -1, 1), reportedAnalysisFPS=reported_fps,
                modifiesVisionTrajectory=False))


def write_document(document, output: Path, evidence_root: Path):
    """Atomically publish a new file only, outside the read-only evidence tree."""
    destination = output.resolve()
    require(not destination.is_relative_to(evidence_root.resolve()), "output must be outside the source evidence tree")
    payload = json.dumps(document, indent=2, sort_keys=True, allow_nan=False) + "\n"
    # No --force: hard-link installation fails if ANY destination entry exists.
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=output.parent,
                                     prefix=".derived-inspection-", delete=False) as stream:
        temporary = Path(stream.name)
        try:
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
            os.link(temporary, output)
        finally:
            temporary.unlink()


def main(argv=None):
    parser = argparse.ArgumentParser(description="Serialize existing POC evidence; no extraction, detection or approval.")
    parser.add_argument("--evidence-root", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path, help="New JSON file outside evidence tree; parent must exist")
    parser.add_argument("--performance-id", help="Required when source metadata lacks the shared performanceID")
    parser.add_argument("--video-only", action="store_true", help="Explicitly omit audio/AV evidence; never an automatic fallback")
    args = parser.parse_args(argv)
    try:
        document = produce(args.evidence_root, args.performance_id, args.video_only)
        write_document(document, args.output, args.evidence_root)
    except (OSError, ValueError, csv.Error, OverflowError) as error:
        print(f"derived-inspection: {error}", file=sys.stderr)
        return 1
    return 0
