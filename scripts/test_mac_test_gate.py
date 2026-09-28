#!/usr/bin/env python3
"""Disposable-process tests only: never enumerate, bind, or capture audio."""
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

from run_mac_test_gate import (INFRASTRUCTURE_EXIT, POLICY_PATH, ProcessTable,
                               TIMEOUT_EXIT, Process, discover_owned, native_invocation, supervise,
                               registered_xcode_workers, xcode_registry_entries)

REPO = Path(__file__).resolve().parent.parent
POLICY = json.loads(POLICY_PATH.read_text())


class NativeSupervisorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="scratchlab-supervisor-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def tearDown(self):
        evidence = os.environ.get("SCRATCHLAB_SUPERVISOR_TEST_EVIDENCE")
        if evidence:
            target = Path(evidence) / self.id()
            for source in self.root.rglob("*"):
                if source.is_file() and source.suffix in (".json", ".log"):
                    output = target / source.relative_to(self.root)
                    output.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(source, output)

    def run_child(self, code, **kwargs):
        return supervise([sys.executable, "-u", "-c", code], self.root / "run",
                         kwargs.pop("timeout", 5), terminate_grace=0.1,
                         kill_grace=2, **kwargs)

    def assert_clean(self, receipt):
        self.assertTrue(receipt["childReaped"])
        self.assertEqual(receipt["survivors"], [])
        live = ProcessTable().snapshot()
        for p in receipt["ownedProcesses"]:
            self.assertFalse(p["pid"] in live and list(live[p["pid"]].birth) == list(p["birth"]))
        with self.assertRaises(ChildProcessError):
            os.waitpid(receipt["childPID"], os.WNOHANG)

    def test_normal_child_preserves_both_streams_and_reaps_without_signal(self):
        r = self.run_child("import sys; print('stdout receipt'); print('stderr receipt', file=sys.stderr)")
        self.assertEqual((r["status"], r["exitCode"]), ("PASS", 0))
        self.assertEqual(r["signals"], [])
        output = (self.root / "run/output.log").read_text()
        self.assertIn("stdout receipt", output)
        self.assertIn("stderr receipt", output)
        self.assert_clean(r)

    def test_ordinary_failure_preserves_child_exit(self):
        r = self.run_child("import sys; print('assertion failure'); sys.exit(65)")
        self.assertEqual((r["status"], r["exitCode"]), ("TEST FAILURE", 65))
        self.assertEqual(r["signals"], [])
        self.assert_clean(r)

    def test_child_exit_124_is_not_misclassified_as_timeout(self):
        r = self.run_child("raise SystemExit(124)")
        self.assertEqual(r["status"], "TEST FAILURE")
        self.assert_clean(r)

    def test_deadline_kills_stubborn_group_preserves_output_and_spares_unrelated(self):
        unrelated = subprocess.Popen([sys.executable, "-c", "import signal; signal.pause()"], start_new_session=True)
        try:
            code = """import os, signal, subprocess, sys
signal.signal(signal.SIGTERM, signal.SIG_IGN)
worker = subprocess.Popen([sys.executable, '-u', '-c',
    "import signal; signal.signal(signal.SIGTERM, signal.SIG_IGN); print('grandchild ready', flush=True); signal.pause()"])
print('parent ready', os.getpid(), 'worker', worker.pid, flush=True)
signal.pause()
"""
            r = self.run_child(code, timeout=1)
            self.assertEqual((r["status"], r["exitCode"]), ("PROCESS TIMEOUT / HANG", TIMEOUT_EXIT))
            self.assertTrue(any(x["signal"] == signal.SIGKILL for x in r["signals"]))
            self.assertGreaterEqual(len(r["ownedProcesses"]), 2)
            output = (self.root / "run/output.log").read_text()
            self.assertIn("parent ready", output)
            self.assertIn("grandchild ready", output)
            self.assertIsNone(unrelated.poll())
            self.assert_clean(r)
        finally:
            unrelated.kill()
            unrelated.wait(timeout=3)

    def test_detached_test_host_is_owned_by_unique_executable_path(self):
        products = self.root / "Products"
        products.mkdir()
        host = products / "DisposableTestHost"
        shutil.copyfile("/bin/sleep", host)
        host.chmod(0o755)
        # Copying a platform-signed binary can make AMFI kill it immediately.
        # Sign only this disposable copy so the test proves supervisor cleanup.
        subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(host)],
                       check=True, capture_output=True)
        # Deliberately not a descendant/group member of the supervised command,
        # modelling an app test host that Apple's machinery launches via launchd.
        orphan = subprocess.Popen([str(host), "60"], start_new_session=True)
        try:
            r = self.run_child("import signal; print('waiting'); signal.pause()", timeout=0.3,
                               owned_executable_roots=[products])
            self.assertEqual(r["status"], "PROCESS TIMEOUT / HANG")
            self.assertTrue(any(p["pid"] == orphan.pid for p in r["ownedProcesses"]))
            self.assertTrue(any(s.get("pid") == orphan.pid and s["signal"] == signal.SIGTERM
                                for s in r["signals"]))
            self.assertEqual(orphan.wait(timeout=3), -signal.SIGTERM)
            self.assert_clean(r)
        finally:
            if orphan.poll() is None:
                orphan.kill()
                orphan.wait(timeout=3)

    def test_success_with_lingering_worker_is_infrastructure_error_and_cleaned(self):
        code = """import subprocess, sys
subprocess.Popen([sys.executable, '-u', '-c', 'import signal; print("worker ready"); signal.pause()'])
print('root exiting')
"""
        r = self.run_child(code)
        self.assertEqual(r["status"], "INFRASTRUCTURE ERROR")
        self.assertEqual(r["exitCode"], INFRASTRUCTURE_EXIT)
        self.assert_clean(r)

    def test_registered_external_service_is_released_after_normal_success_only(self):
        # Deterministic lifecycle fixture: detached service initially descends
        # from our root, then is reparented after the client exits successfully.
        root = Process(900, 1, 900, (10, 1), "/tool/client", 2)
        first = Process(901, 900, 901, (10, 2), "/tool/service", 2)
        shared = Process(901, 1, 901, (10, 2), "/tool/service", 2)
        child = mock.Mock(pid=900, returncode=None)
        child.poll.return_value = 0
        child.wait.return_value = 0
        table = mock.Mock()
        table.snapshot.side_effect = [{900: root, 901: first}, {901: shared}, {901: shared}]
        with mock.patch("run_mac_test_gate.ProcessTable", return_value=table), \
             mock.patch("run_mac_test_gate.subprocess.Popen", return_value=child), \
             mock.patch("run_mac_test_gate.registered_xcode_workers", return_value={shared.identity}), \
             mock.patch("run_mac_test_gate.os.kill") as kill:
            receipt = self.run_child("unused")
        self.assertEqual((receipt["status"], receipt["exitCode"]), ("PASS", 0))
        self.assertEqual(receipt["externalSharedWorkers"][0]["pid"], 901)
        self.assertTrue(receipt["childReaped"])
        self.assertEqual(receipt["survivors"], [])
        kill.assert_not_called()

    def test_timeout_never_releases_workers_through_normal_exit_probe(self):
        with mock.patch("run_mac_test_gate.registered_xcode_workers") as probe:
            receipt = self.run_child("import signal; signal.pause()", timeout=0.2)
        probe.assert_not_called()
        self.assertEqual(receipt["exitCode"], TIMEOUT_EXIT)
        self.assert_clean(receipt)

    def test_reused_pid_and_group_cannot_adopt_or_signal_an_unrelated_process(self):
        old = Process(100, 1, 100, (10, 1), "/owned/old", 2)
        reused = Process(100, 1, 100, (20, 1), "/unrelated/new", 2)
        tracked = {old.identity: old}
        self.assertEqual(discover_owned({100: reused}, tracked, 100, True, []), [])
        self.assertNotIn(reused.identity, tracked)

    def test_launch_failure_is_infrastructure_error(self):
        r = supervise(["/definitely/not/a/test/executable"], self.root / "run", 1)
        self.assertEqual((r["status"], r["exitCode"]), ("INFRASTRUCTURE ERROR", INFRASTRUCTURE_EXIT))
        self.assertIsNone(r["childExit"])
        self.assertEqual(r["signals"], [])

    def test_invalid_deadlines_do_not_launch(self):
        for value in [0, -1, float("nan"), float("inf")]:
            r = supervise(["/must/not/launch"], self.root / "invalid", value)
            self.assertEqual(r["status"], "INFRASTRUCTURE ERROR")
            self.assertNotIn("childPID", r)


class XcodeSharedWorkerEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="scratchlab-worker-evidence-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.tool = self.root / "toolchain/actool"
        self.worker = self.tool.with_name("ibtoold")
        self.process = Process(901, 1, 901, (10, 2), str(self.worker), 2)
        self.table = mock.Mock()
        self.table.snapshot.return_value = {901: self.process}
        self.pipes = [self.root / role for role in ("IN", "OUT", "ERROR", "CONTROL")]
        for path in self.pipes:
            os.mkfifo(path)
        self.registry = "registrations[0].valid = true\nregistrations[0].pid = 901\n" + "".join(
            f"registrations[0].pipeNames[IBTOOLD-{path.name}] = {path}\n" for path in self.pipes)

    def read_tool(self, command, **kwargs):
        if command[0] == "/usr/bin/xcrun":
            return str(self.tool) + "\n"
        if command[0] == "/usr/bin/codesign":
            return ""
        if "--show-shared-memory" in command:
            return self.registry
        if command[0] == "/usr/sbin/lsof":
            return "".join(f"n{path}\n" for path in self.pipes)
        self.fail(str(command))

    def probe(self, process=None, roots=()):
        with mock.patch("run_mac_test_gate.subprocess.check_output", side_effect=self.read_tool), \
             mock.patch("run_mac_test_gate.os.getsid", return_value=901):
            return registered_xcode_workers([process or self.process], self.table, 900,
                                             roots, self.root, None)

    def test_complete_registration_and_open_fifo_identity_establish_shared_service(self):
        self.assertEqual(self.probe(), {self.process.identity})

    def test_same_executable_without_complete_registry_is_not_exempt(self):
        self.registry = self.registry.replace("valid = true", "valid = false")
        self.assertEqual(self.probe(), set())
        self.registry = "registrations[0].valid = true\nregistrations[0].pid = 901\n"
        self.assertEqual(self.probe(), set())

    def test_registry_pid_reuse_or_missing_open_channels_is_not_exempt(self):
        self.table.snapshot.return_value = {901: Process(901, 1, 901, (20, 1), str(self.worker), 2)}
        self.assertEqual(self.probe(), set())
        self.table.snapshot.return_value = {901: self.process}
        original = self.read_tool
        self.read_tool = lambda command, **kwargs: "" if command[0] == "/usr/sbin/lsof" else original(command, **kwargs)
        self.assertEqual(self.probe(), set())

    def test_unique_product_host_and_non_detached_worker_remain_owned(self):
        self.assertEqual(self.probe(roots=[self.worker.parent]), set())
        self.assertEqual(self.probe(Process(901, 900, 900, (10, 2), str(self.worker), 2)), set())

    def test_untrusted_toolchain_or_registry_failure_cannot_release_worker(self):
        with mock.patch("run_mac_test_gate.subprocess.check_output", side_effect=subprocess.CalledProcessError(1, "verify")), \
             mock.patch("run_mac_test_gate.os.getsid", return_value=901):
            self.assertEqual(registered_xcode_workers([self.process], self.table, 900, [], self.root, None), set())

    def test_released_service_cannot_adopt_unrelated_future_clients(self):
        client = Process(902, 901, 902, (12, 1), "/external/client", 2)
        tracked = {self.process.identity: self.process}
        self.assertEqual(discover_owned({901: self.process, 902: client}, tracked, 900, True, [],
                                        {self.process.identity}), [])
        self.assertNotIn(client.identity, tracked)


