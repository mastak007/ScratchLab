#!/usr/bin/env python3
"""Stage a universal CXL update without downgrading its verified signature.

This never installs, launches, changes permissions, or modifies the source app.
Unmodified bundles retain their original signature. Resource removal requires
explicit re-signing with the source entitlements, requirements and options.
"""

import argparse
import hashlib
import json
import pathlib
import plistlib
import re
import shutil
import subprocess

EXPECTED_BUNDLE = "com.machelpnz.scratchlab.cxl-authoring"
RUNTIME_FLAG = 0x10000


def run(*args):
    result = subprocess.run(args, capture_output=True)
    if result.returncode:
        raise RuntimeError(result.stderr.decode().strip() or f"{args[0]} failed")
    return result.stdout


def signature(app):
    result = subprocess.run(
        ["/usr/bin/codesign", "-dvv", str(app)], check=True, capture_output=True
    )
    return result.stderr.decode()


def content_manifest(app):
    """Include nested code, resource seals and symlink targets without following them."""
    return {str(p.relative_to(app)): (
        {"symlink": str(p.readlink())} if p.is_symlink() else
        {"sha256": hashlib.sha256(p.read_bytes()).hexdigest()}
    ) for p in sorted(app.rglob("*")) if p.is_symlink() or p.is_file()}


def signing_contract(app, expected_team):
    # --deep is verification only: nested code is never blindly re-signed.
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", str(app))
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    signed = signature(app)
    flags = re.search(r"\bflags=(0x[0-9a-fA-F]+)\(", signed)
    if not flags or info.get("CFBundleIdentifier") != EXPECTED_BUNDLE:
        raise RuntimeError("Candidate rejected: missing flags or wrong bundle identity.")
    if ("Signature=adhoc" in signed or
            f"TeamIdentifier={expected_team}\n" not in signed or
            "Authority=Apple " not in signed or "Authority=Apple Root CA" not in signed):
        raise RuntimeError("Candidate rejected: expected Apple signing identity not verified.")
    executable = info.get("CFBundleExecutable", "")
    if not executable or pathlib.Path(executable).name != executable:
        raise RuntimeError("Candidate rejected: invalid executable name.")
    binary = app / "Contents/MacOS" / executable
    if not binary.is_file() or binary.is_symlink():
        raise RuntimeError("Candidate rejected: executable missing or redirected.")
    architectures = sorted(run("/usr/bin/lipo", "-archs", str(binary)).decode().split())
    if architectures != ["arm64", "x86_64"]:
        raise RuntimeError("Candidate rejected: both Mac architectures are required.")
    entitlements = plistlib.loads(run(
        "/usr/bin/codesign", "-d", "--entitlements", ":-", str(app)))
    requirement_result = subprocess.run(
        ["/usr/bin/codesign", "-d", "-r-", str(app)], check=True, capture_output=True)
    lines = (requirement_result.stdout + requirement_result.stderr).decode().splitlines()
    requirements = [line for line in lines if line.startswith("designated => ")]
    if len(requirements) != 1 or "anchor apple" not in requirements[0] or EXPECTED_BUNDLE not in requirements[0]:
        raise RuntimeError("Candidate rejected: designated requirement not verified.")
    return dict(info=info, flags=int(flags.group(1), 16), entitlements=entitlements,
                architectures=architectures, designatedRequirement=requirements[0],
                authorities=[line for line in signed.splitlines() if line.startswith("Authority=")],
                teamIdentifier=expected_team, signature=signed,
                executableSHA256=hashlib.sha256(binary.read_bytes()).hexdigest())


def validate_equivalence(source, staged):
    if source["flags"] & RUNTIME_FLAG and not staged["flags"] & RUNTIME_FLAG:
        raise RuntimeError("Candidate rejected: Hardened Runtime was removed.")
    for key in ("flags", "entitlements", "info", "architectures",
                "designatedRequirement", "authorities", "teamIdentifier"):
        if staged[key] != source[key]:
            raise RuntimeError(f"Candidate rejected: source {key} changed.")


