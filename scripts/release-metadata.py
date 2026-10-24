#!/usr/bin/env python3
"""Record local release provenance without claiming dirty sources are a Git release."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import subprocess

spec = importlib.util.spec_from_file_location("source_checks", Path(__file__).with_name("check-source.py"))
checks = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checks)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def snapshot(root: Path) -> dict:
    files = []
    for path in checks.public_files(root):
        relative = path.relative_to(root).as_posix()
        if path.is_symlink():
            raise ValueError("Release sources cannot contain symlinks")
        files.append({"path": relative, "sha256": sha256(path)})
    canonical = json.dumps(files, sort_keys=True, separators=(",", ":")).encode()
    return {
        "head_commit": checks.run(root, "git", "rev-parse", "HEAD").strip(),
        "head_tree": checks.run(root, "git", "rev-parse", "HEAD^{tree}").strip(),
        "has_local_changes": bool(checks.run(root, "git", "status", "--porcelain", "--untracked-files=normal").strip()),
        "public_source_sha256": hashlib.sha256(canonical).hexdigest(),
        "dependency_lockfile_sha256": {name: sha256(root / name) for name in checks.LOCK_PATHS},
        "files": files,
    }


def write_json(path: Path, value: dict) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["snapshot", "verify-source", "manifest"])
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--app", type=Path)
    parser.add_argument("--artifact", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--verification", type=Path)
    args = parser.parse_args()
    root = args.root.resolve()
    current = snapshot(root)
    if args.command == "snapshot":
        write_json(args.source, current)
        return 0
    captured = json.loads(args.source.read_text())
    if current != captured:
        raise ValueError("Source changed after archive began; rebuild before packaging")
    if args.command == "verify-source":
        print("Archive provenance matches current public source snapshot.")
        return 0
    if not all([args.app, args.artifact, args.output, args.verification]):
        parser.error("manifest requires --app, --artifact, --output, and --verification")
    info = plistlib.loads((args.app / "Contents/Info.plist").read_bytes())
    verification = json.loads(args.verification.read_text())
    notarization = {"status": "not-submitted", "submission_id": None}
    receipt = args.source.parent / "notarization.json"
    if receipt.exists():
        submission = json.loads(receipt.read_text())
        notarization = {"status": submission.get("status"), "submission_id": submission.get("id")}
    value = {
        "schema_version": 1,
        "created_utc": datetime.now(timezone.utc).isoformat(),
        "status": "local-review-candidate",
        "source": captured,
        "bundle": {
            "identifier": info["CFBundleIdentifier"],
            "version": info["CFBundleShortVersionString"],
            "build": info["CFBundleVersion"],
            "minimum_macos": info["LSMinimumSystemVersion"],
        },
        "toolchain": {
            "xcode": checks.run(root, "xcodebuild", "-version").strip(),
            "sdk": checks.run(root, "xcrun", "--sdk", "macosx", "--show-sdk-version").strip(),
        },
        "verification": verification,
        "notarization": notarization,
        "artifacts": [{"name": args.artifact.name, "bytes": args.artifact.stat().st_size, "sha256": sha256(args.artifact)}],
        "publication": {"published": False, "tag": None, "release_notes_verified": False},
    }
    write_json(args.output, value)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"Release metadata failed: {type(error).__name__}: {error}")
