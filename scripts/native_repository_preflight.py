#!/usr/bin/env python3
"""Bound canonical-repository access in the actual native test host.

No permissions are changed. A PASS reserves one products directory/host identity
for one subsequent software gate; it never replaces the gate's test results.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

from run_mac_test_gate import INFRASTRUCTURE_EXIT, native_invocation, supervise

SELECTOR = "CaptureReliabilityPhase1CoreTests/testPythonBytecodeCachesAreIgnoredAndUntracked"
PERMISSION_EXIT = 77
CONTEXT_KEY = "SCRATCHLAB_NATIVE_PREFLIGHT_CONTEXT"


def input_identity(project):
    root = project.parent
    # These determine the host identity, build configuration and access probe.
    names = [".git", "ScratchLab.xcodeproj/project.pbxproj", "ScratchLab.xctestplan",
             "ScratchLab.xcodeproj/xcshareddata/xcschemes/ScratchLabDesktop.xcscheme",
             "ScratchLabDesktopTests/CaptureReliabilityPhase1Tests.swift",
             "scripts/run_mac_test_gate.py", "scripts/native_repository_preflight.py"]
    return {name: hashlib.sha256((root / name).read_bytes()).hexdigest()
            for name in names if name != ".git" or (root / name).is_file()}


def permission_evidence(identity, directory):
    # Read-only system evidence, bounded independently of the native supervisor.
    query = ('process == "tccd" AND eventMessage CONTAINS "' + identity +
             '" AND eventMessage CONTAINS "kTCCServiceSystemPolicyDownloadsFolder"')
    try:
        result = subprocess.run(["/usr/bin/log", "show", "--last", "5m", "--style",
                                 "compact", "--predicate", query],
                                capture_output=True, timeout=10)
        (directory / "tcc.log").write_bytes(result.stdout + result.stderr)
        return result.returncode == 0 and b"AUTHREQ_PROMPTING" in result.stdout
    except (OSError, subprocess.TimeoutExpired):
        return False  # Unknown access is infrastructure error, never assumed PASS.


def bounded_probe(command, directory, timeout, *, environment=None, roots=(),
                  permission_check=lambda: False):
    native = supervise(command, directory, timeout, environment=environment,
                       owned_executable_roots=roots)
    log = (directory / "output.log").read_text(errors="replace") if (directory / "output.log").exists() else ""
    passed = len(re.findall(r"Test Case .* testPythonBytecodeCachesAreIgnoredAndUntracked\]' passed", log))
    clean = native["childReaped"] and not native["survivors"]
    status = "INFRASTRUCTURE ERROR"
    if clean and native["status"] == "PASS" and passed == 2:
        status = "PASS"
    elif clean and permission_check():
        status = "PERMISSION BLOCKED"
    result = {"status": status, "supervisorStatus": native["status"],
              "executionsPassed": passed, "childReaped": native["childReaped"],
              "survivors": native["survivors"],
              "exitCode": 0 if status == "PASS" else PERMISSION_EXIT if status == "PERMISSION BLOCKED" else INFRASTRUCTURE_EXIT}
    (directory / "access-result.json").write_text(json.dumps(result, indent=2) + "\n")
    return result


def prepared_context(project, directory):
    directory = directory.resolve()
    result = json.loads((directory / "preflight/access-result.json").read_text())
    context = json.loads((directory / "preflight-context.json").read_text())
    if (result["status"] != "PASS" or context["project"] != str(project)
            or context["inputs"] != input_identity(project)
            or context["directory"] != str(directory)
            or (directory / "receipt.json").exists()
            or (directory / "invocation.json").exists()):
        raise ValueError("Preflight context is stale, unsuccessful, relocated or already consumed")
    return directory


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", type=Path, required=True)
    parser.add_argument("--evidence-root", type=Path, required=True)
    args = parser.parse_args()
    project = args.project.resolve()
    args.evidence_root.mkdir(parents=True, exist_ok=True)
    directory = Path(tempfile.mkdtemp(prefix="access-", dir=args.evidence_root)).resolve()
    probe = directory / "preflight"
    probe.mkdir()
    try:
        inputs = input_identity(project)
        command, env, products = native_invocation(project, "software", directory, [SELECTOR])
        command[command.index("-resultBundlePath") + 1] = str(probe / "tests.xcresult")
        identity = next(x.split("=", 1)[1] for x in command if x.startswith("PRODUCT_BUNDLE_IDENTIFIER="))
        (directory / "preflight-context.json").write_text(json.dumps({
            "project": str(project), "directory": str(directory), "identity": identity,
            "inputs": inputs, "selector": SELECTOR, "timeoutSeconds": 120}, indent=2) + "\n")
        print(f"Repository preflight: exact native host {identity}; deadline 120s; {directory}", flush=True)
        result = bounded_probe(command, probe, 120, environment=env, roots=[products],
                               permission_check=lambda: permission_evidence(identity, probe))
    except (OSError, ValueError, KeyError) as error:
        result = {"status": "INFRASTRUCTURE ERROR", "exitCode": INFRASTRUCTURE_EXIT, "error": str(error)}
        (probe / "access-result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(f"Repository preflight: {result['status']}; context {directory}", flush=True)
    if result["status"] == "PASS":
        print(f"Use {CONTEXT_KEY}={directory} for the single fresh scripts/build.sh all invocation.", flush=True)
    elif result["status"] == "PERMISSION BLOCKED":
        print("Human action required: allow this ScratchLab test host to access the Downloads folder. Full gate NOT RUN.", flush=True)
    return result["exitCode"]


if __name__ == "__main__":
    sys.exit(main())
