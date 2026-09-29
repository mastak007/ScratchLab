#!/usr/bin/env python3
"""Bound a native test invocation outside its process; retain output and receipts.

macOS test hosts can be launchd children. Every native invocation uses a fresh
products directory; executable path plus kernel process birth identity proves
ownership independently of ancestry. No process-name matching or killall.
"""
from __future__ import annotations

import argparse
import ctypes
import hashlib
from dataclasses import dataclass
import json
import math
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import sys
import tempfile
import time

POLICY_PATH = Path(__file__).with_name("native_test_policy.json")
TIMEOUT_EXIT = 124
INFRASTRUCTURE_EXIT = 70


@dataclass(frozen=True)
class Process:
    pid: int
    ppid: int
    pgid: int
    birth: tuple[int, int]
    executable: str
    status: int

    @property
    def identity(self):
        return (self.pid, self.birth)


class BSDInfo(ctypes.Structure):
    _fields_ = [(name, ctypes.c_uint32) for name in (
        "flags", "status", "xstatus", "pid", "ppid", "uid", "gid", "ruid",
        "rgid", "svuid", "svgid", "reserved")]
    _fields_ += [("comm", ctypes.c_char * 16), ("name", ctypes.c_char * 32)]
    _fields_ += [(name, ctypes.c_uint32) for name in (
        "nfiles", "pgid", "pjobc", "tdev", "tpgid")]
    _fields_ += [("nice", ctypes.c_int32), ("start_sec", ctypes.c_uint64),
                ("start_usec", ctypes.c_uint64)]


class ProcessTable:
    def __init__(self):
        if sys.platform != "darwin":
            raise RuntimeError("Native test process ownership requires macOS libproc")
        self.lib = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
        self.lib.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64,
                                         ctypes.c_void_p, ctypes.c_int]
        self.lib.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
        self.lib.proc_listallpids.argtypes = [ctypes.c_void_p, ctypes.c_int]

    def snapshot(self):
        capacity = max(4096, self.lib.proc_listallpids(None, 0) + 256)
        pids = (ctypes.c_int * capacity)()
        count = self.lib.proc_listallpids(pids, ctypes.sizeof(pids))
        if count <= 0 or count >= capacity:
            raise RuntimeError("Cannot obtain complete process ownership snapshot")
        result = {}
        for pid in pids[:count]:
            info = BSDInfo()
            if self.lib.proc_pidinfo(pid, 3, 0, ctypes.byref(info), ctypes.sizeof(info)) != ctypes.sizeof(info):
                continue  # Process vanished or another user's inaccessible process.
            if info.uid != os.getuid() or info.status == 5:  # SZOMB: exited, not executing.
                continue
            buf = ctypes.create_string_buffer(4096)
            self.lib.proc_pidpath(pid, buf, len(buf))
            result[pid] = Process(pid, info.ppid, info.pgid,
                                  (info.start_sec, info.start_usec),
                                  os.fsdecode(buf.value), info.status)
        return result


def discover_owned(snapshot, tracked, child_pid, child_reaped, roots, shared=()):
    # A group number is not a permanent identity. Once our leader is reaped,
    # only an already-known live member can establish continued group ownership.
    group_owned = not child_reaped or any(
        p.pgid == child_pid and p.identity in tracked and p.identity not in shared
        for p in snapshot.values())
    changed = True
    while changed:
        changed = False
        for proc in snapshot.values():
            if proc.identity in shared:
                continue
            parent = snapshot.get(proc.ppid)
            by_parent = (parent is not None and parent.identity in tracked
                         and parent.identity not in shared)
            by_group = child_pid is not None and group_owned and proc.pgid == child_pid
            by_path = any(Path(proc.executable).is_relative_to(root)
                          for root in roots if proc.executable)
            if proc.identity not in tracked and (by_parent or by_group or by_path):
                tracked[proc.identity] = proc
                changed = True
    return [p for p in snapshot.values() if p.identity in tracked and p.identity not in shared]


def xcode_registry_entries(text):
    """Accept complete, valid registrations only; never infer ownership from a name."""
    entries = {}
    for index, field, value in re.findall(r"^registrations\[(\d+)\]\.(\S+) = (.+)$", text, re.M):
        entries.setdefault(index, {})[field] = value
    roles = ("IN", "OUT", "ERROR", "CONTROL")
    return {int(e["pid"]): [e[f"pipeNames[IBTOOLD-{role}]"] for role in roles]
            for e in entries.values() if e.get("valid") == "true"
            and e.get("pid", "").isdigit()
            and all(f"pipeNames[IBTOOLD-{role}]" in e for role in roles)}


