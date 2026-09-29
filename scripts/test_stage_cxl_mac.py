#!/usr/bin/env python3
"""Deterministic staging contract tests; no signing keys, Xcode or hardware."""
import copy
import json
import pathlib
import plistlib
import shutil
import tempfile
import unittest
from unittest import mock

import stage_cxl_mac as staging


class StagingTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="scratchlab-stage-contract-")
        self.addCleanup(self.tmp.cleanup)
        self.root = pathlib.Path(self.tmp.name)
        self.built = self.root / "built.app"
        self.installed = self.root / "installed.app"
        self.output = self.root / "stage" / "candidate.app"
        self.info = {"CFBundleIdentifier": staging.EXPECTED_BUNDLE,
                     "CFBundleExecutable": "ScratchLab", "NSCameraUsageDescription": "Camera"}
        for app in (self.built, self.installed):
            (app / "Contents/MacOS").mkdir(parents=True)
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps(self.info))
            (app / "Contents/MacOS/ScratchLab").write_bytes(b"verified executable")
        self.contract = dict(info=self.info, flags=0x10000,
            entitlements={"com.apple.security.app-sandbox": True},
            architectures=["arm64", "x86_64"], designatedRequirement="designated => verified",
            authorities=["Authority=Apple Distribution: Example"], teamIdentifier="2DDKGL33BU",
            signature="TeamIdentifier=2DDKGL33BU\n", executableSHA256="test-hash")
        self.commands = []

    def run_fake(self, *args):
        self.commands.append(args)
        if args[0] == "/usr/bin/ditto":
            shutil.copytree(args[1], args[2])
        if "--entitlements" in args and "-d" in args:
            return plistlib.dumps(self.contract["entitlements"])
        return b""

    def invoke(self, staged=None, exclude=False):
        with mock.patch.object(staging, "run", side_effect=self.run_fake), \
             mock.patch.object(staging, "signature", return_value="TeamIdentifier=2DDKGL33BU\n"), \
             mock.patch.object(staging, "signing_contract", side_effect=[self.contract, staged or self.contract]):
            return staging.stage(self.built, self.installed, self.output, "a" * 40,
                                 "2DDKGL33BU", exclude)

    def test_runtime_source_is_copied_without_resigning(self):
        result = self.invoke()
        self.assertEqual(result["staged"]["flags"], 0x10000)
        self.assertFalse(result["reSigned"])
        self.assertFalse(any("--sign" in c for c in self.commands))
        self.assertTrue(result["exactBundleCopy"])

    def test_runtime_removed_is_rejected(self):
        changed = copy.deepcopy(self.contract); changed["flags"] = 0
        with self.assertRaisesRegex(RuntimeError, "Hardened Runtime"):
            self.invoke(changed)
        self.assertFalse(self.output.with_suffix(".receipt.json").exists())

    def test_required_entitlement_removed_is_rejected(self):
        changed = copy.deepcopy(self.contract); changed["entitlements"] = {}
        with self.assertRaisesRegex(RuntimeError, "entitlements"):
            self.invoke(changed)

    def test_bundle_id_changed_is_rejected(self):
        changed = copy.deepcopy(self.contract); changed["info"]["CFBundleIdentifier"] = "wrong"
        with self.assertRaisesRegex(RuntimeError, "info"):
            self.invoke(changed)

    def test_valid_equivalent_artifact_accepts_and_writes_receipt(self):
        self.assertTrue(self.invoke()["stagingValid"])
        self.assertTrue(json.loads(self.output.with_suffix(".receipt.json").read_text())["stagingValid"])

    def test_invalid_nested_code_strict_verification_rejects(self):
        with mock.patch.object(staging, "run", side_effect=RuntimeError("nested code invalid")) as run:
            with self.assertRaisesRegex(RuntimeError, "nested code"):
                staging.signing_contract(self.built, "2DDKGL33BU")
        run.assert_called_once_with("/usr/bin/codesign", "--verify", "--deep", "--strict", str(self.built))

    def test_source_content_untouched(self):
        before = staging.content_manifest(self.built)
        self.invoke()
        self.assertEqual(staging.content_manifest(self.built), before)
        self.assertEqual(staging.content_manifest(self.output), before)

    def test_staging_failure_cannot_change_installed_destination(self):
        before = staging.content_manifest(self.installed)
        changed = copy.deepcopy(self.contract); changed["flags"] = 0
        with self.assertRaises(RuntimeError):
            self.invoke(changed)
        self.assertEqual(staging.content_manifest(self.installed), before)
        self.assertFalse(self.output.with_suffix(".receipt.json").exists())
        self.assertTrue(all(str(self.installed) != c[-1] for c in self.commands if c[0] == "/usr/bin/ditto"))

    def test_changed_designated_requirement_is_rejected(self):
        changed = copy.deepcopy(self.contract); changed["designatedRequirement"] = "different"
        with self.assertRaisesRegex(RuntimeError, "designatedRequirement"):
            self.invoke(changed)

    def test_missing_architecture_is_rejected(self):
        changed = copy.deepcopy(self.contract); changed["architectures"] = ["arm64"]
        with self.assertRaisesRegex(RuntimeError, "architectures"):
            self.invoke(changed)

    def test_copy_corruption_is_rejected(self):
        original = self.run_fake
        def corrupt(*args):
            result = original(*args)
            if args[0] == "/usr/bin/ditto":
                (self.output / "Contents/MacOS/ScratchLab").write_bytes(b"corrupt")
            return result
        self.run_fake = corrupt
        with self.assertRaisesRegex(RuntimeError, "bundle contents"):
            self.invoke()

    def test_output_inside_source_is_rejected_before_copy(self):
        self.output = self.built / "nested.app"
        with self.assertRaisesRegex(RuntimeError, "outside source"):
            self.invoke()
        self.assertEqual(self.commands, [])

    def test_resource_removal_resigns_outer_bundle_with_source_security(self):
        examples = self.built / "Contents/Resources/ReferenceExamples"
        examples.mkdir(parents=True); (examples / "sample.json").write_text("{}")
        result = self.invoke(exclude=True)
        self.assertTrue(result["reSigned"])
        sign = next(c for c in self.commands if "--sign" in c)
        self.assertNotIn("--deep", sign)
        self.assertIn("--preserve-metadata=identifier,requirements,flags,runtime", sign)
        self.assertEqual(sign[sign.index("--options") + 1], "0x10000")
        self.assertEqual(plistlib.loads(self.output.with_suffix(".entitlements.plist").read_bytes()),
                         self.contract["entitlements"])
        self.assertTrue(examples.exists())
        self.assertFalse((self.output / "Contents/Resources/ReferenceExamples").exists())


if __name__ == "__main__":
    unittest.main()
