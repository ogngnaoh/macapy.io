#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    printf '%s\n' 'Usage: scripts/package-release.sh <archive-output-directory> [local|developer-id|notarized]' >&2
    exit 2
fi
output="$(cd "$1" && pwd)"
mode="${2:-local}"
case "$mode" in local|developer-id|notarized) ;; *) exit 2 ;; esac
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
unset MACAPY_DEEPSEEK_KEY MACAPY_RUN_LIVE_PROVIDER_TESTS MACAPY_RUN_LOCAL_MODEL_TESTS

app="$output/macapy.xcarchive/Products/Applications/macapy.app"
if [ -d "$output/export/macapy.app" ]; then app="$output/export/macapy.app"; fi
python3 scripts/release-metadata.py verify-source --source "$output/source.json"
python3 scripts/verify-release.py "$app" --source "$output/source.json" --mode "$mode" --output "$output/bundle-verification.json"
package_name="$(python3 - "$app/Contents/Info.plist" "$mode" <<'PY'
import plistlib, re, sys
with open(sys.argv[1], 'rb') as file:
    info = plistlib.load(file)
parts = [str(info['CFBundleShortVersionString']), str(info['CFBundleVersion']), sys.argv[2]]
if not all(re.fullmatch(r'[A-Za-z0-9._-]+', part) for part in parts):
    raise SystemExit('Unsafe package metadata')
print('macapy-' + '-'.join(parts) + '-arm64.zip')
PY
)"
artifact="$output/$package_name"
if [ -e "$artifact" ]; then
    printf '%s\n' 'Package already exists; rebuild into a new output directory.' >&2
    exit 2
fi
ditto -c -k --sequesterRsrc --keepParent "$app" "$artifact"
python3 scripts/release-metadata.py manifest --source "$output/source.json" \
    --app "$app" --artifact "$artifact" --verification "$output/bundle-verification.json" \
    --output "$output/release-manifest.json"
(cd "$output" && shasum -a 256 "$package_name" > SHA256SUMS)
printf '%s\n' "Local package: $artifact" "Manifest: $output/release-manifest.json" 'Nothing was uploaded or published.'
