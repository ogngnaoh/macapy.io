#!/usr/bin/env python3
"""Inspect a macapy bundle locally; no credentials, uploads, or launches."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess


def command(*args: str) -> tuple[int, str]:
    result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    return result.returncode, result.stdout


def validate_metadata(info: dict) -> list[str]:
    errors = []
    for key in ("CFBundleIdentifier", "CFBundleExecutable", "CFBundleShortVersionString", "CFBundleVersion", "LSMinimumSystemVersion"):
        value = info.get(key)
        if not isinstance(value, str) or not value.strip() or "$(" in value:
            errors.append(f"Missing or unresolved bundle key {key}")
    if info.get("CFBundleIdentifier") != "io.macapy.app":
        errors.append("Unexpected bundle identifier")
    if not info.get("NSMicrophoneUsageDescription") or not info.get("NSAudioCaptureUsageDescription"):
        errors.append("Capture privacy descriptions are missing")
    for key in ("NSCalendarsWriteOnlyAccessUsageDescription", "NSCalendarsFullAccessUsageDescription", "NSRemindersFullAccessUsageDescription"):
        value = info.get(key)
        if not isinstance(value, str) or not value.strip():
            errors.append(f"Missing EventKit privacy description {key}")
    return errors


def validate_entitlements(values: dict) -> list[str]:
    errors = []
    if values.get("com.apple.security.device.audio-input") is not True:
        errors.append("Hardened capture requires the Audio Input entitlement")
    for key in [
        "com.apple.security.get-task-allow",
        "com.apple.security.cs.disable-library-validation",
        "com.apple.security.cs.allow-unsigned-executable-memory",
    ]:
        if values.get(key):
            errors.append(f"Unsafe release entitlement {key}")
    return errors


def validate_notices(app: Path, source: dict | None = None) -> list[str]:
    errors = []
    expected = {item['path']: item['sha256'] for item in source.get('files', [])} if source else {}
    for name in ('LICENSE', 'THIRD_PARTY_NOTICES.md'):
        path = app / 'Contents/Resources' / name
        if not path.is_file() or path.is_symlink() or not path.stat().st_size:
            errors.append(f'Required license notice missing from bundle resources: {name}')
        elif source is not None and (name not in expected or hashlib.sha256(path.read_bytes()).hexdigest() != expected[name]):
            errors.append(f'Bundled license notice differs from captured source: {name}')
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--mode", choices=["local", "developer-id", "notarized"], default="local")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--source", type=Path, help="Captured release source.json; verifies exact bundled notice hashes")
    args = parser.parse_args()
    app = args.app.resolve()
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    errors = validate_metadata(info)
    source = json.loads(args.source.read_text()) if args.source else None
    errors.extend(validate_notices(app, source))
    executable = app / "Contents/MacOS" / info.get("CFBundleExecutable", "missing")
    status, architecture = command("lipo", "-archs", str(executable))
    if status or architecture.strip() != "arm64":
        errors.append("Main executable must contain exactly the arm64 architecture")
    forbidden = []
    macho_headers = {bytes.fromhex(value) for value in ["feedface", "cefaedfe", "feedfacf", "cffaedfe", "cafebabe", "bebafeca", "cafebabf", "bfbafeca"]}
    for path in app.rglob("*"):
        relative = path.relative_to(app).as_posix()
        if any(part in {"docs", "Tests", "Fixtures", ".git"} for part in path.relative_to(app).parts) or "ProviderTestSupport" in path.name:
            forbidden.append(relative)
        if path.is_file() and not path.is_symlink():
            with path.open("rb") as file:
                header = file.read(4)
            if header in macho_headers:
                embedded_status, embedded_architecture = command("lipo", "-archs", str(path))
                if embedded_status or embedded_architecture.strip() != "arm64":
                    errors.append(f"Embedded executable must contain exactly arm64: {relative}")
    if forbidden:
        errors.append("Bundle includes test/private material: " + ", ".join(forbidden[:8]))
    status, symbols = command("nm", "-a", str(executable))
    if status == 0 and "ProviderTestSupport" in symbols:
        errors.append("Production executable contains ProviderTestSupport symbols")
    status, signature = command("codesign", "-d", "--verbose=4", str(app))
    developer_id = status == 0 and "Authority=Developer ID Application:" in signature
    hardened = bool(re.search(r"flags=.*\bruntime\b", signature))
    signature_status = "unsigned" if status else ("developer-id" if developer_id else "ad-hoc-or-other")
    if args.mode != "local":
        if not developer_id or not hardened:
            errors.append("Developer ID release requires Developer ID Application signing and hardened runtime")
        if command("codesign", "--verify", "--deep", "--strict", str(app))[0]:
            errors.append("Bundle signature verification failed")
        entitlement_status, entitlements = command("codesign", "-d", "--entitlements", ":-", str(app))
        try:
            plist_start = entitlements.find("<?xml")
            values = plistlib.loads(entitlements[plist_start:].encode()) if plist_start >= 0 else {}
            if entitlement_status:
                errors.append("Unreadable release entitlements")
            errors.extend(validate_entitlements(values))
        except (ValueError, plistlib.InvalidFileException):
            errors.append("Could not parse signed entitlements")
    notarization = "not-checked"
    if args.mode == "notarized":
        # stapler validation inspects the local ticket. The online Gatekeeper
        # assessment is a separate authorized clean-machine release check.
        if command("xcrun", "stapler", "validate", str(app))[0]:
            errors.append("No valid stapled notarization ticket")
        else:
            notarization = "stapled-ticket-valid"
    result = {
        "mode": args.mode, "architecture": architecture.strip(),
        "signature": signature_status, "hardened_runtime": hardened,
        "notarization": notarization, "gatekeeper_clean_install": "pending",
        "license_notices": "source-hash-checked" if source is not None else "presence-checked",
        "passed": not errors, "errors": errors,
    }
    if args.output:
        args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    for error in errors:
        print("ERROR: " + error)
    print(f"Bundle inspection: {'passed' if not errors else 'failed'} ({args.mode}; {signature_status}; notarization {notarization}).")
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
