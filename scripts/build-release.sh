#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
mode=local
output=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --mode) mode="${2:?Missing mode}"; shift 2 ;;
        --output) output="${2:?Missing output directory}"; shift 2 ;;
        *) printf '%s\n' 'Usage: scripts/build-release.sh [--mode local|developer-id] --output <new-directory>' >&2; exit 2 ;;
    esac
done
if [ -z "$output" ] || { [ "$mode" != local ] && [ "$mode" != developer-id ]; }; then
    printf '%s\n' 'Choose a new output directory and mode local or developer-id.' >&2
    exit 2
fi
if [ -e "$output" ]; then
    printf '%s\n' 'Output already exists; use a new directory to preserve the previous candidate.' >&2
    exit 2
fi

# Reuse a caller-selected, already-resolved Xcode package checkout when running
# a local archive without fetching dependencies. Never discover or create it.
package_resolution=(-disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates)
if [ -n "${MACAPY_SOURCE_PACKAGES:-}" ]; then
    if [ ! -d "$MACAPY_SOURCE_PACKAGES" ]; then
        printf '%s\n' 'MACAPY_SOURCE_PACKAGES must name an existing package directory.' >&2
        exit 2
    fi
    package_resolution+=(-clonedSourcePackagesDirPath "$(cd "$MACAPY_SOURCE_PACKAGES" && pwd)")
fi

# This script never discovers identities or reads signing credentials. Signing
# is an explicitly selected operation using an identity configured by its owner.
signing=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO)
if [ "$mode" = developer-id ]; then
    if [ "${MACAPY_ALLOW_SIGNING:-}" != 1 ] || [[ "${DEVELOPER_ID_APPLICATION:-}" != 'Developer ID Application: '* ]] || [[ ! "${DEVELOPMENT_TEAM:-}" =~ ^[A-Z0-9]{10}$ ]]; then
        printf '%s\n' 'Signing requires MACAPY_ALLOW_SIGNING=1, DEVELOPER_ID_APPLICATION, and DEVELOPMENT_TEAM; no credentials were inspected.' >&2
        exit 2
    fi
    signing=(CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$DEVELOPER_ID_APPLICATION" "DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM")
fi

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
unset MACAPY_DEEPSEEK_KEY MACAPY_RUN_LIVE_PROVIDER_TESTS MACAPY_RUN_LOCAL_MODEL_TESTS
python3 scripts/check-source.py
mkdir -p "$output"
output="$(cd "$output" && pwd)"
python3 scripts/release-metadata.py snapshot --source "$output/source.json"

xcodebuild -project macapy.xcodeproj -scheme macapy -configuration Release \
    -destination 'generic/platform=macOS' -archivePath "$output/macapy.xcarchive" \
    -derivedDataPath "$output/DerivedData" "${package_resolution[@]}" \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=NO ENABLE_HARDENED_RUNTIME=YES SKIP_INSTALL=NO \
    "${signing[@]}" archive

app="$output/macapy.xcarchive/Products/Applications/macapy.app"
if [ "$mode" = developer-id ]; then
    python3 - "$output/ExportOptions.plist" "$DEVELOPMENT_TEAM" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'wb') as file:
    plistlib.dump({'method': 'developer-id', 'signingStyle': 'manual',
                  'teamID': sys.argv[2], 'signingCertificate': 'Developer ID Application'}, file)
PY
    xcodebuild -exportArchive -archivePath "$output/macapy.xcarchive" \
        -exportOptionsPlist "$output/ExportOptions.plist" -exportPath "$output/export"
    app="$output/export/macapy.app"
fi
python3 scripts/release-metadata.py verify-source --source "$output/source.json"
python3 scripts/verify-release.py "$app" --source "$output/source.json" --mode "$mode" --output "$output/bundle-verification.json"
printf '%s\n' "Archive ready for local review: $output" "Mode: $mode. Nothing was published or notarized."
