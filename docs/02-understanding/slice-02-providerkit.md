# Slice 2 — ProviderKit: OpenAI-Compatible Client, Profiles, Keychain, Spend

**Status:** pending
**Plan written:** 2026-07-17 (M2 planning session; acceptance checks precede implementation)
**References:** ../../SPEC.md §6.3 (LLMProvider contract), §6.4, §8 (security/privacy), §10; PRD FR-014, FR-015; ./milestone.md exit criteria 3 & 6.

The plan for this slice is also its record.

## Design

### Decisions (planning, 2026-07-17)

1. **`ProviderKit` becomes real:** `LLMProvider` protocol per SPEC §6.3 (`stream(_:)` → `AsyncThrowingStream<LLMEvent>`, `complete<T: Decodable>` with JSON-schema response format); single impl `OpenAICompatibleClient` on URLSession SSE. `CompletionRequest` carries model id, messages, response format, and `Purpose` tag.
2. **Endpoint profiles:** base URL, Keychain key reference, fast/deep model ids, quirks descriptor. Built-ins: OpenAI, OpenRouter, DeepSeek (data-jurisdiction note in UI copy), Ollama (no key); custom profiles allowed. Quirks exercised in tests: DeepSeek `reasoning_content` passback on continuations, sampling-params-ignored-in-thinking-mode.
3. **Keys in Keychain only** (Keychain Services, service `io.macapy.app`): never in DB, settings rows, or logs. No key → AI surfaces show the quiet setup prompt (PRD edge case), everything local still works.
4. **Spend:** schema migration adds `spend_ledger` (SPEC §6.2, camelCase columns); every call rows model/tokens/est-cost/purpose; per-meeting cap stored in settings; a `SpendMeter` gate consulted before any AI call — cap reached ⇒ typed refusal the caller must surface. Cap can never affect capture/transcription (SPEC kill-switch rule).
5. **UI:** Providers + Spend settings tabs built to the slice-1 design, including a "test connection" action that streams a short completion.
6. **Fake OpenAI-compatible server** as a test fixture (local HTTP listener in the test target): scripted SSE streams, structured-output responses, malformed/partial payloads, `reasoning_content` continuations, mid-stream disconnects, 429/5xx sequences. This harness is reused by slice 3 and M3.
7. **Live verification target: DeepSeek** (the author's key). Other profiles ship fake-server-tested only in M2.

## Acceptance checks (written before implementation)

Machine-verifiable (against the fake server unless noted):

1. Streaming: SSE chunks decode to an ordered `LLMEvent` stream; first-token and completion events observed; stream ends cleanly.
2. Structured output: `complete<T>` validates the final object against the schema; malformed and truncated payloads throw typed errors (no partial-object escape).
3. DeepSeek quirks: continuation requests carry `reasoning_content` back; thinking-mode requests omit sampling params.
4. Failure modes: mid-stream disconnect surfaces a typed error and leaves the client reusable; 429 and 5xx map to typed errors; a scripted recovery sequence (fail → succeed) completes.
5. Keychain-only: after storing a key and running calls, the DB file and captured log output contain no key material (test greps both).
6. Spend: each call writes one ledger row with correct purpose + token counts; est-cost math unit-tested; a call attempted past the cap is refused with the typed cap error and writes no row.
7. Zero-network guard: with no profile configured, no code path constructs a network request (G6 regression at the unit level).
8. Full `swift test` green; `xcodebuild` clean.

User-live:

9. Enter the DeepSeek key in Providers settings → test connection streams a reply; the key is visible in Keychain Access (service `io.macapy.app`) and nowhere on disk; deleting it in-app removes it.
10. Spend tab shows the ledger rows and est. cost from check 9's calls.
11. Meeting run with **no key configured**: capture/transcript/history fully work, AI surfaces show the quiet setup prompt, `lsof -i -a -p $(pgrep -x macapy)` stays empty (milestone exit criterion 3).

## Checklist

- [ ] Acceptance checks user-reviewed (M2 kickoff gate)
- [ ] Fake OpenAI-compatible server fixture (test target)
- [ ] `LLMProvider` + `OpenAICompatibleClient` SSE streaming (TDD against fake server)
- [ ] Endpoint profiles + quirks descriptors (built-ins incl. DeepSeek quirks)
- [ ] Keychain storage + no-key quiet path
- [ ] `spend_ledger` migration + `SpendMeter` cap gate
- [ ] Providers + Spend settings tabs (to slice-1 design)
- [ ] Critic pass (risky slice: streaming client)
- [ ] Verifier re-runs checks 1–8 with evidence
- [ ] Live checks 9–11 walked with author
- [ ] Ship rituals: slice table, integration notes, handoff, commit

## Notes / dead ends

(append as work proceeds)
