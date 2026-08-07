# Slice 3 — Post-Meeting Agent v1: Extraction → Draft Artifacts → Review

**Status:** shipped 2026-08-07
**Plan written:** 2026-07-17 (M2 planning session; acceptance checks precede implementation); amended 2026-08-06 (checks 9–11 re-expressed as automated oracles under the no-manual-checks ruling — slice-02 note 31)
**References:** ../../SPEC.md §6.4 (post-meeting agent, G3), §6.2 (artifacts schema); PRD FR-008, FR-009 (review only — EventKit is M4), Story 4; ./milestone.md exit criteria 2 & 6.

The plan for this slice is also its record.

## Design

### Decisions (planning, 2026-07-17)

1. **`AgentKit` gets its first real component:** a post-meeting extractor triggered on meeting end (from `SessionController` stop, non-ephemeral meetings with a configured provider only). One deep-tier structured-output pass over the final transcript → `artifacts` rows (`summary`, `decision`, `action_item` with owner/deadline where stated) in `draft` status.
2. **No rolling summary in M2** (that's M3's context assembly). Long transcripts are handled by chunked map-reduce extraction (per-chunk extract → merge pass) — the mechanism must not hard-fail at any meeting length (PRD 3h+ edge case); exact chunk budget decided at build and recorded here.
3. **Schema migration adds `artifacts`** (SPEC §6.2, camelCase). Deleting a meeting cascades to artifacts (invariant already specced).
4. **Review UI lives in meeting detail** (new screen, built to slice-1 design): artifacts pane with per-item approve/reject. Approve/reject **only flips status** — no external effect of any kind in M2.
5. **Retroactive generation** (PRD edge case): if extraction failed or no provider was configured at meeting end, meeting detail offers "generate artifacts" once a provider is available. Same code path as the automatic trigger.
6. **Spend + cap integration:** extraction calls carry `Purpose.artifact`, row into the ledger, and respect the cap gate (cap reached ⇒ visible halt notice, transcript untouched).
7. **G3 measurement:** wall time from meeting-end to last artifact row written, surfaced in diagnostics; authoritative check is live on DeepSeek.

## Acceptance checks (written before implementation)

Machine-verifiable (fake server from slice 2):

1. End-to-end: meeting end → extraction request issued → artifacts rows land in `draft` with correct kinds and payloads (scripted response).
2. Decode robustness: malformed / truncated / schema-violating extraction payloads produce a typed failure and zero partial artifact rows (SPEC §10 unit case).
3. Approve flips status to `approved`, reject to `rejected`; nothing else in the DB or system changes (asserted: row diff only).
4. Long-transcript path: a synthetic 3h-scale transcript completes extraction via chunked map-reduce without error.
5. Retroactive path: extraction with no provider ⇒ meeting marked artifacts-pending, no crash; invoking generate later (fake server up) produces the same artifacts as the automatic path.
6. Cap: cap-reached before extraction ⇒ no request issued, visible-halt state set, meeting/transcript rows intact.
7. Ephemeral meetings never trigger extraction and never write artifacts.
8. Full `swift test` green; `xcodebuild` clean.

Live-gated automated (DeepSeek; skip-not-fail without the key) — *re-expressed 2026-08-06 from the original author-walked checks per the no-manual-checks ruling (slice-02 note 31); the original wording follows each for traceability*:

9. **Automated:** a fixture transcript with unambiguous ground truth (explicitly stated decisions, and action items with named owners and stated deadlines) runs the real extraction path against live DeepSeek → schema-valid artifact rows land in `draft`; every unambiguous fixture item appears (owner and deadline populated where the fixture states them); wall time from trigger to last row **< 60s** (G3, measured in-test and recorded in milestone.md). LLM nondeterminism is bounded by asserting the unambiguous core, not exact payloads. *(Was: real meeting ends → artifacts in meeting detail within 60s. The genuinely-real-meeting run folds into dogfooding + the app-complete walk.)*
10. **Covered by machine check 3** (approve/reject flips status; asserted row-diff-only — nothing else in DB or system changes). The visual half (meeting-detail rendering) goes to the app-complete walk. *(Was: author walks approve/reject.)*
11. **Automated:** extraction against a profile pointing at a dead local port → meeting marked artifacts-pending, no crash, no partial rows; then generate against live DeepSeek → drafts appear via the same path. Deterministic stand-in for "network disabled" — no manual toggling. *(Was: end a meeting with network off, re-enable, generate.)*

