# Development

macapy is a native macOS application and a root Swift package. The Xcode target is a thin executable shell over `AppShell`; lower modules own capture, transcription, diarization, persistence, providers, and meeting intelligence.

## Requirements

- An Apple Silicon Mac running macOS 26 or later.
- Xcode 26 or later, with its command-line tools and macOS SDK installed.
- Python 3.10 or later for source and release checks.

Select the intended toolchain for the current shell without changing the system-wide selection:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -version
swift --version
```

Clone the repository, open `macapy.xcodeproj`, and run the **macapy** scheme. Build dependencies download during the first resolution. `Package.resolved` pins the versions; the root and Xcode lockfiles must contain identical dependency pins. Their `originHash` values can differ because the two resolution contexts differ.

```bash
swift test
xcodebuild -project macapy.xcodeproj -scheme macapy build
```

The first-run speech/model setup is separate from compilation. No API key is required to build, run deterministic tests, or use local transcription. Optional AI needs the configured provider credential. Do not source `.envrc` for ordinary development or CI: it is an optional local Keychain lookup used only for deliberately authorized live-provider work.

## Automated verification

The complete offline verification entrypoint is:

```bash
scripts/verify.sh offline
```

It checks public source boundaries and dependency pins, runs package tests, compiles the native app, and checks the resulting dependency state again. Here, **offline** describes test runtime: first-time build dependency resolution still requires network access. Real speech/diarization suites and live-provider suites report explicit skips. A skipped suite supplies no model-quality or provider-compatibility evidence.

For a focused iteration:

```bash
scripts/verify.sh offline --filter TestRunPolicyTests
```

That command runs the selected package tests without repeating the complete source/app checks. The script removes provider credentials and optional-lane flags from child processes, including when they were inherited from a developer shell.

Verification tooling has its own small contract suite:

```bash
scripts/test-verification-lanes.sh
python3 scripts/test-release-tools.py
scripts/test-retrieval-tools.sh
python3 scripts/check-source.py
python3 scripts/check-licenses.py
```

The source guard checks the current index and non-ignored working files. It rejects tracked private `docs/`, broken local Markdown links, public links into private notes, common credential signatures, author-specific absolute paths, mismatched dependency locks, and production products that reach test-only targets. It reports secret rule names and locations without printing matched values. It also checks exact dependency/license notice and fixture provenance inventory for drift. It is a focused guard, not a complete historical secret scan or legal clearance. Remote links and hosted GitHub rendering are not fetched by this offline check.

CI runs on the explicit `macos-26` Apple Silicon image with a selected Xcode path, read-only repository permissions, a pinned checkout action, and no provider secrets. Installed-model and live-provider checks are separate local opt-in lanes. CI configuration is not proof of a successful hosted run until a revision is published and that run completes.

## Installed-model evidence

Run this lane only when local model execution is intended and assets have already been installed through the app's setup flow:

```bash
MACAPY_LOCAL_AUDIO_FIXTURES=/absolute/path/to/local-fixtures \
  MACAPY_RUN_LOCAL_MODEL_TESTS=1 scripts/verify.sh models
```

It retains the real SpeechAnalyzer, concurrent transcription, diarization, end-to-end pipeline, and debug latency checks. Missing required assets or explicitly supplied local audio cause visible skips. The tests and latency CLI use installed-only speech preparation; they never request model downloads. Fake-engine and pure transformation tests remain in the normal offline lane.

Speech WAVs are excluded from the public source tree. Apple's [macOS Tahoe license, section 2F](https://www.apple.com/legal/sla/docs/macOSTahoe.pdf) restricts System Voices output to personal, noncommercial use and excludes public sharing. Existing audio was preserved locally before removal; older Git objects have not been rewritten. Do not upload generated audio with issues, benchmark reports, or releases.

For personal local testing, a separately opted-in script can create fresh fixtures using already-installed Samantha and Daniel voices. It writes a matching diarization schedule, never installs voices, and rejects a public repository output directory:

```bash
MACAPY_GENERATE_LOCAL_AUDIO=1 python3 scripts/generate-local-audio-fixtures.py /absolute/path/to/new-local-fixtures
```

The model tests require `fox.wav`, `train.wav`, or `two-voices.wav` as named in their skip reason; the diarization oracle also requires the matching `schedule.json`. Local synthesis versions can change durations, so record the generated hashes and never present a new fixture run as a repeat of historical audio evidence.

For an authorized release latency measurement using a synthetic fixture:

```bash
swift run -c release macapy-latency /absolute/path/to/local-fixtures/fox.wav
swift run -c release macapy-latency --diarize /absolute/path/to/local-fixtures/two-voices.wav
```

These commands run real installed models. The second also requires installed diarization assets. Keep the report together with hardware, OS/toolchain, fixture identity, configuration, and sample count. The debug regression ceiling is not the release latency claim.

## Synthetic retrieval evidence

The default offline suite checks a frozen 40-question corpus. The larger Release lane builds a bounded synthetic fixture with at least 146,000 transcript segments and exactly 10,000 document chunks:

```bash
scripts/measure-retrieval.sh /tmp/macapy-retrieval-evidence-new
```

Use a new directory. The script strips provider/model lane credentials and flags, requires already-resolved packages, records the current public source hash, and refuses to replace existing evidence. It measures warm history/retrieval latency and peak test-process RSS. An optional platform sentence-embedding probe never requests an asset download; unavailable or incomplete experiments remain explicit in the report. Exact cosine and reciprocal-rank fusion comparisons do not enable production semantic ranking.

These are synthetic retrieval/source checks. They do not measure generated-answer correctness, real capture latency, active app memory, cold startup, or a long-running meeting. Preserve failed/null results and the frozen corpus hash when reporting outcomes.

## Live-provider evidence

Live tests require both an exact opt-in flag and a nonempty `MACAPY_DEEPSEEK_KEY` supplied securely to the process. Before enabling them, review the selected test, authorize its provider traffic, and declare its call/cost bound. Do not place credentials in source files, command examples, issue reports, or retained logs.

```bash
MACAPY_RUN_LIVE_PROVIDER_TESTS=1 scripts/verify.sh live --filter DeepSeekLiveTests
```

The live script requires an explicit test filter. The flag/filter is an admission guard, not a universal cost cap: individual live suites have different workloads, and the frozen quality evaluation makes many more calls than a connection smoke check. Real-provider tests share an asynchronous admission gate to avoid competing provider latency measurements. No live suite runs just because a credential exists.

## Working on the code

Keep provider, indexing, diarization, and optional AI work off the capture/transcription critical path. Exercise cancellation, stale-result fencing, and deletion through the same store contracts used in production. `ProviderTestSupport` is reusable test infrastructure and must never become a dependency of a production product.

Private architecture and planning notes live in ignored `docs/`; they are not part of the contributor-facing repository. Public explanations belong in `guide/`. Avoid real meeting content in tests, screenshots, benchmark reports, and logs. Use synthetic fixtures with recorded provenance.

For packaging, provenance, and the remaining distribution requirements, see [Release preparation](release.md).
