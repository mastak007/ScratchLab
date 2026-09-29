#!/usr/bin/env python3
"""Fast disposable access probes; no native app launch or TCC mutation."""
import json
import os
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest import mock

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

    def retained_context(self):
        import native_repository_preflight as module
        project = Path(module.__file__).resolve().parent.parent / "ScratchLab.xcodeproj"
        identity = "com.machelpnz.scratchlab.nativegate.0123456789ab"
        probe = self.root / "preflight"
        probe.mkdir()
        command, _, _ = native_invocation(project, "software", self.root,
                                          ["one/test"], retained_identity=identity)
        (probe / "access-result.json").write_text(json.dumps({"status": "PASS"}))
        (probe / "receipt.json").write_text(json.dumps({"command": command}))
        context = {"project": str(project), "directory": str(self.root),
                   "inputs": input_identity(project), "identity": identity}
        (self.root / "preflight-context.json").write_text(json.dumps(context))
        return project, identity, context

    def test_prepared_context_preserves_exact_host_and_cannot_be_consumed_twice(self):
        import run_mac_test_gate as gate
        project, identity, _ = self.retained_context()
        context = prepared_context(project, self.root)
        with mock.patch.dict(os.environ, {"SCRATCHLAB_NATIVE_PREFLIGHT_CONTEXT": str(context)}), \
             mock.patch.object(sys, "argv", ["gate", "--project", str(project),
                                            "--evidence-root", str(self.root)]), \
             mock.patch.object(gate, "supervise", return_value={"status": "PASS", "exitCode": 0}) as supervisor:
            self.assertEqual(gate.main(), 0)
        command = supervisor.call_args.args[0]
        self.assertEqual([x for x in command if x.startswith("PRODUCT_BUNDLE_IDENTIFIER=")],
                         ["PRODUCT_BUNDLE_IDENTIFIER=" + identity])
        self.assertEqual(supervisor.call_args.kwargs["owned_executable_roots"], [self.root / "Products"])
        with self.assertRaises(ValueError):
            prepared_context(project, context)

    def test_retained_identity_is_independent_of_evidence_location(self):
        project = Path("/repository/ScratchLab.xcodeproj")
        identity = "com.machelpnz.scratchlab.nativegate.0123456789ab"
        commands = [native_invocation(project, "software", self.root / name,
                                     retained_identity=identity)[0] for name in ["first", "second"]]
        for command in commands:
            self.assertEqual([x for x in command if x.startswith("PRODUCT_BUNDLE_IDENTIFIER=")],
                             ["PRODUCT_BUNDLE_IDENTIFIER=" + identity])
        self.assertNotEqual([x for x in commands[0] if x.startswith("SYMROOT=")],
                            [x for x in commands[1] if x.startswith("SYMROOT=")])

    def test_retained_identity_cannot_select_production_or_malformed_bundle(self):
        for identity in ["com.machelpnz.scratchlab.cxl-authoring", "com.machelpnz.scratchlab",
                         "", "com.machelpnz.scratchlab.nativegate.not-hex", 123]:
            with self.subTest(identity=identity), self.assertRaises(ValueError):
                native_invocation(Path("/repository/ScratchLab.xcodeproj"), "software",
                                  self.root, retained_identity=identity)

    def test_prepared_context_rejects_missing_or_different_observed_identity(self):
        project, _, context = self.retained_context()
        path = self.root / "preflight-context.json"
        for identity in [None, "com.machelpnz.scratchlab.nativegate.abcdef012345"]:
            context["identity"] = identity
            path.write_text(json.dumps(context))
            with self.subTest(identity=identity), self.assertRaises(ValueError):
                prepared_context(project, self.root)

    def test_preflight_contains_no_security_mutation_commands(self):
        import native_repository_preflight as module
        source = Path(module.__file__).read_text()
        for forbidden in ["tccutil", "TCC.db", "sqlite3", "osascript", "sudo", "chmod", "killall"]:
            self.assertNotIn(forbidden, source)


if __name__ == "__main__":
    unittest.main()
