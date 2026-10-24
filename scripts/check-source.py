#!/usr/bin/env python3
"""Offline source/publication checks. Diagnostics name rules, never matched secrets."""
from __future__ import annotations

import argparse
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import unquote, urlsplit


LOCK_PATHS = (
    "Package.resolved",
    "macapy.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
)
SECRET_PATTERNS = {
    "private-key material": r"-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----",
    "GitHub token": r"\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{50,})\b",
    "AWS access key": r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b",
    "provider token": r"\bsk-(?:proj-[A-Za-z0-9_-]{30,}|[a-fA-F0-9]{32,})\b",
    "Slack token": r"\bxox[baprs]-[A-Za-z0-9-]{20,}\b",
}


def run(root: Path, *args: str) -> str:
    return subprocess.check_output(args, cwd=root, text=True, stderr=subprocess.DEVNULL)


def public_files(root: Path) -> list[Path]:
    # Includes new authoring work but excludes ignored docs/build output. A dirty
    # working tree is expected while preparing a local candidate, never an error.
    names = run(root, "git", "ls-files", "-z", "--cached", "--others", "--exclude-standard").split("\0")
    return sorted({root / name for name in names if name and (root / name).is_file()})


def check_text(relative: str, text: str) -> list[str]:
    errors = []
    for name, pattern in SECRET_PATTERNS.items():
        for match in re.finditer(pattern, text):
            # The intentionally rejected canary in the live auth test is public
            # synthetic data. Do not exempt whole test files from secret checks.
            if name == "provider token" and set(match.group()[3:]) == {"0"}:
                continue
            line = text.count("\n", 0, match.start()) + 1
            errors.append(f"{relative}:{line}: possible {name} (value omitted)")
    if re.search(r"/Users/[A-Za-z0-9._-]+/", text):
        errors.append(f"{relative}: author-specific absolute path")
    return errors


def check_markdown(root: Path, path: Path, text: str) -> list[str]:
    errors = []
    # Fenced code examples are documentation, not links that the renderer loads.
    text = re.sub(r"```.*?```", "", text, flags=re.S)
    for match in re.finditer(r"!?\[[^\]\n]*\]\((<[^>]+>|[^\s)]+)(?:\s+[^)]*)?\)", text):
        target = match.group(1).strip("<>")
        parsed = urlsplit(target)
        if parsed.scheme or target.startswith(("#", "//")):
            continue  # Remote URLs are not fetched during offline verification.
        link_path = unquote(parsed.path)
        destination = (path.parent / link_path).resolve()
        try:
            relative = destination.relative_to(root.resolve())
        except ValueError:
            errors.append(f"{path.relative_to(root)}: link escapes repository")
            continue
        if relative.parts and relative.parts[0] == "docs":
            errors.append(f"{path.relative_to(root)}: public link targets private docs/")
        elif not destination.exists():
            errors.append(f"{path.relative_to(root)}: missing local link target {relative}")
    return errors


def normalized_pins(data: dict) -> dict:
    return {pin["identity"]: {k: pin[k] for k in ("kind", "location", "state")} for pin in data["pins"]}


def check_locks(root: Path) -> list[str]:
    errors = []
    try:
        locks = [normalized_pins(json.loads((root / name).read_text())) for name in LOCK_PATHS]
    except (OSError, ValueError, KeyError):
        return ["Dependency lockfiles must both exist and contain valid pins"]
    if locks[0] != locks[1]:
        errors.append("Root and Xcode dependency pins differ (originHash is intentionally context-specific)")
    state_path = root / ".build/workspace-state.json"
    if state_path.exists():
        try:
            dependencies = json.loads(state_path.read_text())["object"]["dependencies"]
            actual = {
                dependency["packageRef"]["identity"]: dependency["state"]["checkoutState"]["revision"]
                for dependency in dependencies
            }
            expected = {name: pin["state"]["revision"] for name, pin in locks[0].items()}
            if actual != expected:
                errors.append("Resolved SwiftPM checkouts differ from Package.resolved")
        except (ValueError, KeyError):
            errors.append("Cannot verify resolved SwiftPM workspace-state schema")
    return errors


def check_production_graph(package: dict) -> list[str]:
    targets = {target["name"]: target for target in package["targets"]}
    roots = [name for product in package["products"] for name in product["targets"]]
    visited: set[str] = set()
    pending = list(roots)
    while pending:
        name = pending.pop()
        if name in visited:
            continue
        visited.add(name)
        if name == "ProviderTestSupport" or targets.get(name, {}).get("type") == "test":
            return [f"Production product reaches test-only target {name}"]
        for dependency in targets.get(name, {}).get("dependencies", []):
            # PackageDescription dump shape: target/byName are local edges;
            # external product edges cannot point into this package's tests.
            for kind in ("target", "byName"):
                if kind in dependency:
                    pending.append(dependency[kind][0])
    return []


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--package-json", type=Path, help="Use an existing swift package dump-package result")
    options = parser.parse_args()
    root = options.root.resolve()
    errors = []
    if run(root, "git", "ls-files", "--", "docs").strip():
        errors.append("Private docs/ entries remain in the Git index")
    ignored = run(root, "git", "check-ignore", "-v", "docs/source-check-probe.md")
    if not re.match(r"\.gitignore:\d+:/docs/\t", ignored):
        errors.append("docs/ must be ignored by the root /docs/ rule")
    files = public_files(root)
    for path in files:
        relative = path.relative_to(root).as_posix()
        if path.is_symlink():
            try:
                path.resolve().relative_to(root)
            except ValueError:
                errors.append(f"{relative}: symlink escapes repository")
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeError:
            continue  # Binary media provenance is checked separately at release review.
        errors.extend(check_text(relative, text))
        # Internal agent guidance may refer to ignored docs; public reader docs may not.
        if path.suffix == ".md" and relative not in {"AGENTS.md", "CLAUDE.md"}:
            errors.extend(check_markdown(root, path, text))
    errors.extend(check_locks(root))
    license_spec = importlib.util.spec_from_file_location("license_checks", Path(__file__).with_name("check-licenses.py"))
    license_checks = importlib.util.module_from_spec(license_spec)
    license_spec.loader.exec_module(license_checks)
    license_errors, pending_reviews = license_checks.check_licenses(root)
    errors.extend(license_errors)
    try:
        package = json.loads(options.package_json.read_text() if options.package_json else run(root, "swift", "package", "dump-package"))
        errors.extend(check_production_graph(package))
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError):
        errors.append("Unable to inspect package graph; run with a configured Xcode toolchain")
    if errors:
        for error in sorted(set(errors)):
            print(f"ERROR: {error}", file=sys.stderr)
        return 1
    print(f"Source checks passed: {len(files)} public files, matching dependency pins, isolated production graph.")
    if pending_reviews:
        print(f"License inventory: {len(pending_reviews)} pending review items; inspect scripts/check-licenses.py output before a release claim.")
    print("Scope: current index/worktree and local links; remote history, hosted rendering, and binary provenance require separate review.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
