#!/usr/bin/env python3
"""Offline evaluation harness for ScratchLab multi-scratch classifiers.

Reads a labelled training-clip manifest and a predictions file, then writes
a JSON report with:
- confusion matrix by scratch_type
- per-label precision / recall / f1
- list of low-confidence and misclassified clip ids

This is offline-only and does not run any model itself. It expects an
external classifier (or a cached prediction dump) to produce the predictions
JSON. Aggregate output is safe to commit; per-clip rows reference clip_ids,
not file paths or vendor metadata.
"""
from __future__ import annotations

import argparse
import json
import sys
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from process_dataset import normalize_scratch_type
from validate_training_manifest import validate_manifest


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Evaluate scratch-type predictions against a labelled training manifest "
            "and write a confusion matrix + per-label metrics report."
        )
    )
    parser.add_argument(
        "--manifest",
        required=True,
        help="Path to a labelled manifest matching templates/training_clip_manifest_template.json.",
    )
    parser.add_argument(
        "--predictions",
        required=True,
        help=(
            "Path to a JSON file with shape "
            '{"predictions": [{"clip_id": ..., "predicted_scratch_type": ..., '
            '"confidence": ...}, ...]}'
        ),
    )
    parser.add_argument(
        "--output",
        required=True,
        help="Path to write the evaluation report JSON.",
    )
    parser.add_argument(
        "--low-confidence-threshold",
        type=float,
        default=0.5,
        help="Predictions at or below this confidence are flagged as low-confidence.",
    )
    parser.add_argument(
        "--split",
        choices=("train", "validation", "test", "all"),
        default="all",
        help="Restrict the evaluation to a single split.",
    )
    return parser.parse_args()


