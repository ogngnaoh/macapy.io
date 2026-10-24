# macapy repository guidance

## Product boundary

macapy is a local-first native macOS meeting assistant. The current baseline has Milestones 1–3 implemented; memory/RAG, approved EventKit actions, pre-meeting briefs, and launch hardening remain later work unless the task explicitly includes them.

Permanent constraints:

- No backend, accounts, telemetry, meeting bot, or meeting-platform integration.
- Never persist or transmit raw audio.
- After required speech/diarization assets are installed, meeting-time network traffic may go only to the user-configured LLM endpoint.
- Capture and local transcription must continue when optional diarization or AI work fails, stalls, is cancelled, or reaches its spend cap.
- External actions require explicit user review and approval.

The `legacy` branch contains the archived Electron/FastAPI implementation. It is historical context and a negative example, not architectural guidance.

## Sources of truth

Resolve discrepancies in this order:

1. Production code and database migrations.
2. Fresh green tests and recorded milestone evidence.
3. The latest applicable milestone/handoff record.
4. Local `docs/architecture.md`.
5. Local `docs/SPEC.md`, `docs/PRD.md`, and older plans.

`docs/` is intentionally local-only and ignored by Git. Never force-add it. In an auxiliary worktree where it is absent, report architecture decisions in the handoff; the integration owner updates the main checkout’s local `docs/architecture.md`.

## Local planning and specification documents

All product, architecture, design, planning, and implementation-reference documents belong under ignored `docs/` and remain on the local machine only. `docs/PRD.md` and `docs/SPEC.md` are still the canonical product and system contracts; change them only when the task intentionally changes those contracts.

- milestone and slice plans;
- implementation specifications and design explorations;
- HTML/CSS design-system references and screen mockups;
- acceptance matrices, research notes, and rejected approaches;
- handoffs, closeout records, verification summaries, and architecture decisions.

Do not put internal plans/specs at the repository root or force-add anything under `docs/`. A document intended for users or contributors must be explicitly approved as public and placed outside `docs/` in a separate change.

Use these paths:

- `docs/architecture.md` — living system design and architecture decision register;
- `docs/PRD.md` — canonical local product requirements;
- `docs/SPEC.md` — canonical local system specification;
- `docs/design/` — local design system, screen mockups, and their assets;
- `docs/milestones.md` — local roadmap and milestone status;
- `docs/<milestone>/milestone.md` — milestone outcome, scope, gates, and closure;
- `docs/<milestone>/slice-XX-<name>.md` — decision-complete slice plan and implementation record;
- `docs/<milestone>/handoff.md` — verified state, pending work, risks, and next action;
- `docs/plans/YYYY-MM-DD-<topic>.md` — substantial standalone work that does not belong to a milestone.

Write planning detail proportionally, but a substantial plan/spec should make the following decision-complete:

- status, date, implementation baseline, intended outcome, and observable success criteria;
- scope and non-goals;
- constraints, assumptions, locked choices, and credible alternatives;
- affected module ownership, contracts/interfaces, data flow, and persistence changes;
- concurrency, failure/recovery, privacy/network, deletion, migration, and compatibility behavior where relevant;
- dependencies, sequencing, rollout/rollback considerations, and material risks;
- focused tests plus milestone/repository acceptance gates;
- unresolved questions only when they truly require user authority or external evidence.

Document lifecycle:

1. Create or update the plan before substantial implementation; write acceptance checks before the behavior they validate.
2. Mark unbuilt behavior Proposed or Planned. Never describe it as implemented architecture.
3. During implementation, append dated findings, deviations, failed assumptions, and evidence that materially changed the plan.
4. At integration, update the record to the code that actually shipped, including exact verification scope and known residual risks.
5. At closure, mark the plan Closed/Implemented, record acceptance verdicts, refresh `docs/architecture.md`, and leave a compact handoff when later work remains.
6. Preserve useful reasoning. Supersede obsolete plans/decisions instead of silently rewriting history or deleting failed approaches.

Local-only does not mean safe for secrets. Never include credentials, authorization headers, raw real-meeting transcripts, personal attendee data, private prompts/responses, or retained billable-provider logs. Record sanitized summaries, commands, metrics, and hashes instead.

Because `docs/` is not backed up by Git or the remote, preserve important local records with the user’s approved local backup system. Do not create a remote backup or external copy without explicit authorization.

### Git and worktree safeguards

- `git check-ignore -v docs/<file>` must resolve to the root `/docs/` rule.
- After the one-time docs-untracking commit lands, `git ls-files docs` must return nothing.
- Before committing or pushing, inspect the staged file list and verify it does not add or modify anything under `docs/`. The one-time staged deletions used to untrack historical docs are the only expected exception.
- Never use `git add -f docs/...` or an ignore override for local planning material.
- A branch/worktree created before docs were untracked can reintroduce them. Incorporate the untracking change before integration and verify the resulting Git tree contains no `docs/` entries.
- Ignored files are not automatically present in auxiliary worktrees. Keep the canonical plan/spec in the primary local checkout; workers summarize decisions and evidence in their handoff to the integration owner.