class NativeAdmissionPolicyTests(unittest.TestCase):
    def test_default_overrides_ambient_integration_and_capture_opt_in(self):
        key = POLICY["environmentKey"]
        command, env, products = native_invocation(REPO / "ScratchLab.xcodeproj", "software", Path("/tmp/example"),
            environment={key: "1", "TEST_RUNNER_" + key: "1", "SCRATCHLAB_CAPTURE_OUTPUT": "1"})
        self.assertEqual(env[key], "0")
        self.assertEqual(env["TEST_RUNNER_" + key], "0")
        self.assertEqual(env["SCRATCHLAB_CAPTURE_OUTPUT"], "0")
        self.assertFalse(any(x.startswith("-only-testing:") for x in command))
        self.assertIn("SYMROOT=" + str(products), command)
        self.assertTrue(any(x.startswith("PRODUCT_BUNDLE_IDENTIFIER=com.machelpnz.scratchlab.nativegate.") for x in command))

    def test_explicit_integration_forwards_one_admission_contract_and_exact_selectors(self):
        command, env, _ = native_invocation(REPO / "ScratchLab.xcodeproj", "audio-integration", Path("/tmp/example"), environment={})
        key = POLICY["environmentKey"]
        self.assertEqual(env[key], "1")
        self.assertEqual(env["TEST_RUNNER_" + key], "1")
        self.assertEqual(env["SCRATCHLAB_CAPTURE_OUTPUT"], "1")
        self.assertEqual([x.split("ScratchLabDesktopTests/", 1)[1] for x in command if x.startswith("-only-testing:")], POLICY["integrationSelectors"])

    def test_real_device_methods_require_admission_as_first_statement(self):
        found = {}
        for f in (REPO / "ScratchLabDesktopTests").glob("*.swift"):
            source = f.read_text()
            for match in re.finditer(r'    func (test\w+)\(\)(?: throws)? \{\n(.*?)\n    \}', source, re.S):
                classes = re.findall(r'^(?:final class|extension) (\w+)', source[:match.start()], re.M)
                if classes:
                    found[classes[-1] + "/" + match[1]] = match[2]
        for selector in POLICY["integrationSelectors"]:
            body = found[selector]
            if "optionalDevice" in body:
                self.assertNotIn("= AVCaptureDevice.default", body)
            else:
                self.assertEqual(body.strip().splitlines()[0], "try RealAudioIntegrationAdmission.requireOptIn()")

    def test_ordinary_pcm_and_injected_audio_tests_are_not_integration_selectors(self):
        names = "\n".join(POLICY["integrationSelectors"])
        for name in ["testGrainEdgeFadeInZerosFirstFrame", "testManualCaptureStartReportsEngineNotRunningExactlyOnce", "LowLatencySinkLifecycleTests", "testUnavailableRouteNeverSchedulesCountInOrRecording"]:
            self.assertNotIn(name, names)
        self.assertEqual(len(POLICY["integrationSelectors"]), len(set(POLICY["integrationSelectors"])))


class BuildScriptRoutingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="scratchlab-gate-routing-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.calls = self.root / "calls.jsonl"
        self.env = dict(os.environ, PATH=str(self.bin) + ":" + os.environ["PATH"],
                        GATE_TEST_CALLS=str(self.calls), GATE_TEST_BEHAVIOR="pass",
                        GATE_TEST_EVIDENCE=str(self.root / "native-evidence"))
        self.env.pop("SCRATCHLAB_NATIVE_PREFLIGHT_CONTEXT", None)
        # Stub only unrelated prerequisites; execute the REAL native supervisor.
        python = self.bin / "python3"
        python.write_text(f'''#!{sys.executable}
import json, os, sys
name=os.path.basename(sys.argv[1])
if name in ('test_mac_test_gate.py','test_native_repository_preflight.py','test_capture_pipeline.py'):
 with open(os.environ['GATE_TEST_CALLS'],'a') as f:f.write(json.dumps({{'prerequisite':name}})+'\\n')
 sys.exit(0)
if name == 'run_mac_test_gate.py':
 sys.argv += ['--evidence-root', os.environ['GATE_TEST_EVIDENCE']]
os.execv({sys.executable!r}, [{sys.executable!r}]+sys.argv[1:])
''')
        python.chmod(0o755)
        xcode = self.bin / "xcodebuild"
        xcode.write_text(f'''#!{sys.executable}
import json, os, signal, sys
with open(os.environ['GATE_TEST_CALLS'],'a') as f:
 f.write(json.dumps({{'argv':sys.argv[1:],'optIn':os.environ.get({POLICY['environmentKey']!r}), 'runnerOptIn':os.environ.get({'TEST_RUNNER_'+POLICY['environmentKey']!r})}})+'\\n')
print('FAKE native stdout',flush=True)
print('FAKE native stderr',file=sys.stderr,flush=True)
if 'test' in sys.argv:
 behavior=os.environ['GATE_TEST_BEHAVIOR']
 if behavior=='timeout':signal.pause()
 if behavior=='failure':sys.exit(65)
''')
        xcode.chmod(0o755)

    def invoke(self, mode, behavior="pass"):
        self.env["GATE_TEST_BEHAVIOR"] = behavior
        self.env["SCRATCHLAB_NATIVE_TEST_TIMEOUT_SECONDS"] = "0.4" if behavior == "timeout" else "10"
        # All process launches here target the disposable xcodebuild stub.
        result = subprocess.run(["bash", str(REPO / "scripts/build.sh"), mode],
                                env=self.env, text=True, capture_output=True, timeout=20)
        return result, [json.loads(x) for x in self.calls.read_text().splitlines()]

    def test_default_all_uses_supervisor_and_builds_only_after_success(self):
        self.env[POLICY["environmentKey"]] = "1"
        result, calls = self.invoke("all")
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        native = next(x for x in calls if "test" in x.get("argv", []))
        self.assertEqual(native["optIn"], "0")
        self.assertEqual(native["runnerOptIn"], "0")
        self.assertTrue(any(x.startswith("SYMROOT=") for x in native["argv"]))
        self.assertEqual(sum("build" in x.get("argv", []) for x in calls), 4)
        self.assertIn("Native gate: PASS", result.stdout)
        self.assertIn("does not establish", result.stdout)

    def test_explicit_integration_is_supervised_separate_and_has_no_platform_builds(self):
        result, calls = self.invoke("audio-integration")
        self.assertEqual(result.returncode, 0, result.stderr)
        native = next(x for x in calls if "argv" in x)
        self.assertEqual(native["optIn"], "1")
        self.assertEqual(native["runnerOptIn"], "1")
        self.assertFalse(any("build" in x.get("argv", []) for x in calls))
        self.assertIn("Explicit real-device audio integration", result.stdout)

    def test_timeout_stops_gate_and_does_not_reach_platform_builds(self):
        result, calls = self.invoke("all", "timeout")
        self.assertEqual(result.returncode, TIMEOUT_EXIT, result.stdout + result.stderr)
        self.assertIn("PROCESS TIMEOUT / HANG", result.stdout)
        self.assertFalse(any("build" in x.get("argv", []) for x in calls))

    def test_ordinary_test_failure_stops_gate_separately_from_timeout(self):
        result, calls = self.invoke("all", "failure")
        self.assertEqual(result.returncode, 65)
        self.assertIn("TEST FAILURE", result.stdout)
        self.assertNotIn("PROCESS TIMEOUT", result.stdout)
        self.assertFalse(any("build" in x.get("argv", []) for x in calls))


if __name__ == "__main__":
    unittest.main(verbosity=2)
