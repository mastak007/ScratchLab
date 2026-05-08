#!/usr/bin/env python3
"""Fixture tests for the training-manifest validator and evaluation harness.

These run the same way as scripts/test_dataset_processor.py — call:

    python3 scripts/test_training_manifest.py
"""
from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent
DATASET_DIR = REPO_ROOT / "scripts" / "dataset_processor"
VALIDATOR_SCRIPT = DATASET_DIR / "validate_training_manifest.py"
EVALUATOR_SCRIPT = DATASET_DIR / "evaluate_classifier.py"


def load_module(name: str, path: Path):
    if str(DATASET_DIR) not in sys.path:
        sys.path.insert(0, str(DATASET_DIR))
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Unable to load module from {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


VALIDATOR_MODULE = load_module("validate_training_manifest_test_module", VALIDATOR_SCRIPT)
EVALUATOR_MODULE = load_module("evaluate_classifier_test_module", EVALUATOR_SCRIPT)


def _make_clip(**overrides):
    base = {
        "clip_id": "clip_001",
        "scratch_type": "baby",
        "bpm": 90,
        "beat_mode": "withBeat",
        "performer": "in_house_demo",
        "capture_device": "studio_camera_audio",
        "has_video": True,
        "has_audio": True,
        "has_motion": False,
        "label_confidence": 0.95,
        "split": "train",
        "duration_seconds": 4.0,
        "notes": "",
    }
    base.update(overrides)
    return base


class TrainingManifestValidatorTests(unittest.TestCase):
    maxDiff = None

    def test_minimal_valid_manifest_passes(self):
        manifest = {
            "spec_version": "training_clip_manifest_v1",
            "clips": [
                _make_clip(),
                _make_clip(clip_id="clip_002", scratch_type="chirp", split="validation"),
                _make_clip(
                    clip_id="clip_003",
                    scratch_type="flare_1click",
                    split="test",
                    bpm=80,
                ),
            ],
        }
        errors = VALIDATOR_MODULE.validate_manifest(manifest)
        self.assertEqual(errors, [])

    def test_unknown_scratch_type_rejected(self):
        manifest = {"clips": [_make_clip(scratch_type="banana")]}
        errors = VALIDATOR_MODULE.validate_manifest(manifest)
        self.assertTrue(any("not in the canonical" in error for error in errors), errors)

    def test_invalid_split_rejected(self):
        manifest = {"clips": [_make_clip(split="holdout")]}
        errors = VALIDATOR_MODULE.validate_manifest(manifest)
        self.assertTrue(any("split must be one of" in error for error in errors), errors)

    def test_invalid_beat_mode_rejected(self):
        manifest = {"clips": [_make_clip(beat_mode="freestyle")]}
        errors = VALIDATOR_MODULE.validate_manifest(manifest)
        self.assertTrue(any("beat_mode must be one of" in error for error in errors), errors)

    def test_with_beat_requires_bpm(self):
        manifest = {"clips": [_make_clip(bpm=None)]}
        errors = VALIDATOR_MODULE.validate_manifest(manifest)
        self.assertTrue(any("bpm must be a positive integer" in error for error in errors), errors)

    def test_no_beat_allows_null_bpm(self):
        manifest = {"clips": [_make_clip(beat_mode="noBeat", bpm=None)]}
        errors = VALIDATOR_MODULE.validate_manifest(manifest)
        self.assertEqual(errors, [])

    def test_confidence_out_of_range_rejected(self):
        manifest = {"clips": [_make_clip(label_confidence=1.4)]}
        errors = VALIDATOR_MODULE.validate_manifest(manifest)
        self.assertTrue(any("label_confidence must be a number" in error for error in errors), errors)

    def test_duplicate_clip_ids_rejected(self):
        manifest = {"clips": [_make_clip(), _make_clip()]}
        errors = VALIDATOR_MODULE.validate_manifest(manifest)
        self.assertTrue(any("duplicate clip_id" in error for error in errors), errors)

    def test_clip_id_with_path_separator_rejected(self):
        manifest = {"clips": [_make_clip(clip_id="folder/clip_001")]}
        errors = VALIDATOR_MODULE.validate_manifest(manifest)
        self.assertTrue(any("stable identifier, not a path" in error for error in errors), errors)

    def test_banned_provenance_field_rejected(self):
        manifest = {
            "clips": [
                _make_clip(),
            ],
            "source_dvd": "Some Disc",
        }
        errors = VALIDATOR_MODULE.validate_manifest(manifest)
        self.assertTrue(
            any("banned provenance field" in error for error in errors), errors
        )

    def test_banned_token_in_string_value_rejected(self):
        manifest = {
            "clips": [
                _make_clip(notes="ripped via MakeMKV from /Users/me/foo.mkv"),
            ]
        }
        errors = VALIDATOR_MODULE.validate_manifest(manifest)
        joined_errors = "\n".join(errors)
        self.assertIn("MakeMKV", joined_errors)
        self.assertIn("/Users/", joined_errors)

    def test_min_per_class_enforced(self):
        manifest = {
            "clips": [
                _make_clip(scratch_type="baby", clip_id="b1"),
                _make_clip(scratch_type="baby", clip_id="b2"),
                _make_clip(scratch_type="chirp", clip_id="c1"),
            ]
        }
        errors = VALIDATOR_MODULE.validate_manifest(manifest, require_min_per_class=2)
        self.assertTrue(
            any("'chirp' has only 1 clip" in error for error in errors), errors
        )

    def test_cli_round_trip(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            manifest_path = Path(temp_dir) / "manifest.json"
            manifest_path.write_text(
                json.dumps(
                    {
                        "spec_version": "training_clip_manifest_v1",
                        "clips": [_make_clip()],
                    }
                ),
                encoding="utf-8",
            )
            result = subprocess.run(
                [sys.executable, str(VALIDATOR_SCRIPT), "--manifest", str(manifest_path)],
                capture_output=True,
                text=True,
                cwd=DATASET_DIR,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("Validation OK", result.stdout)

    def test_cli_rejects_banned_token(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            manifest_path = Path(temp_dir) / "manifest.json"
            manifest_path.write_text(
                json.dumps(
                    {
                        "spec_version": "training_clip_manifest_v1",
                        "clips": [
                            _make_clip(notes="exported via processed_makemkv"),
                        ],
                    }
                ),
                encoding="utf-8",
            )
            result = subprocess.run(
                [sys.executable, str(VALIDATOR_SCRIPT), "--manifest", str(manifest_path)],
                capture_output=True,
                text=True,
                cwd=DATASET_DIR,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("processed_makemkv", result.stderr)


class EvaluateClassifierTests(unittest.TestCase):
    maxDiff = None

    def _manifest(self, clips):
        return {"spec_version": "training_clip_manifest_v1", "clips": clips}

    def _predictions(self, items):
        return {"predictions": items}

    def test_perfect_predictions_yield_full_accuracy(self):
        manifest = self._manifest(
            [
                _make_clip(clip_id="b1", scratch_type="baby"),
                _make_clip(clip_id="c1", scratch_type="chirp", split="validation"),
                _make_clip(
                    clip_id="t1", scratch_type="transform", split="test", bpm=120
                ),
            ]
        )
        predictions = self._predictions(
            [
                {"clip_id": "b1", "predicted_scratch_type": "baby", "confidence": 0.99},
                {"clip_id": "c1", "predicted_scratch_type": "chirp", "confidence": 0.92},
                {
                    "clip_id": "t1",
                    "predicted_scratch_type": "transform",
                    "confidence": 0.88,
                },
            ]
        )
        report = EVALUATOR_MODULE.evaluate(manifest, predictions)
        self.assertEqual(report["summary"]["overall_accuracy"], 1.0)
        self.assertEqual(report["summary"]["misclassified_count"], 0)
        for label in ("baby", "chirp", "transform"):
            metrics = report["per_label_metrics"][label]
            self.assertEqual(metrics["precision"], 1.0)
            self.assertEqual(metrics["recall"], 1.0)
            self.assertEqual(metrics["f1"], 1.0)

    def test_misclassification_recorded(self):
        manifest = self._manifest(
            [
                _make_clip(clip_id="b1", scratch_type="baby"),
                _make_clip(clip_id="c1", scratch_type="chirp", split="validation"),
            ]
        )
        predictions = self._predictions(
            [
                {"clip_id": "b1", "predicted_scratch_type": "baby", "confidence": 0.9},
                {"clip_id": "c1", "predicted_scratch_type": "baby", "confidence": 0.4},
            ]
        )
        report = EVALUATOR_MODULE.evaluate(manifest, predictions)
        self.assertEqual(report["summary"]["evaluated_clip_count"], 2)
        self.assertEqual(report["summary"]["misclassified_count"], 1)
        misclassified = report["misclassified_examples"]
        self.assertEqual(len(misclassified), 1)
        self.assertEqual(misclassified[0]["clip_id"], "c1")
        self.assertEqual(misclassified[0]["predicted_scratch_type"], "baby")
        self.assertEqual(report["confusion_matrix"]["chirp"]["baby"], 1)

    def test_low_confidence_examples_listed(self):
        manifest = self._manifest(
            [
                _make_clip(clip_id="b1", scratch_type="baby"),
                _make_clip(clip_id="b2", scratch_type="baby"),
            ]
        )
        predictions = self._predictions(
            [
                {"clip_id": "b1", "predicted_scratch_type": "baby", "confidence": 0.9},
                {"clip_id": "b2", "predicted_scratch_type": "baby", "confidence": 0.3},
            ]
        )
        report = EVALUATOR_MODULE.evaluate(
            manifest, predictions, low_confidence_threshold=0.5
        )
        self.assertEqual(report["summary"]["low_confidence_count"], 1)
        self.assertEqual(report["low_confidence_examples"][0]["clip_id"], "b2")

    def test_missing_prediction_is_flagged_not_counted_as_correct(self):
        manifest = self._manifest(
            [
                _make_clip(clip_id="b1", scratch_type="baby"),
                _make_clip(clip_id="b2", scratch_type="baby"),
            ]
        )
        predictions = self._predictions(
            [
                {"clip_id": "b1", "predicted_scratch_type": "baby", "confidence": 0.9},
            ]
        )
        report = EVALUATOR_MODULE.evaluate(manifest, predictions)
        self.assertEqual(report["summary"]["evaluated_clip_count"], 1)
        self.assertEqual(report["summary"]["missing_prediction_count"], 1)
        self.assertEqual(report["missing_predictions"], ["b2"])

    def test_unknown_predicted_label_handled(self):
        manifest = self._manifest([_make_clip(clip_id="b1", scratch_type="baby")])
        predictions = self._predictions(
            [{"clip_id": "b1", "predicted_scratch_type": "banana", "confidence": 0.6}]
        )
        report = EVALUATOR_MODULE.evaluate(manifest, predictions)
        self.assertEqual(report["summary"]["unknown_prediction_count"], 1)
        self.assertEqual(report["per_label_metrics"]["baby"]["false_negative"], 1)

    def test_split_filter_restricts_clips(self):
        manifest = self._manifest(
            [
                _make_clip(clip_id="b1", scratch_type="baby", split="train"),
                _make_clip(clip_id="b2", scratch_type="baby", split="validation"),
            ]
        )
        predictions = self._predictions(
            [
                {"clip_id": "b1", "predicted_scratch_type": "baby", "confidence": 0.9},
                {"clip_id": "b2", "predicted_scratch_type": "chirp", "confidence": 0.4},
            ]
        )
        report_train = EVALUATOR_MODULE.evaluate(
            manifest, predictions, split_filter="train"
        )
        report_val = EVALUATOR_MODULE.evaluate(
            manifest, predictions, split_filter="validation"
        )
        self.assertEqual(report_train["summary"]["evaluated_clip_count"], 1)
        self.assertEqual(report_train["summary"]["misclassified_count"], 0)
        self.assertEqual(report_val["summary"]["evaluated_clip_count"], 1)
        self.assertEqual(report_val["summary"]["misclassified_count"], 1)

    def test_cli_writes_report(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            base = Path(temp_dir)
            manifest_path = base / "manifest.json"
            predictions_path = base / "predictions.json"
            report_path = base / "out" / "report.json"

            manifest_path.write_text(
                json.dumps(
                    self._manifest(
                        [
                            _make_clip(clip_id="b1", scratch_type="baby"),
                            _make_clip(clip_id="c1", scratch_type="chirp"),
                        ]
                    )
                ),
                encoding="utf-8",
            )
            predictions_path.write_text(
                json.dumps(
                    self._predictions(
                        [
                            {
                                "clip_id": "b1",
                                "predicted_scratch_type": "baby",
                                "confidence": 0.95,
                            },
                            {
                                "clip_id": "c1",
                                "predicted_scratch_type": "baby",
                                "confidence": 0.3,
                            },
                        ]
                    )
                ),
                encoding="utf-8",
            )

            result = subprocess.run(
                [
                    sys.executable,
                    str(EVALUATOR_SCRIPT),
                    "--manifest",
                    str(manifest_path),
                    "--predictions",
                    str(predictions_path),
                    "--output",
                    str(report_path),
                ],
                capture_output=True,
                text=True,
                cwd=DATASET_DIR,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(report_path.exists())
            written = json.loads(report_path.read_text(encoding="utf-8"))
            self.assertEqual(written["summary"]["evaluated_clip_count"], 2)
            self.assertEqual(written["summary"]["misclassified_count"], 1)


if __name__ == "__main__":
    unittest.main()
