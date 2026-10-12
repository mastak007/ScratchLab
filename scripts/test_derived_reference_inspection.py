"""Small source-schema fixtures; no media, detector or historical evidence writes."""
import csv
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
TOOL = ROOT / "scripts/dataset_processor/ingest_media_scratch.py"
SPEC = importlib.util.spec_from_file_location("derived_inspection", TOOL.with_name("derived_reference_inspection.py"))
PRODUCER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PRODUCER)
FIXTURES = ROOT / "ScratchLabDesktopTests/Fixtures/DerivedInspection/Producer"
IDENTITY = "qbert_makemkv_dvd/Baby_79bpm"


class DerivedInspectionProducerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.evidence = self.root / "evidence"
        shutil.copytree(FIXTURES / "baby79_holdout_24_30", self.evidence)

    def produce(self, **kwargs):
        return PRODUCER.produce(self.evidence, IDENTITY, **kwargs)

    def edit_json(self, path, edit):
        target = self.evidence / path
        data = json.loads(target.read_text())
        edit(data)
        target.write_text(json.dumps(data))

    def edit_csv(self, path, edit):
        target = self.evidence / path
        with target.open(newline="") as stream:
            reader = csv.DictReader(stream)
            rows, fields = list(reader), reader.fieldnames
        edit(rows)
        with target.open("w", newline="") as stream:
            writer = csv.DictWriter(stream, fieldnames=fields)
            writer.writeheader()
            writer.writerows(rows)

    def cli(self, output, *extra):
        return subprocess.run([sys.executable, str(TOOL), "derived-inspection", "--evidence-root",
            str(self.evidence), "--performance-id", IDENTITY, "--output", str(output), *extra],
            capture_output=True, text=True)

    def test_deterministic_cli_and_no_input_writes(self):
        before = {p.relative_to(self.evidence): p.read_bytes() for p in self.evidence.rglob("*") if p.is_file()}
        first, second = self.root / "first.json", self.root / "second.json"
        for output in (first, second):
            result = self.cli(output)
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(first.read_bytes(), second.read_bytes())
        self.assertEqual(before, {p.relative_to(self.evidence): p.read_bytes() for p in self.evidence.rglob("*") if p.is_file()})
        self.assertTrue(first.read_bytes().endswith(b"\n"))

    def test_metadata_clock_and_historical_provenance(self):
        doc = self.produce()
        self.assertEqual(doc["schemaVersion"], PRODUCER.SCHEMA)
        self.assertEqual(doc["timebase"]["analysisFramesPerSecond"], 59.94005994005994)
        self.assertEqual(1000 / doc["timebase"]["analysisFramesPerSecond"], 16.683333333333334)
        self.assertEqual(doc["sourceType"], "videoAudioDerived")
        self.assertEqual(doc["trajectoryProvenance"]["sourceType"], "videoDerived")
        self.assertEqual(doc["source"]["trainingUse"], "primary_training")
        self.assertEqual(doc["source"]["ingestSourceType"], "makemkv_dvd_rip")
        self.assertFalse(doc["hardwareGroundTruth"])
        self.assertFalse(doc["canonicalReference"])
        self.assertEqual(doc["review"]["state"], "needsReview")

    def test_generated_bytes_match_goldens_decoded_by_swift_io(self):
        for name, video_only in (("baby79_test", False), ("baby79_holdout_24_30", False), ("baby79_test", True)):
            with self.subTest(name=name, video_only=video_only):
                document = PRODUCER.produce(FIXTURES / name, IDENTITY, video_only)
                filename = name + ("_video" if video_only else "") + ".json"
                output = self.root / filename
                PRODUCER.write_document(document, output, FIXTURES / name)
                self.assertEqual(output.read_bytes(), (FIXTURES / "Expected" / filename).read_bytes())

    def test_both_windows_share_performance_not_interval_identity(self):
        dev = PRODUCER.produce(FIXTURES / "baby79_test", IDENTITY)
        holdout = self.produce()
        self.assertEqual(dev["source"], holdout["source"])
        self.assertNotEqual(dev["timebase"]["sourceStartSeconds"], holdout["timebase"]["sourceStartSeconds"])

    def test_identity_required_preserved_and_conflicts_rejected(self):
        with self.assertRaisesRegex(PRODUCER.EvidenceError, "performanceID missing"):
            PRODUCER.produce(self.evidence)
        self.edit_json(PRODUCER.REFERENCE, lambda d: d["source"].update(performanceID="original/performance"))
        self.assertEqual(PRODUCER.produce(self.evidence)["source"]["performanceID"], "original/performance")
        with self.assertRaisesRegex(PRODUCER.EvidenceError, "performanceID.*conflicts"):
            self.produce()

    def test_inactive_speech_is_not_motion_evidence(self):
        doc = self.produce()
        audio = doc["audio"]
        self.assertEqual(audio["semantics"], PRODUCER.SEMANTICS)
        frame = audio["frames"][-1]
        self.assertEqual(frame["availability"], "inactive_platter")
        self.assertFalse(frame["visionActive"])
        self.assertGreater(frame["rms"], 0.2)
        self.assertIsNone(frame["motionNorm"])
        self.edit_csv(PRODUCER.FUSION, lambda rows: rows[-1].update(audio_motion_norm="0.9"))
        with self.assertRaisesRegex(PRODUCER.EvidenceError, "inactive/unavailable"):
            self.produce()

    def test_unknown_missing_and_interpolated_estimates_survive(self):
        samples = {s["frame"]: s for s in self.produce()["samples"]}
        self.assertEqual(samples[62]["direction"], "UNKNOWN")
        self.assertIsNone(samples[62]["angleDegrees"])
        self.assertIsNone(samples[62]["angularVelocityDegreesPerSecond"])
        self.assertTrue(samples[238]["interpolated"])
        self.assertEqual(samples[238]["direction"], "UNKNOWN")
        self.assertEqual(samples[238]["angularVelocityDegreesPerSecond"], 1394.138571)

    def test_lag_is_per_source_not_applied_to_vision(self):
        original = self.produce()
        self.assertEqual({v["lagFields"] for v in original["avLag"]}, {1, 2})
        self.assertEqual(original["avLag"][0]["reportedAnalysisFPS"], 59.94125756758216)
        self.edit_json(PRODUCER.LAG, lambda d: d["features"]["audioMotionNorm"]["visionGated"]["bestPearson"].update(lagFields=-4, pearson=-0.42))
        changed = self.produce()
        self.assertEqual(changed["avLag"][0]["lagFields"], -4)
        self.assertEqual(changed["avLag"][0]["pearson"], -0.42)
        self.assertEqual(changed["samples"], original["samples"])
        self.assertEqual(changed["turnarounds"], original["turnarounds"])

    def test_video_only_is_explicit_and_preserves_vision(self):
        audio = self.produce()
        video = self.produce(video_only=True)
        self.assertEqual(video["sourceType"], "videoDerived")
        self.assertNotIn("audio", video)
        self.assertEqual(video["avLag"], [])
        self.assertEqual(video["samples"], audio["samples"])
        self.assertEqual(video["turnarounds"][0]["timestampSeconds"], audio["turnarounds"][0]["timestampSeconds"])
        (self.evidence / PRODUCER.AUDIO).unlink()
        with self.assertRaises(FileNotFoundError):
            self.produce()  # No silent downgrade.
        self.assertEqual(self.produce(video_only=True), video)

    def test_missing_each_mandatory_file_fails_without_output(self):
        for name in (PRODUCER.REFERENCE, PRODUCER.TRAJECTORY, PRODUCER.FUSION, PRODUCER.AUDIO, PRODUCER.LAG):
            with self.subTest(name=name):
                path = self.evidence / name
                content = path.read_bytes()
                path.unlink()
                result = self.cli(self.root / "missing.json")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(name, result.stderr)
                self.assertFalse((self.root / "missing.json").exists())
                path.write_bytes(content)

    def test_malformed_mandatory_metadata_fails(self):
        cases = [
            (PRODUCER.REFERENCE, lambda d: d.pop("platterSource")),
            (PRODUCER.REFERENCE, lambda d: d.update(platterSource="hardwareTelemetry")),
            (PRODUCER.REFERENCE, lambda d: d.update(hardwareGroundTruth=True)),
            (PRODUCER.REFERENCE, lambda d: d.update(canonicalReference=True)),
            (PRODUCER.REFERENCE, lambda d: d["video"].pop("analysisFPS")),
            (PRODUCER.REFERENCE, lambda d: d["video"].update(analysisFPS=0)),
            (PRODUCER.REFERENCE, lambda d: d["video"].update(analysisFPS=59.94125756758216)),
            (PRODUCER.REFERENCE, lambda d: d.pop("tracking")),
            (PRODUCER.REFERENCE, lambda d: d["source"]["datasetMetadata"].pop("sourceType")),
            (PRODUCER.AUDIO, lambda d: d.update(modifiesVisionTrajectory=True)),
            (PRODUCER.AUDIO, lambda d: d["events"][0].update(visionTimeSeconds=25)),
            (PRODUCER.AUDIO, lambda d: d["source"].update(zip="another.zip")),
            (PRODUCER.AUDIO, lambda d: d["analysis"].update(analysisFPS=60)),
            (PRODUCER.LAG, lambda d: d.update(modifiesVisionTrajectory=True)),
            (PRODUCER.LAG, lambda d: d.update(sourceCSV="another.csv")),
        ]
        for name, edit in cases:
            with self.subTest(name=name, edit=edit):
                original = (self.evidence / name).read_bytes()
                self.edit_json(name, edit)
                with self.assertRaises(PRODUCER.EvidenceError):
                    self.produce()
                (self.evidence / name).write_bytes(original)

    def test_audio_copied_vision_disagreement_fails(self):
        for key, value in (("vision_velocity_deg_s", "123"), ("vision_direction", "REVERSE"),
                           ("timestamp_s", "25"), ("vision_interpolated", "True"), ("visual_confidence", "0.1")):
            with self.subTest(key=key):
                original = (self.evidence / PRODUCER.FUSION).read_bytes()
                self.edit_csv(PRODUCER.FUSION, lambda rows: rows[0].update({key: value}))
                with self.assertRaisesRegex(PRODUCER.EvidenceError, "conflicts"):
                    self.produce()
                (self.evidence / PRODUCER.FUSION).write_bytes(original)

    def test_no_overwrite_or_source_tree_output(self):
        output = self.root / "exists.json"
        output.write_text("keep me")
        self.assertNotEqual(self.cli(output).returncode, 0)
        self.assertEqual(output.read_text(), "keep me")
        self.assertNotEqual(self.cli(self.evidence / "new.json").returncode, 0)
        self.assertFalse((self.evidence / "new.json").exists())
        self.assertEqual(list(self.root.glob(".derived-inspection-*")), [])

    def test_nonfinite_duplicate_json_and_bad_csv_rejected(self):
        original = (self.evidence / PRODUCER.REFERENCE).read_text()
        for content in (original.replace('"analysisFPS": 59.94005994005994', '"analysisFPS": NaN'),
                        original.replace('"schemaVersion": 1', '"schemaVersion": 1, "schemaVersion": 1')):
            (self.evidence / PRODUCER.REFERENCE).write_text(content)
            with self.assertRaises(PRODUCER.EvidenceError):
                self.produce()
        (self.evidence / PRODUCER.REFERENCE).write_text(original)
        self.edit_csv(PRODUCER.TRAJECTORY, lambda rows: rows[0].update(smoothed_angle_deg="nan"))
        with self.assertRaises(PRODUCER.EvidenceError):
            self.produce()


if __name__ == "__main__":
    unittest.main()