## Build and verification

- Full package tests: `swift test`
- App build: `xcodebuild -project macapy.xcodeproj -scheme macapy build`
- Release latency harness: `swift run -c release macapy-latency <fixture.wav>`
- Xcode 26+ should be selected at `/Applications/Xcode.app/Contents/Developer`.
- Live DeepSeek and model-gated suites are opt-in. Run networked or billable checks only with explicit authorization and a declared call/cost bound.
- Run focused checks while iterating, then the repository-defined full checks before claiming a software change complete. State clearly when a check was not run.

## Architecture snapshot

- Swift 6 with strict concurrency; SwiftUI/AppKit; macOS 26+; Apple Silicon is the v1 support target.
- One native process and one root Swift package. The Xcode app target is a thin shell over `AppShell`.
- `CaptureKit`: microphone/system capture, format conversion, bounded audio fan-out.
- `TranscribeKit`: SpeechAnalyzer adapter, transcript events/store, STT diagnostics.
- `DiarizeKit`: FluidAudio adapter and speaker attribution; no persistence dependency.
- `PersistKit`: GRDB/SQLite migrations and stores, FTS5 search, deletion, spend persistence.
- `ProviderKit`: Keychain credentials, OpenAI-compatible transport, endpoint quirks, sanitized failures, spend metering.
- `AgentKit`: post-meeting extraction and live-copilot classification, context, generation, arbitration, and recovery.
- `AppShell`: composition root, meeting lifecycle, task ownership/fencing, native presentation, and user controls.
- `ProviderTestSupport`: fake provider infrastructure; it must never link into the production product.

External dependencies are deliberately narrow: GRDB is quarantined in persistence and FluidAudio in diarization. Avoid adding a dependency or cross-module edge when a small local contract suffices.

## Engineering conventions

- “Capture always wins.” Never put provider, search, diarization, indexing, or post-meeting work on the capture/transcription critical path.
- Use structured concurrency, explicit actor ownership, bounded buffering, and meeting/provider/revision fences. Actor isolation does not prevent logical races across `await`.
- Attach transcript consumers before capture starts; drain or explicitly hand off capture teardown and spend settlement before releasing ownership.
- Treat incomplete provider output as failure: require the terminal protocol contract and natural `stop`; never persist partial structured results.
- Keep provider differences in endpoint profiles/quirks, not scattered conditionals or duplicate clients.
- Use in-memory GRDB through the same store interfaces for ephemeral meetings; do not “write then delete.”
- Keep migrations forward-only and additive. Preserve foreign-key, FTS, ephemeral, and deletion invariants with tests.
- Credentials belong only in Keychain. Logs, fixtures, docs, and errors must not contain keys, authorization headers, raw prompts, transcripts, or provider bodies.
- Use `os.Logger` with subsystem `io.macapy.app` and focused categories. Do not add a second logging framework.
- Keep `AppShell` as the composition/UI boundary; lower modules must not import SwiftUI app plumbing.
- Preserve unrelated working-tree changes. Do not commit, push, deploy, publish, or rewrite history unless the user explicitly asks.

## Recording architecture choices

Before implementing a material change, inspect `docs/architecture.md` and the relevant production contracts/migrations. Record a choice when it changes any of the following:

- module ownership, dependencies, or public contracts;
- schema, consistency, indexing, migration, retention, or deletion behavior;
- privacy, credentials, network egress, permissions, or security boundaries;
- concurrency ownership, buffering/backpressure, cancellation, recovery, or failure policy;
- provider compatibility, context assembly, spend enforcement, or model lifecycle;
- platform/deployment support, external dependencies, or measurable latency, memory, quality, storage, or cost budgets.

Do not create decision records for routine local implementation details with no credible alternative or lasting consequence.

Each architecture entry must include:

- **Status:** Proposed, Accepted, Implemented, or Superseded.
- **Context:** Requirement, constraint, failure, or evidence that forced the choice.
- **Decision:** Exact behavioral boundary chosen.
- **Alternatives:** Credible options considered.
- **Tradeoffs:** What improved and what cost or limitation was accepted.
- **Evidence:** Tests, measurements, incidents, prototypes, or authoritative platform behavior.
- **Consequences:** Effects on interfaces, data lifecycle, operations, privacy, or future work.
- **Revisit when:** A measurable trigger or product change.

Workflow:

1. Keep unresolved choices under the relevant pending section; do not present planned architecture as implemented.
2. During implementation, capture design-changing findings and rejected approaches as they occur.
3. After fresh verification, change the entry to Implemented and add the evidence. Never silently rewrite old reasoning; mark replaced choices Superseded.
4. At milestone closeout, update the architecture baseline, diagrams, data lifecycle, budgets, limitations, interview stories, and claim boundaries.
5. Keep the record interview-defensible: distinguish design targets from measured scale, fixture evidence from field telemetry, and compatible abstractions from production-wired support.

## Communication

Lead with the outcome. Keep updates concise and evidence-based. At handoff, include verified state, remaining work, risks, relevant local-only architecture updates, and the next owner/action.
