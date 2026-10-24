#!/bin/bash
set -euo pipefail

# Dependency resolution may fetch pinned build dependencies on a fresh clone.
# "Offline" describes the test runtime: no provider requests or model downloads.
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

usage() {
    cat <<'USAGE'
Usage: scripts/verify.sh [offline|models|live] [swift test options]

  offline  Deterministic tests and native app build (default).
           Credentials and optional-lane flags are removed from the child environment.
  models   Requires MACAPY_RUN_LOCAL_MODEL_TESTS=1. Runs the retained real-model
           suites with already-installed assets; unavailable suites report skips.
           Never installs speech or diarization assets; no provider calls.
  live     Requires MACAPY_RUN_LIVE_PROVIDER_TESTS=1, MACAPY_DEEPSEEK_KEY, and
           --filter <reviewed-test-filter>. Run only with explicit authorization
           and a declared call/cost bound for that selected suite. Billable.

Examples:
  scripts/verify.sh
  scripts/verify.sh offline --filter TestRunPolicyTests
  MACAPY_RUN_LOCAL_MODEL_TESTS=1 scripts/verify.sh models
USAGE
}

lane="${1:-offline}"
if [ "$#" -gt 0 ]; then shift; fi
case "$lane" in
    -h|--help) usage; exit 0 ;;
    offline|models|live) ;;
    *) usage >&2; exit 2 ;;
esac

# Retain the caller's Xcode selection; do not change xcode-select globally.
if [ -z "${DEVELOPER_DIR:-}" ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

case "$lane" in
    offline)
        printf '%s\n' 'Offline runtime lane: local-model and live-provider suites will report explicit skips.'
        if [ "$#" -eq 0 ]; then
            env -u MACAPY_RUN_RETRIEVAL_EVIDENCE -u MACAPY_DEEPSEEK_KEY -u MACAPY_RUN_LIVE_PROVIDER_TESTS -u MACAPY_RUN_LOCAL_MODEL_TESTS \
                python3 scripts/check-source.py
        fi
        env -u MACAPY_RUN_RETRIEVAL_EVIDENCE -u MACAPY_DEEPSEEK_KEY -u MACAPY_RUN_LIVE_PROVIDER_TESTS -u MACAPY_RUN_LOCAL_MODEL_TESTS \
            swift test "$@"
        # Focused iteration does not need a second full app build.
        if [ "$#" -eq 0 ]; then
            env -u MACAPY_RUN_RETRIEVAL_EVIDENCE -u MACAPY_DEEPSEEK_KEY -u MACAPY_RUN_LIVE_PROVIDER_TESTS -u MACAPY_RUN_LOCAL_MODEL_TESTS \
                xcodebuild -project macapy.xcodeproj -scheme macapy \
                    -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO build
            env -u MACAPY_RUN_RETRIEVAL_EVIDENCE -u MACAPY_DEEPSEEK_KEY -u MACAPY_RUN_LIVE_PROVIDER_TESTS -u MACAPY_RUN_LOCAL_MODEL_TESTS \
                python3 scripts/check-source.py
        fi
        ;;
    models)
        if [ "${MACAPY_RUN_LOCAL_MODEL_TESTS:-}" != 1 ]; then
            printf '%s\n' 'Model lane is disabled. Set MACAPY_RUN_LOCAL_MODEL_TESTS=1 to opt in to installed-model checks.' >&2
            exit 2
        fi
        printf '%s\n' 'Installed-model lane: no asset downloads; missing assets are reported as skipped, not passed.'
        env -u MACAPY_RUN_RETRIEVAL_EVIDENCE -u MACAPY_DEEPSEEK_KEY -u MACAPY_RUN_LIVE_PROVIDER_TESTS \
            swift test --filter 'SpeechAnalyzerEngineTests|ConcurrentEngineTests|G1BudgetTests|FluidAudioDiarizerTests|DiarizedMeetingEndToEndTests' "$@"
        ;;
    live)
        if [ "${MACAPY_RUN_LIVE_PROVIDER_TESTS:-}" != 1 ] || [[ ! "${MACAPY_DEEPSEEK_KEY:-}" =~ [^[:space:]] ]]; then
            printf '%s\n' 'Live lane is disabled. Explicit opt-in and a nonempty provider credential are both required.' >&2
            exit 2
        fi
        if [ "$#" -ne 2 ] || [ "$1" != --filter ] || [ -z "$2" ]; then
            printf '%s\n' 'Live lane requires exactly --filter <reviewed-test-filter>; declare and approve the call/cost bound before running.' >&2
            exit 2
        fi
        printf '%s\n' 'Live provider lane: explicitly selected tests may make billable requests. Local-model lane is disabled.'
        env -u MACAPY_RUN_RETRIEVAL_EVIDENCE -u MACAPY_RUN_LOCAL_MODEL_TESTS swift test "$@"
        ;;
esac
