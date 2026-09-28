#!/usr/bin/env python3
"""Fast disposable access probes; no native app launch or TCC mutation."""
import json
import os
from pathlib import Path
import sys
import tempfile
import time
import unittest

from native_repository_preflight import bounded_probe, input_identity, prepared_context
from run_mac_test_gate import ProcessTable, native_invocation

PASS_LINE = "Test Case '-[ScratchLabDesktopTests.CaptureReliabilityPhase1CoreTests testPythonBytecodeCachesAreIgnoredAndUntracked]' passed (0.001 seconds)."


class RepositoryPreflightTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="scratchlab-access-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()

    def probe(self, code, timeout=3, permission_check=lambda: False):
        return bounded_probe([sys.executable, "-u", "-c", code], self.root / "probe",
                             timeout, permission_check=permission_check)

    def test_accessible_fixture_passes_and_reaps(self):
        path = self.root / "index"
        path.write_bytes(b"canonical fixture")
        result = self.probe(f"from pathlib import Path; assert Path({str(path)!r}).read_bytes(); print({PASS_LINE!r}); print({PASS_LINE!r})")
        self.assertEqual(result["status"], "PASS")
        self.assertEqual(result["executionsPassed"], 2)
        self.assertTrue(result["childReaped"])
        self.assertEqual(result["survivors"], [])

    def test_inaccessible_fixture_is_permission_blocked_quickly(self):
        path = self.root / "denied"
        path.write_text("fixture")
        path.chmod(0)
        try:
            start = time.monotonic()
            result = self.probe(f"from pathlib import Path; Path({str(path)!r}).read_bytes()",
                                permission_check=lambda: "PermissionError" in (self.root / "probe/output.log").read_text())
            self.assertEqual(result["status"], "PERMISSION BLOCKED")
            self.assertLess(time.monotonic() - start, 3)
            self.assertTrue(result["childReaped"])
        finally:
            path.chmod(0o600)

    def test_missing_repository_is_infrastructure_error(self):
        result = self.probe("from pathlib import Path; Path('/nonexistent-scratchlab-repository/.git').read_bytes()")
        self.assertEqual(result["status"], "INFRASTRUCTURE ERROR")

    def test_unresponsive_host_is_bounded_and_all_owned_processes_reaped(self):
        start = time.monotonic()
        result = self.probe("import signal; signal.pause()", timeout=0.2)
        self.assertEqual(result["status"], "INFRASTRUCTURE ERROR")
        self.assertLess(time.monotonic() - start, 4)
        self.assertTrue(result["childReaped"])
        self.assertEqual(result["survivors"], [])
        receipt = json.loads((self.root / "probe/receipt.json").read_text())
        live = ProcessTable().snapshot()
        for proc in receipt["ownedProcesses"]:
            self.assertFalse(proc["pid"] in live and list(live[proc["pid"]].birth) == proc["birth"])

    def test_zero_test_success_cannot_pass_access_preflight(self):
        self.assertEqual(self.probe("pass")["status"], "INFRASTRUCTURE ERROR")

    def test_prepared_context_preserves_exact_host_and_cannot_be_consumed_twice(self):
        import native_repository_preflight as module
        project = Path(module.__file__).resolve().parent.parent / "ScratchLab.xcodeproj"
        probe = self.root / "preflight"
        probe.mkdir()
        (probe / "access-result.json").write_text(json.dumps({"status": "PASS"}))
        (self.root / "preflight-context.json").write_text(json.dumps({"project": str(project), "directory": str(self.root), "inputs": input_identity(project)}))
        context = prepared_context(project, self.root)
        a, _, pa = native_invocation(project, "software", context, ["one/test"])
        b, _, pb = native_invocation(project, "software", context)
        self.assertEqual(pa, pb)
        self.assertEqual([x for x in a if x.startswith("PRODUCT_BUNDLE_IDENTIFIER=")], [x for x in b if x.startswith("PRODUCT_BUNDLE_IDENTIFIER=")])
        (context / "invocation.json").write_text("{}")
        with self.assertRaises(ValueError):
            prepared_context(project, context)

    def test_preflight_contains_no_security_mutation_commands(self):
        import native_repository_preflight as module
        source = Path(module.__file__).read_text()
        for forbidden in ["tccutil", "TCC.db", "sqlite3", "osascript", "sudo", "chmod", "killall"]:
            self.assertNotIn(forbidden, source)


if __name__ == "__main__":
    unittest.main()
