#!/bin/bash
set -euo pipefail

# Explicit opt-in: this contacts Apple and uses the caller's previously created
# notarytool Keychain profile. It never prints or exports stored credentials.
if [ "${MACAPY_ALLOW_NOTARIZATION:-}" != 1 ] || [ -z "${MACAPY_NOTARY_PROFILE:-}" ] || [ "$#" -ne 1 ]; then
    printf '%s\n' 'Usage: MACAPY_ALLOW_NOTARIZATION=1 MACAPY_NOTARY_PROFILE=<profile-name> scripts/notarize-release.sh <archive-output-directory>' >&2
    exit 2
fi
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
output="$(cd "$1" && pwd)"
app="$output/export/macapy.app"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
unset MACAPY_DEEPSEEK_KEY MACAPY_RUN_LIVE_PROVIDER_TESTS MACAPY_RUN_LOCAL_MODEL_TESTS
python3 scripts/release-metadata.py verify-source --source "$output/source.json"
python3 scripts/verify-release.py "$app" --source "$output/source.json" --mode developer-id
submission="$output/notary-submission.zip"
if [ -e "$submission" ] || [ -e "$output/notarization.json" ]; then
    printf '%s\n' 'Notarization output already exists; preserve its identity and inspect the previous result before retrying.' >&2
    exit 2
fi
ditto -c -k --sequesterRsrc --keepParent "$app" "$submission"
xcrun notarytool submit "$submission" --keychain-profile "$MACAPY_NOTARY_PROFILE" \
    --wait --output-format json > "$output/notarization.json"
python3 - "$output/notarization.json" <<'PY'
import json, sys
with open(sys.argv[1]) as file:
    result = json.load(file)
if result.get('status') != 'Accepted' or not result.get('id'):
    raise SystemExit('Apple did not accept the submission; no stapling or publication performed.')
PY
xcrun stapler staple "$app"
python3 scripts/verify-release.py "$app" --source "$output/source.json" --mode notarized --output "$output/bundle-verification.json"
printf '%s\n' 'Notarization accepted and ticket stapled. Run package-release.sh in notarized mode to create the final checksummed ZIP. Nothing was published.'