def _iso_now() -> str:
    return (
        datetime.now(timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z")
    )


def _index_predictions(payload: Any) -> dict[str, dict[str, Any]]:
    if not isinstance(payload, dict):
        raise ValueError("predictions file must be a JSON object with a 'predictions' array")
    items = payload.get("predictions")
    if not isinstance(items, list):
        raise ValueError("predictions file is missing the 'predictions' array")

    indexed: dict[str, dict[str, Any]] = {}
    for index, item in enumerate(items):
        if not isinstance(item, dict):
            raise ValueError(f"predictions[{index}] must be an object")
        clip_id = item.get("clip_id")
        if not isinstance(clip_id, str) or not clip_id.strip():
            raise ValueError(f"predictions[{index}] has missing/empty clip_id")
        indexed[clip_id] = item
    return indexed


def evaluate(
    manifest_payload: dict[str, Any],
    predictions_payload: dict[str, Any],
    *,
    split_filter: str = "all",
    low_confidence_threshold: float = 0.5,
) -> dict[str, Any]:
    clips = manifest_payload.get("clips", [])
    predictions = _index_predictions(predictions_payload)

    confusion: dict[str, dict[str, int]] = defaultdict(lambda: defaultdict(int))
    per_label_totals: dict[str, dict[str, int]] = defaultdict(
        lambda: {"true_positive": 0, "false_positive": 0, "false_negative": 0}
    )

    misclassified: list[dict[str, Any]] = []
    low_confidence: list[dict[str, Any]] = []
    missing_predictions: list[str] = []
    unknown_predictions: list[dict[str, Any]] = []

    evaluated_count = 0

    for clip in clips:
        if not isinstance(clip, dict):
            continue
        if split_filter != "all" and clip.get("split") != split_filter:
            continue

        clip_id = clip.get("clip_id")
        if not isinstance(clip_id, str):
            continue
        gold = normalize_scratch_type(clip.get("scratch_type"))
        if gold is None:
            continue

        prediction = predictions.get(clip_id)
        if prediction is None:
            missing_predictions.append(clip_id)
            continue

        predicted = normalize_scratch_type(prediction.get("predicted_scratch_type"))
        confidence = prediction.get("confidence")
        if not isinstance(confidence, (int, float)):
            confidence = None

        evaluated_count += 1

        if predicted is None:
            unknown_predictions.append(
                {
                    "clip_id": clip_id,
                    "raw_predicted_scratch_type": prediction.get(
                        "predicted_scratch_type"
                    ),
                    "gold_scratch_type": gold,
                }
            )
            per_label_totals[gold]["false_negative"] += 1
            confusion[gold]["__unknown__"] += 1
            continue

        confusion[gold][predicted] += 1

        if predicted == gold:
            per_label_totals[gold]["true_positive"] += 1
        else:
            per_label_totals[gold]["false_negative"] += 1
            per_label_totals[predicted]["false_positive"] += 1
            misclassified.append(
                {
                    "clip_id": clip_id,
                    "gold_scratch_type": gold,
                    "predicted_scratch_type": predicted,
                    "confidence": confidence,
                }
            )

        if confidence is not None and float(confidence) <= low_confidence_threshold:
            low_confidence.append(
                {
                    "clip_id": clip_id,
                    "gold_scratch_type": gold,
                    "predicted_scratch_type": predicted,
                    "confidence": confidence,
                }
            )

    per_label_metrics: dict[str, dict[str, float]] = {}
    for label, totals in per_label_totals.items():
        true_positive = totals["true_positive"]
        false_positive = totals["false_positive"]
        false_negative = totals["false_negative"]
        precision_denominator = true_positive + false_positive
        recall_denominator = true_positive + false_negative
        precision = (
            true_positive / precision_denominator
            if precision_denominator > 0
            else 0.0
        )
        recall = (
            true_positive / recall_denominator if recall_denominator > 0 else 0.0
        )
        f1_denominator = precision + recall
        f1 = (
            2 * precision * recall / f1_denominator if f1_denominator > 0 else 0.0
        )
        per_label_metrics[label] = {
            "true_positive": true_positive,
            "false_positive": false_positive,
            "false_negative": false_negative,
            "precision": round(precision, 4),
            "recall": round(recall, 4),
            "f1": round(f1, 4),
        }

    correct = sum(metrics["true_positive"] for metrics in per_label_metrics.values())
    overall_accuracy = (
        correct / evaluated_count if evaluated_count > 0 else 0.0
    )

    confusion_serialised: dict[str, dict[str, int]] = {
        gold: dict(predictions_for_gold)
        for gold, predictions_for_gold in confusion.items()
    }

    return {
        "spec_version": "scratchlab_eval_report_v1",
        "generated_at": _iso_now(),
        "split_filter": split_filter,
        "low_confidence_threshold": low_confidence_threshold,
        "summary": {
            "evaluated_clip_count": evaluated_count,
            "missing_prediction_count": len(missing_predictions),
            "unknown_prediction_count": len(unknown_predictions),
            "misclassified_count": len(misclassified),
            "low_confidence_count": len(low_confidence),
            "overall_accuracy": round(overall_accuracy, 4),
        },
        "per_label_metrics": per_label_metrics,
        "confusion_matrix": confusion_serialised,
        "misclassified_examples": misclassified,
        "low_confidence_examples": low_confidence,
        "missing_predictions": missing_predictions,
        "unknown_predictions": unknown_predictions,
    }


def main() -> int:
    args = parse_args()

    manifest_path = Path(args.manifest).expanduser().resolve()
    predictions_path = Path(args.predictions).expanduser().resolve()
    output_path = Path(args.output).expanduser().resolve()

    if not manifest_path.is_file():
        print(f"Manifest does not exist: {manifest_path}", file=sys.stderr)
        return 1
    if not predictions_path.is_file():
        print(f"Predictions file does not exist: {predictions_path}", file=sys.stderr)
        return 1

    try:
        manifest_payload = json.loads(manifest_path.read_text(encoding="utf-8"))
        predictions_payload = json.loads(predictions_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        print(f"Failed to parse JSON: {error}", file=sys.stderr)
        return 1

    manifest_errors = validate_manifest(manifest_payload)
    if manifest_errors:
        for line in manifest_errors:
            print(line, file=sys.stderr)
        print(
            "Manifest failed validation; refusing to run evaluation.",
            file=sys.stderr,
        )
        return 1

    try:
        report = evaluate(
            manifest_payload,
            predictions_payload,
            split_filter=args.split,
            low_confidence_threshold=args.low_confidence_threshold,
        )
    except ValueError as error:
        print(f"Evaluation failed: {error}", file=sys.stderr)
        return 1

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    summary = report["summary"]
    print(
        "Evaluation complete: "
        f"evaluated={summary['evaluated_clip_count']} "
        f"correct_accuracy={summary['overall_accuracy']:.4f} "
        f"misclassified={summary['misclassified_count']} "
        f"low_confidence={summary['low_confidence_count']} "
        f"missing={summary['missing_prediction_count']}"
    )
    print(f"Report written to: {output_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
