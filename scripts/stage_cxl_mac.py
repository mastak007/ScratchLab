#!/usr/bin/env python3
"""Stage a universal CXL update with a stable Apple-issued signing identity.

This never installs, launches, changes permissions, or modifies the source app.
Use the same team and bundle identifier for subsequent CXL updates.
"""

import argparse
import hashlib
import json
import pathlib
import plistlib
import subprocess


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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--built-app", required=True, type=pathlib.Path)
    parser.add_argument("--installed-app", required=True, type=pathlib.Path)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--identity", required=True, help="Apple-issued certificate SHA-1")
    parser.add_argument("--expected-team", default="2DDKGL33BU")
    parser.add_argument("--exclude-reference-examples", action="store_true",
                        help="Omit the optional full-app reference library from the CXL bundle.")
    args = parser.parse_args()
    if len(args.identity) != 40 or any(c not in "0123456789abcdefABCDEF" for c in args.identity):
        parser.error("Use an Apple-issued certificate SHA-1; ad hoc signing is forbidden.")
    if len(args.expected_team) != 10 or not args.expected_team.isalnum():
        parser.error("Expected team must be a ten-character Apple team identifier.")
    if args.output.exists():
        parser.error("Output already exists; choose a new staging location.")

    info_path = pathlib.Path("Contents/Info.plist")
    original = plistlib.loads((args.installed_app / info_path).read_bytes())
    built = plistlib.loads((args.built_app / info_path).read_bytes())
    expected_bundle = "com.machelpnz.scratchlab.cxl-authoring"
    if original["CFBundleIdentifier"] != expected_bundle or built["CFBundleIdentifier"] != expected_bundle:
        parser.error("Both apps must have the existing CXL bundle identifier.")
    permission_keys = {k for info in (original, built) for k in info
                       if k.endswith("UsageDescription") or k == "NSBonjourServices"}
    for key in permission_keys | {"CFBundleExecutable"}:
        if original.get(key) != built.get(key):
            parser.error(f"Installed identity/permission metadata differs: {key}")
    installed_signature = signature(args.installed_app)
    teams = [line.split("=", 1)[1] for line in installed_signature.splitlines()
             if line.startswith("TeamIdentifier=")]
    if teams and teams[0] not in ("not set", args.expected_team):
        parser.error("The installed app belongs to a different signing team.")
    entitlements = run("/usr/bin/codesign", "-d", "--entitlements", ":-", str(args.installed_app))
    installed_entitlements = plistlib.loads(entitlements)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    run("/usr/bin/ditto", str(args.built_app), str(args.output))
    if args.exclude_reference_examples:
        examples = args.output / "Contents/Resources/ReferenceExamples"
        if examples.exists():
            import shutil
            shutil.rmtree(examples)
    entitlement_path = args.output.with_suffix(".entitlements.plist")
    entitlement_path.write_bytes(plistlib.dumps(installed_entitlements))
    # Apple's default Development requirement can pin the certificate CN.
    # Bind to our existing team and bundle instead, including across renewal.
    designated = (f'designated => identifier "{expected_bundle}" and anchor apple generic '
                  f'and certificate leaf[subject.OU] = "{args.expected_team}" '
                  'and certificate 1[field.1.2.840.113635.100.6.2.1] exists')
    run("/usr/bin/codesign", "--force", "--deep", "--sign", args.identity,
        "--entitlements", str(entitlement_path), "--requirements", "=" + designated,
        "--timestamp", str(args.output))
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", str(args.output))
    signed = signature(args.output)
    if "Signature=adhoc" in signed or f"TeamIdentifier={args.expected_team}\n" not in signed:
        raise RuntimeError("Candidate rejected: stable signing team was not verified.")
    if "Authority=Apple " not in signed or "Authority=Apple Root CA" not in signed:
        raise RuntimeError("Candidate rejected: Apple certificate chain was not verified.")
    actual_entitlements = plistlib.loads(run(
        "/usr/bin/codesign", "-d", "--entitlements", ":-", str(args.output)))
    if actual_entitlements != installed_entitlements:
        raise RuntimeError("Candidate rejected: entitlements changed.")
    binary = args.output / "Contents/MacOS" / built["CFBundleExecutable"]
    architectures = run("/usr/bin/lipo", "-archs", str(binary)).decode().split()
    if set(architectures) != {"arm64", "x86_64"}:
        raise RuntimeError("Candidate rejected: both Mac architectures are required.")
    requirement_result = subprocess.run(["/usr/bin/codesign", "-d", "-r-", str(args.output)],
                                        check=True, capture_output=True)
    requirement = (requirement_result.stdout + requirement_result.stderr).decode()
    if "anchor apple" not in requirement or args.expected_team not in requirement:
        raise RuntimeError("Candidate rejected: designated requirement lacks Apple/team identity.")
    receipt = dict(app=str(args.output.resolve()), bundleIdentifier=expected_bundle,
                   teamIdentifier=args.expected_team, signingIdentitySHA1=args.identity,
                   executableSHA256=hashlib.sha256(binary.read_bytes()).hexdigest(),
                   architectures=architectures, designatedRequirement=requirement,
                   permissionMetadataPreserved=True, entitlementsPreserved=True,
                   signature=signed)
    args.output.with_suffix(".receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(receipt, indent=2))


if __name__ == "__main__":
    main()
