#!/bin/bash
set -euo pipefail

# Exercise the shell entrypoint using fake tool executables. No compiler,
# model, provider, or credential store is touched by these contract checks.
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/macapy-verification.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
mkdir "$test_dir/bin"
export MACAPY_LANE_PROBE="$test_dir/probe"

cat > "$test_dir/bin/swift" <<'MOCK'
#!/bin/bash
set -euo pipefail
test -z "${MACAPY_RUN_RETRIEVAL_EVIDENCE:-}"
printf 'swift|credential=%s|models=%s|live=%s|%s\n' \
    "${MACAPY_DEEPSEEK_KEY:+present}" "${MACAPY_RUN_LOCAL_MODEL_TESTS:-}" \
    "${MACAPY_RUN_LIVE_PROVIDER_TESTS:-}" "$*" >> "$MACAPY_LANE_PROBE"
MOCK
cat > "$test_dir/bin/xcodebuild" <<'MOCK'
#!/bin/bash
set -euo pipefail
printf 'xcodebuild|credential=%s|models=%s|live=%s\n' \
    "${MACAPY_DEEPSEEK_KEY:+present}" "${MACAPY_RUN_LOCAL_MODEL_TESTS:-}" \
    "${MACAPY_RUN_LIVE_PROVIDER_TESTS:-}" >> "$MACAPY_LANE_PROBE"
MOCK
cat > "$test_dir/bin/python3" <<'MOCK'
#!/bin/bash
set -euo pipefail
test "$1" = scripts/check-source.py
printf 'guard|credential=%s|models=%s|live=%s\n' \
    "${MACAPY_DEEPSEEK_KEY:+present}" "${MACAPY_RUN_LOCAL_MODEL_TESTS:-}" \
    "${MACAPY_RUN_LIVE_PROVIDER_TESTS:-}" >> "$MACAPY_LANE_PROBE"
MOCK
chmod +x "$test_dir/bin/swift" "$test_dir/bin/xcodebuild" "$test_dir/bin/python3"
export PATH="$test_dir/bin:$PATH"

expect_probe() {
    if [ "$(cat "$MACAPY_LANE_PROBE")" != "$1" ]; then
        printf '%s\n' 'Verification lane contract failed.' >&2
        cat "$MACAPY_LANE_PROBE" >&2
        exit 1
    fi
    : > "$MACAPY_LANE_PROBE"
}

# A developer shell with both opt-ins and a credential still runs offline.
MACAPY_RUN_RETRIEVAL_EVIDENCE=1 MACAPY_DEEPSEEK_KEY=synthetic-test-value MACAPY_RUN_LOCAL_MODEL_TESTS=1 MACAPY_RUN_LIVE_PROVIDER_TESTS=1 \
    "$repo_root/scripts/verify.sh" offline >/dev/null
expect_probe $'guard|credential=|models=|live=\nswift|credential=|models=|live=|test\nxcodebuild|credential=|models=|live=\nguard|credential=|models=|live='

"$repo_root/scripts/verify.sh" offline --filter TestRunPolicyTests >/dev/null
expect_probe 'swift|credential=|models=|live=|test --filter TestRunPolicyTests'

# Missing exact opt-in, missing credentials, or unbounded live selection fail
# before either fake executable can be reached.
expect_rejected() {
    if "$@" >/dev/null 2>&1; then
        printf '%s\n' 'Expected an optional lane to reject this invocation.' >&2
        exit 1
    fi
    expect_probe ''
}
expect_rejected env -u MACAPY_RUN_LOCAL_MODEL_TESTS "$repo_root/scripts/verify.sh" models
expect_rejected env MACAPY_RUN_LOCAL_MODEL_TESTS=true "$repo_root/scripts/verify.sh" models
expect_rejected env -u MACAPY_RUN_LIVE_PROVIDER_TESTS MACAPY_DEEPSEEK_KEY=synthetic-test-value "$repo_root/scripts/verify.sh" live --filter DeepSeekLiveTests
expect_rejected env -u MACAPY_DEEPSEEK_KEY MACAPY_RUN_LIVE_PROVIDER_TESTS=1 "$repo_root/scripts/verify.sh" live --filter DeepSeekLiveTests
expect_rejected env MACAPY_DEEPSEEK_KEY='  ' MACAPY_RUN_LIVE_PROVIDER_TESTS=1 "$repo_root/scripts/verify.sh" live --filter DeepSeekLiveTests
expect_rejected env MACAPY_DEEPSEEK_KEY=synthetic-test-value MACAPY_RUN_LIVE_PROVIDER_TESTS=1 "$repo_root/scripts/verify.sh" live

MACAPY_DEEPSEEK_KEY=synthetic-test-value MACAPY_RUN_LOCAL_MODEL_TESTS=1 MACAPY_RUN_LIVE_PROVIDER_TESTS=1 \
    "$repo_root/scripts/verify.sh" models >/dev/null
expect_probe 'swift|credential=|models=1|live=|test --filter SpeechAnalyzerEngineTests|ConcurrentEngineTests|G1BudgetTests|FluidAudioDiarizerTests|DiarizedMeetingEndToEndTests'

MACAPY_DEEPSEEK_KEY=synthetic-test-value MACAPY_RUN_LOCAL_MODEL_TESTS=1 MACAPY_RUN_LIVE_PROVIDER_TESTS=1 \
    "$repo_root/scripts/verify.sh" live --filter DeepSeekLiveTests >/dev/null
expect_probe 'swift|credential=present|models=|live=1|test --filter DeepSeekLiveTests'

printf '%s\n' 'Verification lane contracts passed (10 checks; fake tools only).'
