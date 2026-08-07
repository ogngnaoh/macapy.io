# Handoff — Milestone 02 (Understanding)

## Start here next session

Slice 3 (post-meeting agent) **shipped 2026-08-07**. **Next session is a planning discussion, not a build** (author decision 2026-08-07): re-plan slices 4 (diarization + memory-watch hardening) and 5 (history & search) together, then implement both. The existing slice docs (`./slice-04-diarization.md`, `./slice-05-history-search.md`) are the starting point, not the finished plan — their checks were approved 2026-07-24 and predate both the no-manual-checks ruling and everything slices 2–3 learned, so expect amendments; re-express any author-walked check as an automated oracle (same exercise slice 3 did for its checks 9–11), and get the revised checks user-reviewed before implementation begins (repo convention).

Inputs that planning discussion must take up:
- **FluidAudio vetting** stays slice 4's hard precondition (license/size/maintenance review + the empirical two-voice `say`-fixture separation run demanded at the 2026-07-24 gate) before the slice commits to its fixture design.
- Slice-3 facts that touch both slices: schema is at v3 with `artifacts` cascading on meeting delete (slice 5's deletion/search scope must cover artifacts); meeting detail now exists (slice 5's "Delete…" button and search land around it); DeepSeek is json_object-only for structured output.

**Verification model (author ruling 2026-08-06, unchanged):** no manual checks during development — deterministic automated oracles only; one manual walk of the whole app at app-complete. Live suites gate on `LiveCredentials.hasDeepSeek` (skip-not-fail on clones); run via `source .envrc && swift test` (direnv not installed — source per shell; key seeded once via `security add-generic-password -s io.macapy.dev -a deepseek -w`).

1. Sanity on arrival: `swift test` → 244 tests / 49 suites green (the live suites report skipped without the key but still count), clean tree, no unpushed commits.
2. Nothing is owed *to* slices 4–5 from slice 3. Standing M3 debts: in-flight spend reservation (cap can overshoot by concurrent in-flight calls — SpendMeter doc); streaming consumers must drain to `.completed` and decide their own non-stop `finish_reason` handling (slice 3 ruled it for structured calls only); wiring the G3 number into the diagnostics percentile view.
3. New provider fact, relevant to everything M3 builds: **first-party DeepSeek V4 supports only `json_object` structured output** (rejects `json_schema` — live-proven). `Quirks.usesJSONObjectResponseFormat` handles it (schema rides as a trailing system message; client-side decode still validates). The copilot classifier's strict-JSON step must assume this shape on DeepSeek.

## Current state

- **Slice 3 shipped.** Meeting end → one deep-tier extraction (60k-char chunked map-reduce above budget, concurrent maps) → `artifacts` rows in `draft` → review in meeting detail (approve/reject flips status only); retroactive Generate for pending meetings is the same code path; ephemeral meetings structurally can't reach the agent. **G3 live: 2.5s** trigger→last row (budget 60s). Slice-2 V5 debt closed: the capped meter exists (`AppShellCoordinator.postMeetingAgent()`), cap-reached ⇒ zero requests + visible halt state in the pane.
- Schema is at **v3** (`artifacts`, FK-cascade from meetings). Artifacts-pending/cap-halt are *derived* states, never persisted.
- `PostMeetingAgent` has a per-meeting in-flight guard (actor reentrancy double-insert, caught + regression-tested this session).
- Everything is pushed; push works **only over SSH** on the author's network (HTTPS throttles to ~3KB/s) — `origin`'s push URL is SSH, keep it.
- Security posture unchanged: secret scanning + push protection on; keys only in Keychain; `KeyLeakTests` still green over the new call paths.
- Production DB untouched by tests (1 meeting / 50 segments as of 2026-08-06; slice-3 tests are all in-memory).

## Open concerns

- **Check 11 of slice 2 (decoupled from ship, note 29):** real full-length no-key meeting with `lsof -i -a -p $(pgrep -x macapy)` empty throughout — still pending, runs at the author's next real meeting; passing retires M1 exit criterion 4. The author must remember; nothing blocks on it.
- **App-complete manual walk (one, at the end):** pixels only — now also includes meeting-detail rendering (cards, chips, meta lines, both modes) on top of the slice-2 list (Settings field wiring, Keychain Access visual, Spend tab).
- Slices 4–5 re-planning discussion precedes any build (see Start here); FluidAudio vetting inside it.
- Booking still logs-and-continues on ledger-write failure; M3 owes in-flight spend reservation.
- 7 NEEDS-CLARIFICATION markers in PRD/SPEC stand; none block M2.
