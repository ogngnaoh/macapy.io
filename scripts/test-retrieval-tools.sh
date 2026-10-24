#!/bin/bash
set -euo pipefail
# Real provenance snapshot machinery, fake Swift runner: no models or builds.
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/macapy-retrieval-contract.XXXXXX")"
trap 'rm -rf "$fixture_dir"' EXIT
mkdir "$fixture_dir/bin"
cat > "$fixture_dir/bin/swift" <<'MOCK'
#!/bin/bash
set -euo pipefail
if [ "$*" = --version ]; then printf '%s\n' 'Synthetic Swift version'; exit; fi
test "$*" = 'test --disable-automatic-resolution --skip-update -c release --filter RetrievalEvidenceTests'
test -z "${MACAPY_DEEPSEEK_KEY:-}"
test -z "${MACAPY_RUN_LIVE_PROVIDER_TESTS:-}"
test -z "${MACAPY_RUN_LOCAL_MODEL_TESTS:-}"
test "$MACAPY_RUN_RETRIEVAL_EVIDENCE" = 1
test "$MACAPY_SEARCH_SCALE" = 1
test "${#MACAPY_EVIDENCE_SOURCE_HASH}" = 64
python3 - <<'PY'
import json,os
from pathlib import Path
Path(os.environ['MACAPY_RETRIEVAL_EVIDENCE_OUTPUT']).write_text(json.dumps({
    'configuration':'Release','segments':146458,'documentChunks':10000,'results':[{}]*40
}))
PY
MOCK
chmod +x "$fixture_dir/bin/swift"
export PATH="$fixture_dir/bin:$PATH"
MACAPY_DEEPSEEK_KEY=synthetic-test-value MACAPY_RUN_LIVE_PROVIDER_TESTS=1 MACAPY_RUN_LOCAL_MODEL_TESTS=1 MACAPY_SEARCH_SCALE=999 \
    "$repo_root/scripts/measure-retrieval.sh" "$fixture_dir/report" >/dev/null
if "$repo_root/scripts/measure-retrieval.sh" "$fixture_dir/report" >/dev/null 2>&1; then
    printf '%s\n' 'Existing evidence directory was incorrectly accepted.' >&2; exit 1
fi
if "$repo_root/scripts/measure-retrieval.sh" >/dev/null 2>&1; then
    printf '%s\n' 'Missing output argument was incorrectly accepted.' >&2; exit 1
fi
printf '%s\n' 'Retrieval script contracts passed (3 checks; fake Swift, no builds/models/providers).'
