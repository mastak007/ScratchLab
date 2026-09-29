#!/usr/bin/env python3
"""Guard the local CXL signing overlay and the separate Store contract."""
import json
import pathlib
import plistlib
import subprocess
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


class CXLLocalSigningTests(unittest.TestCase):
    def test_overlay_cannot_override_functional_build_inputs(self):
        allowed = {
            "CODE_SIGN_STYLE", "CODE_SIGN_IDENTITY", "DEVELOPMENT_TEAM",
            "PROVISIONING_PROFILE", "PROVISIONING_PROFILE_SPECIFIER",
            "CODE_SIGN_ENTITLEMENTS", "CODE_SIGN_INJECT_BASE_ENTITLEMENTS",
            "ENABLE_HARDENED_RUNTIME", "OTHER_CODE_SIGN_FLAGS",
        }
        settings = {}
        for line in (ROOT / "ScratchLabDesktop/CXLLocalRelease.xcconfig").read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("//"):
                continue
            key, separator, value = line.partition("=")
            self.assertTrue(separator, "Includes or non-assignment directives need review")
            key = key.strip()
            self.assertIn(key, allowed, "Local signing must not alter compilation or resources")
            self.assertNotIn(key, settings)
            settings[key] = value.strip()
        self.assertEqual(settings["CODE_SIGN_IDENTITY"], "Developer ID Application")
        self.assertEqual(settings["DEVELOPMENT_TEAM"], "2DDKGL33BU")
        self.assertEqual(settings["PROVISIONING_PROFILE"], "")
        self.assertEqual(settings["PROVISIONING_PROFILE_SPECIFIER"], "")
        self.assertEqual(settings["CODE_SIGN_INJECT_BASE_ENTITLEMENTS"], "NO")
        self.assertEqual(settings["ENABLE_HARDENED_RUNTIME"], "YES")
        self.assertEqual(settings["CODE_SIGN_STYLE"], "Manual")
        self.assertEqual(settings["OTHER_CODE_SIGN_FLAGS"], "$(inherited) --timestamp")
        self.assertEqual(settings["CODE_SIGN_ENTITLEMENTS"],
                         "ScratchLabDesktop/ScratchLabDesktop.entitlements")

    def test_local_entitlements_preserve_all_store_runtime_capabilities(self):
        desktop = ROOT / "ScratchLabDesktop"
        local = plistlib.loads((desktop / "ScratchLabDesktop.entitlements").read_bytes())
        store = plistlib.loads((desktop / "ScratchLabCXL.entitlements").read_bytes())
        distribution_only = {"com.apple.application-identifier",
                             "com.apple.developer.team-identifier", "keychain-access-groups"}
        self.assertEqual(local, {k: v for k, v in store.items() if k not in distribution_only})
        self.assertTrue(local["com.apple.security.app-sandbox"])
        self.assertNotIn("com.apple.security.get-task-allow", local)
        self.assertFalse(distribution_only.intersection(local))

    def test_store_configuration_retains_its_submission_contract(self):
        project = json.loads(subprocess.check_output([
            "/usr/bin/plutil", "-convert", "json", "-o", "-",
            str(ROOT / "ScratchLab.xcodeproj/project.pbxproj")]))
        objects = project["objects"]
        target = next(v for v in objects.values()
                      if v["isa"] == "PBXNativeTarget" and v.get("name") == "ScratchLabDesktop")
        configurations = objects[target["buildConfigurationList"]]["buildConfigurations"]
        store = next(objects[c]["buildSettings"] for c in configurations
                     if objects[c]["name"] == "CXLRelease")
        self.assertEqual(store["CODE_SIGN_STYLE"], "Manual")
        self.assertEqual(store["CODE_SIGN_IDENTITY"], "Apple Distribution")
        self.assertEqual(store["PROVISIONING_PROFILE_SPECIFIER"], "ScratchLab CXL Mac App Store")
        self.assertEqual(store["CODE_SIGN_ENTITLEMENTS"], "ScratchLabDesktop/ScratchLabCXL.entitlements")
        self.assertEqual(store["PRODUCT_BUNDLE_IDENTIFIER"], "com.machelpnz.scratchlab.cxl-authoring")
        self.assertEqual(store["ENABLE_HARDENED_RUNTIME"], "YES")
        self.assertEqual(store["SWIFT_ACTIVE_COMPILATION_CONDITIONS"], "$(inherited) CXL_AUTHORING")


if __name__ == "__main__":
    unittest.main()