def registered_xcode_workers(live, table, child_pid, roots, directory, environment):
    """Prove an idle external Xcode service by its registry AND open FIFO handles.

    This is called only after a normal child exit, never on a timeout/interruption.
    Unregistered workers, unique-product test hosts, and incomplete evidence retain
    the existing ownership/cleanup contract. No polling or idle grace period.
    """
    evidence = {"registeredSharedWorkers": [], "errors": []}
    accepted = set()

    def read(command):
        return subprocess.check_output(command, env=environment, stderr=subprocess.STDOUT,
                                       text=True, timeout=5)

    try:
        # A detached process alone proves nothing. First establish the selected,
        # Apple-signed toolchain's registry provider and service executable.
        candidates = [p for p in live if p.ppid == 1 and p.pgid == p.pid
                      and p.pgid != child_pid and p.executable
                      and not any(Path(p.executable).is_relative_to(root) for root in roots)]
        if not candidates:
            return accepted
        tool = Path(read(["/usr/bin/xcrun", "--find", "actool"]).strip()).resolve()
        worker = tool.with_name("ibtoold")
        candidates = [p for p in candidates if Path(p.executable).resolve() == worker
                      and os.getsid(p.pid) == p.pid]
        if not candidates:
            return accepted
        for executable in (tool, worker):
            read(["/usr/bin/codesign", "--verify", "--strict", "-R=anchor apple", str(executable)])
        registry = read([str(tool), "--show-shared-memory"])
        evidence["registry"] = registry
        entries = xcode_registry_entries(registry)
        for proc in candidates:
            pipes = entries.get(proc.pid)
            if not pipes or len(set(pipes)) != 4:
                continue
            current = table.snapshot().get(proc.pid)
            if (current is None or current.identity != proc.identity
                    or Path(current.executable).resolve() != worker):
                continue
            # Registry PID alone is insufficient: bind this live birth identity
            # to all four registered channels, which are owned user FIFOs.
            paths = [Path(path).resolve() for path in pipes]
            metadata = [path.stat() for path in paths]
            if not all(stat.S_ISFIFO(s.st_mode) and s.st_uid == os.getuid() for s in metadata):
                continue
            handles = read(["/usr/sbin/lsof", "-nP", "-a", "-p", str(proc.pid), "-Fn"])
            opened = {Path(line[1:]).resolve() for line in handles.splitlines()
                      if line.startswith("n/")}
            if not all(path in opened for path in paths):
                continue
            # Do not classify a service that has left the idle registry while
            # evidence was gathered, or a recycled PID/session.
            confirmed = xcode_registry_entries(read([str(tool), "--show-shared-memory"]))
            current = table.snapshot().get(proc.pid)
            if (confirmed.get(proc.pid) != pipes or current is None
                    or current.identity != proc.identity or current.ppid != 1
                    or current.pgid != proc.pid or os.getsid(proc.pid) != proc.pid
                    or Path(current.executable).resolve() != worker):
                continue
            accepted.add(proc.identity)
            evidence["registeredSharedWorkers"].append(dict(
                pid=proc.pid, birth=proc.birth, executable=proc.executable,
                registryProvider=str(tool), pipes=pipes,
                reason="Apple-signed external service; detached session; matching idle registry and open FIFOs"))
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        # Missing/changed/unsupported evidence never grants an exemption.
        evidence["errors"].append(str(error))
    finally:
        (Path(directory) / "shared-worker-evidence.json").write_text(
            json.dumps(evidence, indent=2) + "\n")
    return accepted


def positive_seconds(value):
    value = float(value)
    if not math.isfinite(value) or value <= 0:
        raise ValueError("Deadline must be finite and greater than zero")
    return value


