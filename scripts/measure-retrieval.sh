#!/bin/bash
set -euo pipefail

# Explicit, synthetic, local-only Release evidence. This lane never requests
# speech/diarization downloads, reads Keychain, or invokes a provider suite.
if [ "$#" -ne 1 ]; then
    printf '%s\n' 'Usage: scripts/measure-retrieval.sh NEW_OUTPUT_DIRECTORY' >&2
    exit 2
fi
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
if [ -e "$1" ]; then
    printf '%s\n' 'Choose a new output directory; evidence is never overwritten.' >&2
    exit 2
fi
unset MACAPY_DEEPSEEK_KEY MACAPY_RUN_LIVE_PROVIDER_TESTS MACAPY_RUN_LOCAL_MODEL_TESTS
export MACAPY_SEARCH_SCALE=1 MACAPY_RUN_RETRIEVAL_EVIDENCE=1
mkdir -p "$1"
evidence_dir="$(cd "$1" && pwd)"
export MACAPY_RETRIEVAL_EVIDENCE_OUTPUT="$evidence_dir/retrieval.json"
python3 scripts/release-metadata.py snapshot --source "$evidence_dir/source.json"
export MACAPY_EVIDENCE_SOURCE_HASH
MACAPY_EVIDENCE_SOURCE_HASH="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["public_source_sha256"])' "$evidence_dir/source.json")"
export MACAPY_EVIDENCE_SWIFT_VERSION
MACAPY_EVIDENCE_SWIFT_VERSION="$(swift --version)"
printf '%s\n' 'Running bounded synthetic retrieval evidence (Release, 146k segments, 10k chunks; no provider or download).'
# Existing resolved dependencies are required. Do not resolve/update packages
# or silently install assets while collecting offline evidence.
swift test --disable-automatic-resolution --skip-update -c release --filter RetrievalEvidenceTests 2>&1 | tee "$evidence_dir/test.log"
python3 scripts/release-metadata.py verify-source --source "$evidence_dir/source.json"
python3 - "$evidence_dir/retrieval.json" <<'PY'
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
report = json.loads(path.read_text())
assert report['configuration'] == 'Release'
assert report['segments'] >= 146_000 and report['documentChunks'] == 10_000
assert len(report['results']) == 40
print(f"Evidence saved: {path}")
print('Scope: synthetic retrieval only; no answer-quality, active-app memory, capture latency, or soak-test claim.')
PY
