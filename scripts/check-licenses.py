#!/usr/bin/env python3
"""Offline notice/provenance drift guard; this is an inventory check, not legal clearance."""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import sys


def check_licenses(root: Path, strict_release: bool = False) -> tuple[list[str], list[str]]:
    errors, pending = [], []
    try:
        inventory = json.loads((root / 'scripts/license-inventory.json').read_text())
        pins = {p['identity']: p['state']['revision'] for p in json.loads((root / 'Package.resolved').read_text())['pins']}
        notices = ' '.join((root / 'THIRD_PARTY_NOTICES.md').read_text().split())
        if pins != inventory['pins']:
            errors.append('Dependency revisions changed; refresh the exact license inventory and public notices')
        for revision in pins.values():
            if revision not in notices:
                errors.append('A resolved dependency revision is missing from public notices')
        for notice in inventory['notices']:
            path = root / notice['path']
            # A fresh clone may not have resolved checkouts yet. Retained public
            # notices are still required; a resolved checkout is checked exactly.
            if not path.exists() and notice['path'].startswith('.build/checkouts/'):
                continue
            if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != notice['sha256']:
                errors.append(f"License text changed or missing: {notice['path']}")
            elif ' '.join(path.read_text().split()) not in notices:
                errors.append(f"Full license text is not retained in public notices: {notice['path']}")
        indexed = {asset['path'] for asset in inventory['assets']}
        required = {p.relative_to(root).as_posix() for pattern in ['Tests/**/Fixtures/*.wav', 'Sources/**/Resources/**/*.ttf', 'Sources/**/Resources/**/*.otf'] for p in root.glob(pattern)}
        for name in sorted(required - indexed):
            errors.append(f'Uninventoried audio/font asset: {name}')
        for asset in inventory['assets']:
            path = root / asset['path']
            if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != asset['sha256']:
                errors.append(f"Asset changed or missing; update provenance review: {asset['path']}")
            if asset['status'].endswith('-pending'):
                pending.append(f"{asset['path']}: {asset['status']}")
        for asset in inventory.get('removed_audio', []):
            if (root / asset['path']).exists():
                errors.append(f"Excluded historical audio reappeared in public source: {asset['path']}")
        pending.extend(inventory['pending_release_reviews'])
        if strict_release and pending:
            errors.append('Release provenance review is incomplete; pending inventory items require resolution')
    except (OSError, ValueError, KeyError):
        errors.append('Cannot validate required license/provenance inventory')
    return errors, pending


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument('--release', action='store_true', help='Fail if any provenance review remains pending')
    args = parser.parse_args()
    errors, pending = check_licenses(args.root.resolve(), args.release)
    for message in errors:
        print(f'ERROR: {message}', file=sys.stderr)
    for message in pending:
        print(f'PENDING: {message}')
    if not errors:
        print('License inventory matches current pins/assets/notices. Pending items are not clearance.')
    return bool(errors)

if __name__ == '__main__':
    raise SystemExit(main())