## Checklist

- [x] Acceptance checks user-reviewed (M2 kickoff gate — approved 2026-07-24, amendments in ./milestone.md Integration notes)
- [x] `artifacts` migration + GRDB records (2026-08-07: schema v3, `ArtifactStore`, row-diff-only oracle in `ArtifactStoreTests`)
- [x] Extraction prompt + JSON schema + decode layer (2026-08-07: `MeetingExtraction` + `PostMeetingExtractor`, TDD against the fake server — `ExtractionDecodeTests`)
- [x] Chunked map-reduce for long transcripts (2026-08-07: `TranscriptChunker`, concurrent maps + one merge; budget in note 2 below)
- [x] Meeting-end trigger + retroactive generate path (2026-08-07: `AppShellCoordinator.teardownPipeline` → `PostMeetingAgent.generateArtifacts`; same entry point behind the detail pane's Generate button)
- [x] Meeting detail screen with artifacts pane + review flow (2026-08-07: `MeetingDetailView`/`MeetingDetailModel` to design/05 — review sections, pending note + Generate, setup prompt, cap-halt notice)
- [x] Spend purpose tagging + cap-halt notice (2026-08-07: `Purpose.artifact` booked through `MeteredProvider`; halt state derived + rendered — note 4)
- [x] **Owed from slice 2:** V5 closed — `AppShellCoordinator.postMeetingAgent()` is the one place a capped `SpendMeter` is constructed from `perMeetingCapUSD` (note 5); `finish_reason` ruled + implemented (note 3); extraction is non-streaming so the drain-to-`.completed` concern doesn't arise for this consumer (booking happens in `completeReportingUsage`) — restated for M3's streaming consumers
- [x] Critic pass (2026-08-07, fresh-context reviewer — findings + resolutions in note 8)
- [x] Verifier re-runs checks 1–8 with evidence (2026-08-07 — evidence table in note 9)
- [x] Live-gated automated checks 9 + 11 green on the author's machine (2026-08-07: **G3 = 2.5s** trigger→last row, recorded in milestone.md; one RED→fix cycle — note 6)
- [x] Ship rituals: slice table, integration notes, handoff, commit, push (2026-08-07)

## Notes / dead ends

1. **2026-08-07 (build session):** whole slice built and shipped in one session; decisions 2–7 below were made at build time as the plan required. Verification disclosure (repo convention): this session wrote both the implementation and its tests; the critic pass ran in a fresh context (note 8); live checks ran against real DeepSeek on the author's key.
2. **Chunk budget (decision 2 recorded):** 60,000 characters per extraction call (~15k tokens at ~4 chars/token — provider-agnostic on purpose; a tokenizer here would tie AgentKit to one vocabulary). Single pass when the rendered transcript fits one chunk — a 1h meeting (~50k chars) stays single-pass. Above it: greedy line-packing into ≤60k-char chunks (an over-budget single line is split mid-line — degraded extraction beats a hard fail), chunks map **concurrently** (wall time ≈ slowest call + merge, for G3), one merge call over the partial-extraction JSONs — merge input is bounded by extraction *output* size, so no meeting length hard-fails (PRD 3h+ case; check 4 runs a ~260k-char synthetic → 5 maps + merge).
3. **`finish_reason` ruling (slice-2 open item, closed):** on non-streaming structured calls, any non-`stop` finish reason throws the new `ProviderError.truncated(finishReason:)` **before decode** — a `length`-cut payload that still parses must not become artifacts (same bucket as check 2's malformed payloads; `FinishReasonTests`). Streaming callers keep deciding themselves via `Completion.finishReason` — M3's concern.
4. **Artifacts-pending and cap-halt are derived, never persisted:** pending = ended ∧ non-ephemeral ∧ zero artifact rows; halted = ledger spend ≥ configured cap (recomputed on load, plus surfaced immediately from the agent's `.halted` outcome). No state column to migrate or drift; one source of truth.
5. **V5 closed:** `AppShellCoordinator.postMeetingAgent()` constructs `SpendMeter(ledger:pricing:capUSD: settings.perMeetingCapUSD)` inside a `MeteredProvider` keyed to the meeting — settings re-read per generation, so a cap set after the meeting applies to retroactive generates. Cap-reached ⇒ `authorize` throws before any request is built (check 6: zero requests recorded).
6. **Live RED → quirk (the slice's one dead end):** first-party DeepSeek V4 rejects `response_format: json_schema` — live check 9 400'd with *"This response_format type is unavailable now"*. Fix: new `Quirks.usesJSONObjectResponseFormat` (set on the deepSeek profile): the client sends `{"type": "json_object"}` and appends the JSON Schema as a **trailing** system message (tail-append keeps any cached prefix valid, SPEC §6.4); validation is unchanged — the final object is still decoded client-side against the schema type (SPEC §6.3), so nothing the endpoint stops enforcing goes unenforced. Wire-pinned both ways in `ProfileQuirksTests`; live re-run green. The fake-server json_schema tests keep covering the strict dialect (OpenAI/OpenRouter path for the fast-follow).
7. **Trigger placement + reentrancy:** generation runs as its own task spawned after `stop()` completes — a next meeting's start serializes behind stop, and must never wait on a multi-second extraction. `PostMeetingAgent` carries an in-flight-per-meeting guard because actors are reentrant across `await`s: without it, the automatic trigger racing the detail pane's Generate button double-inserted (caught in this session; regression test `concurrentGenerationsForOneMeetingDraftExactlyOnce`).
8. **Critic pass (fresh context, bounded mandate: correctness + slice requirements):** two findings, one soft spot — all fixed before ship. (a) `PostMeetingAgent`'s failure log used `String(describing: error)`, bypassing ProviderLog's message-stripping rule (an endpoint may echo request content — transcript text — into error strings); fixed by promoting the sanitizer to public `ProviderError.logDescription`, routing both AgentKit catches and ProviderLog through it, regression-pinned by `LogSanitizationTests`. (b) Stale `SpendMeter` doc comment still claimed nothing constructs a capped meter; updated to point at `postMeetingAgent()`. (c) Soft spot: a second meeting ending before the first's generation finished overwrote `artifactGenerationTask`, leaving the earlier task running but untracked by `settle()` (test-determinism only); generations now chain like stopTask does. Separately, the builder itself caught an actor-reentrancy double-insert (note 7) before the critic ran — the critic confirmed the guard. Everything else in the mandate came back clean with evidence (transactional inserts, cap gate unbypassed, double-gated ephemeral, row-diff flips, additive migration, quirk correctness).
9. **Verifier evidence (checks 1–8):** 1 → `MeetingEndArtifactsTests.meetingEndDraftsArtifactsThroughTheFullShell`; 2 → `ExtractionDecodeTests` (+ `FinishReasonTests` at the client); 3 → `ArtifactStoreTests.statusFlipChangesExactlyThatOneCell` (full-DB row-diff oracle) + `MeetingDetailModelTests.approveAndRejectFlipStatusAndNothingElse`; 4 → `PostMeetingAgentTests.threeHourScaleTranscriptCompletesViaMapReduce`; 5 → `PostMeetingAgentTests.noProviderLeavesMeetingPending…` + `MeetingEndArtifactsTests.unconfiguredProvider…` + `MeetingDetailModelTests.generateFromPending…`; 6 → `PostMeetingAgentTests.capReachedIssuesNoRequest…` + `MeetingDetailModelTests.capReachedLoadsIntoTheVisibleHaltState`; 7 → `MeetingEndArtifactsTests.ephemeralMeetingNeverTriggersExtraction` + `PostMeetingAgentTests.ephemeralMeetingIsNeverExtracted`; 8 → full `swift test` + `xcodebuild` clean (final counts in milestone note). UI additions honor the slice-1 grep audit (no ad-hoc Color/Font literals; new tokens `statusApproved`/`statusRejected`/`textOnSignal` from the mockup's values).
10. **Deferred, recorded:** the mockup titlebar's "Delete…" goes with slice 5 (deletion); wiring the G3 number into the diagnostics panel's percentile view waits for M3 (today's surface is the artifacts header's "drafted in Ns", the mockup's own readout); meeting-detail *rendering* (pixels) goes to the app-complete walk like every other visual check.