def supervise(command, directory, timeout, *, environment=None,
              owned_executable_roots=(), terminate_grace=2.0, kill_grace=3.0):
    """Receipt is authoritative: ordinary child exit124 is NOT a timeout.

    Direct child is reaped. Tracked descendants / unique-product test hosts
    are terminated and confirmed absent, with PID reuse checked before signals.
    Cleanup remains bounded; any survivor is an infrastructure error, never PASS.
    """
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    receipt = {"command": list(command), "timeoutSeconds": timeout,
               "startedAt": time.time(), "status": "INFRASTRUCTURE ERROR",
               "signals": [], "ownedProcesses": [], "survivors": [],
               "childExit": None, "childReaped": False}
    child = None
    tracked = {}
    shared = set()
    roots = [Path(x).resolve() for x in owned_executable_roots]
    interrupted = []
    old_handlers = {}
    table = None

    def discover():
        snapshot = table.snapshot()
        return discover_owned(snapshot, tracked, child.pid if child else None,
                              child is not None and child.returncode is not None, roots, shared)

    def signal_owned(sig):
        live = discover()
        # The new session's group is exclusively ours. Check a live member's
        # kernel birth identity immediately before signalling the group.
        group_members = [p for p in live if p.pgid == child.pid]
        if group_members:
            current = table.snapshot()
            if any(current.get(p.pid) is not None
                   and current[p.pid].identity == p.identity
                   and current[p.pid].pgid == child.pid for p in group_members):
                try:
                    os.killpg(child.pid, sig)
                    receipt["signals"].append({"group": child.pid, "signal": sig})
                except ProcessLookupError:
                    pass
        for proc in live:
            if proc.pgid == child.pid:
                continue
            current = table.snapshot().get(proc.pid)
            if current is not None and current.identity == proc.identity:
                try:
                    os.kill(proc.pid, sig)
                    receipt["signals"].append({"pid": proc.pid, "birth": proc.birth, "signal": sig})
                except ProcessLookupError:
                    pass

    def await_cleanup(seconds):
        end = time.monotonic() + seconds
        while True:
            child.poll()  # Reap the direct child as soon as it exits.
            live = discover()
            if not live or time.monotonic() >= end:
                return live
            time.sleep(0.05)  # Supervisor bookkeeping, never an XCTest timing oracle.

    try:
        timeout = positive_seconds(timeout)
        table = ProcessTable()  # Fail before launch if ownership cannot be inspected.
        for sig in (signal.SIGTERM, signal.SIGINT):
            old_handlers[sig] = signal.signal(sig, lambda number, frame: interrupted.append(number))
        with (directory / "output.log").open("wb") as log:
            child = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT,
                                     env=environment, start_new_session=True)
            receipt["childPID"] = child.pid
            deadline = time.monotonic() + timeout
            while True:
                discover()
                code = child.poll()
                if code is not None:
                    receipt["status"] = "PASS" if code == 0 else "TEST FAILURE"
                    break
                if interrupted:
                    receipt["status"] = "INFRASTRUCTURE ERROR"
                    receipt["interruptedBy"] = interrupted[0]
                    break
                if time.monotonic() >= deadline:
                    receipt["status"] = "PROCESS TIMEOUT / HANG"
                    break
                time.sleep(min(0.1, max(0, deadline - time.monotonic())))
    except (OSError, ValueError, RuntimeError) as error:
        receipt["error"] = str(error)
    finally:
        if child is not None:
            try:
                live = discover()
                if live and receipt["status"] in ("PASS", "TEST FAILURE"):
                    shared.update(registered_xcode_workers(
                        live, table, child.pid, roots, directory, environment))
                    if shared:
                        receipt["externalSharedWorkers"] = [dict(pid=p.pid, birth=p.birth,
                            executable=p.executable) for p in live if p.identity in shared]
                        live = discover()
                if live:
                    receipt["cleanupRequired"] = True
                    # A nominally exited command leaving owned workers isn't a pass.
                    if receipt["status"] in ("PASS", "TEST FAILURE"):
                        receipt["status"] = "INFRASTRUCTURE ERROR"
                        receipt["error"] = "Child exited leaving owned processes"
                    signal_owned(signal.SIGTERM)
                    if await_cleanup(terminate_grace):
                        signal_owned(signal.SIGKILL)
                        receipt["survivors"] = [p.pid for p in await_cleanup(kill_grace)]
                receipt["childExit"] = child.wait(timeout=kill_grace)
                receipt["childReaped"] = True
                if receipt["survivors"]:
                    receipt["status"] = "INFRASTRUCTURE ERROR"
            except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
                receipt["status"] = "INFRASTRUCTURE ERROR"
                receipt["error"] = "Cleanup could not be verified: " + str(error)
        for sig, handler in old_handlers.items():
            signal.signal(sig, handler)
        receipt["ownedProcesses"] = [dict(pid=p.pid, ppid=p.ppid, pgid=p.pgid,
                                            birth=p.birth, executable=p.executable)
                                      for p in tracked.values()]
        receipt["finishedAt"] = time.time()
        status = receipt["status"]
        receipt["exitCode"] = (TIMEOUT_EXIT if status == "PROCESS TIMEOUT / HANG" else
                               INFRASTRUCTURE_EXIT if status == "INFRASTRUCTURE ERROR" else
                               max(0, receipt["childExit"]) if receipt["childExit"] >= 0 else
                               128 - receipt["childExit"])
        (directory / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    return receipt


def native_test_identity(directory, retained_identity=None):
    identity = retained_identity if retained_identity is not None else (
        "com.machelpnz.scratchlab.nativegate." + hashlib.sha256(str(directory).encode()).hexdigest()[:12])
    if not isinstance(identity, str) or not re.fullmatch(r"com\.machelpnz\.scratchlab\.nativegate\.[0-9a-f]{12}", identity):
        raise ValueError("Retained identity must be a dedicated nativegate bundle identifier")
    return identity


def native_invocation(project, mode, directory, only_testing=(), environment=None, *, retained_identity=None):
    policy = json.loads(POLICY_PATH.read_text())
    env = dict(os.environ if environment is None else environment)
    admitted = mode == "audio-integration"
    key = policy["environmentKey"]
    for name in (key, "TEST_RUNNER_" + key):
        env[name] = "1" if admitted else "0"  # Ambient opt-in cannot contaminate default all.
    for name in ("SCRATCHLAB_CAPTURE_OUTPUT", "TEST_RUNNER_SCRATCHLAB_CAPTURE_OUTPUT"):
        env[name] = "1" if admitted else "0"
    # Only the explicit integration mode enables the existing generated-output tap.
    selectors = list(only_testing) or (policy["integrationSelectors"] if admitted else [])
    products = directory / "Products"
    command = ["xcodebuild", "-project", str(project), "-scheme", "ScratchLabDesktop",
               "-destination", "platform=macOS", "-derivedDataPath", str(directory / "DerivedData"),
               "-resultBundlePath", str(directory / "tests.xcresult"),
               "SYMROOT=" + str(products), "OBJROOT=" + str(directory / "Intermediates"),
               "test"]
    identity = native_test_identity(directory, retained_identity)
    command.append("PRODUCT_BUNDLE_IDENTIFIER=" + identity)
    command.extend("-only-testing:ScratchLabDesktopTests/" + s for s in selectors)
    return command, env, products


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", type=Path, required=True)
    parser.add_argument("--mode", choices=["software", "audio-integration"], default="software")
    parser.add_argument("--timeout", type=positive_seconds)
    parser.add_argument("--evidence-root", type=Path, default=Path("/private/tmp/scratchlab-native-gates"))
    parser.add_argument("--only-testing", action="append", default=[])
    args = parser.parse_args()
    policy = json.loads(POLICY_PATH.read_text())
    timeout_key = "SCRATCHLAB_AUDIO_INTEGRATION_TIMEOUT_SECONDS" if args.mode == "audio-integration" else "SCRATCHLAB_NATIVE_TEST_TIMEOUT_SECONDS"
    default = policy["audioIntegrationTimeoutSeconds" if args.mode == "audio-integration" else "softwareTimeoutSeconds"]
    timeout = positive_seconds(args.timeout if args.timeout is not None else os.environ.get(timeout_key, default))
    args.evidence_root.mkdir(parents=True, exist_ok=True)
    prepared = os.environ.get("SCRATCHLAB_NATIVE_PREFLIGHT_CONTEXT")
    retained_identity = None
    if prepared:
        from native_repository_preflight import prepared_context
        if args.mode != "software" or args.only_testing:
            raise ValueError("Prepared repository context is only for a complete software gate")
        directory = prepared_context(args.project.resolve(), Path(prepared))
        retained_identity = json.loads((directory / "preflight-context.json").read_text())["identity"]
    else:
        directory = Path(tempfile.mkdtemp(prefix=args.mode + "-", dir=args.evidence_root)).resolve()
    command, env, products = native_invocation(args.project.resolve(), args.mode, directory, args.only_testing,
                                               retained_identity=retained_identity)
    (directory / "invocation.json").write_text(json.dumps({"mode": args.mode, "command": command,
        "timeoutSeconds": timeout, "integrationAdmission": env[policy["environmentKey"]]}, indent=2) + "\n")
    print(f"Native test supervisor: {args.mode}, deadline {timeout:g}s; evidence {directory}", flush=True)
    receipt = supervise(command, directory, timeout, environment=env, owned_executable_roots=[products])
    print(f"Native gate: {receipt['status']} (exit {receipt['exitCode']}); {directory / 'receipt.json'}", flush=True)
    print("Real-device integration is separate from software verification; neither proves physical hardware acceptance.", flush=True)
    return receipt["exitCode"]


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError) as error:
        print(f"Native gate: INFRASTRUCTURE ERROR: {error}", file=sys.stderr)
        sys.exit(INFRASTRUCTURE_EXIT)