def stage(built_app, installed_app, output, identity, expected_team, exclude_reference_examples=False):
    if output.exists() or output.is_symlink():
        raise RuntimeError("Output already exists; choose a new staging location.")
    for protected in (built_app, installed_app):
        if output.resolve().is_relative_to(protected.resolve()):
            raise RuntimeError("Output must be outside source and installed bundles.")
    before = content_manifest(built_app)
    source = signing_contract(built_app, expected_team)
    original = plistlib.loads((installed_app / "Contents/Info.plist").read_bytes())
    if original.get("CFBundleIdentifier") != EXPECTED_BUNDLE:
        raise RuntimeError("Installed bundle identity differs.")
    permission_keys = {k for info in (original, source["info"]) for k in info
                       if k.endswith("UsageDescription") or k == "NSBonjourServices"}
    for key in permission_keys | {"CFBundleExecutable"}:
        if original.get(key) != source["info"].get(key):
            raise RuntimeError(f"Installed identity/permission metadata differs: {key}")
    installed_signature = signature(installed_app)
    if f"TeamIdentifier={expected_team}\n" not in installed_signature:
        raise RuntimeError("Installed app signing team differs.")
    installed_entitlements = plistlib.loads(run(
        "/usr/bin/codesign", "-d", "--entitlements", ":-", str(installed_app)))
    for key, value in installed_entitlements.items():
        if source["entitlements"].get(key) != value:
            raise RuntimeError(f"Verified source does not retain installed entitlement: {key}")
    output.parent.mkdir(parents=True, exist_ok=True)
    run("/usr/bin/ditto", str(built_app), str(output))
    examples = output / "Contents/Resources/ReferenceExamples"
    resigned = exclude_reference_examples and examples.exists()
    if resigned:
        if examples.is_symlink():
            raise RuntimeError("Refusing redirected reference resources.")
        shutil.rmtree(examples)
        entitlement_path = output.with_suffix(".entitlements.plist")
        entitlement_path.write_bytes(plistlib.dumps(source["entitlements"]))
        # Only the outer resource seal changed. Keep nested signatures intact.
        run("/usr/bin/codesign", "--force", "--sign", identity,
            "--preserve-metadata=identifier,requirements,flags,runtime",
            "--options", hex(source["flags"]), "--entitlements", str(entitlement_path),
            "--timestamp", str(output))
    staged = signing_contract(output, expected_team)
    validate_equivalence(source, staged)
    after = content_manifest(output)
    if not resigned and after != before:
        raise RuntimeError("Candidate rejected: unmodified staging changed bundle contents.")
    if resigned:
        # Re-signing may change only the main signature and resource seal, plus
        # the explicitly excluded examples. Nested code/resources must be exact.
        allowed = {"Contents/MacOS/" + source["info"]["CFBundleExecutable"],
                   "Contents/_CodeSignature/CodeResources"}
        keep = lambda p: p not in allowed and not p.startswith("Contents/Resources/ReferenceExamples/")
        if {p: v for p, v in before.items() if keep(p)} != {p: v for p, v in after.items() if keep(p)}:
            raise RuntimeError("Candidate rejected: unexpected resource or nested code change.")
    if content_manifest(built_app) != before:
        raise RuntimeError("Candidate rejected: source bundle changed during staging.")
    receipt = dict(app=str(output.resolve()), sourceApp=str(built_app.resolve()),
                   bundleIdentifier=EXPECTED_BUNDLE, teamIdentifier=expected_team,
                   reSigned=resigned, requestedSigningIdentitySHA1=identity,
                   executableSHA256=staged["executableSHA256"],
                   source=source, staged=staged, sourceContentUnchanged=True,
                   exactBundleCopy=not resigned, nestedCodeVerification="PASS",
                   resourceVerification="PASS", stagingValid=True)
    output.with_suffix(".receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--built-app", required=True, type=pathlib.Path)
    parser.add_argument("--installed-app", required=True, type=pathlib.Path)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--identity", required=True, help="Apple certificate SHA-1, used only if resources change")
    parser.add_argument("--expected-team", default="2DDKGL33BU")
    parser.add_argument("--exclude-reference-examples", action="store_true")
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9a-fA-F]{40}", args.identity):
        parser.error("Use an Apple-issued certificate SHA-1; ad hoc signing is forbidden.")
    if not re.fullmatch(r"[A-Za-z0-9]{10}", args.expected_team):
        parser.error("Expected team must be a ten-character Apple team identifier.")
    print(json.dumps(stage(args.built_app, args.installed_app, args.output,
                           args.identity, args.expected_team, args.exclude_reference_examples), indent=2))


if __name__ == "__main__":
    main()
