# Handoff — Milestone 02 (Understanding)

## Start here next session

Slice 2 (ProviderKit) **shipped 2026-08-06**. Slice 3 (post-meeting agent) is next: write its acceptance checks as deterministic automated oracles first (see the verification model below), then implement. The slice doc is `./slice-03-post-meeting-agent.md`; its kickoff-gate checks were approved 2026-07-24 but predate the no-manual-checks ruling — re-express any author-walked check as an automated oracle before building.

**Verification model (author ruling 2026-08-06, slice-02 note 31):** no manual checks during development — every check is a deterministic automated oracle; one manual walk of the whole app happens when the app is complete. Live-API suites are gated on `LiveCredentials.hasDeepSeek` (skip-not-fail on clones) and run via `source .envrc && swift test` (direnv not installed — source per shell; key seeded once with `security add-generic-password -s io.macapy.dev -a deepseek -w`).

1. Sanity on arrival: `swift test` → 195 tests / 40 suites green (the 3 live tests report skipped without the key but still count), clean tree, no unpushed commits.
2. Slice 3 owes from slice 2: wire the per-meeting cap (verifier V5 — `perMeetingCapUSD` persists and displays but nothing constructs a capped meter); decide `finish_reason: length|content_filter` surfacing for structured calls; consumers must drain streams to `.completed` (abandoned streams book nothing).
3. D6 resolved 2026-08-06: live DeepSeek matches the hand-written fixtures — **no record/replay**; `OpenAIFixtures` stays.

## Current state

- **Slice 2 shipped.** Live verification is automated: `ProviderLiveFlowTests` (checks 9–10: real Keychain via a raw-SecItem oracle under a dedicated test service, real on-disk DB byte-grepped for key residue, real DeepSeek call booked and est-cost re-derived with independent arithmetic, in-app remove proven) + `DeepSeekLiveTests` (first-ever run passed — **V4 model ids live-proven**; bogus key → clean 401). Cost oracle mutation-proven (wrong rate → red).
- **Only DeepSeek is wirable** (`EndpointProfile.wired`, note 30): the Providers UI shows one row; the four-profile catalog (`builtIns`) stays in ProviderKit for the multi-provider fast-follow. A profile graduates into `wired` by passing its own live check.
- Everything is pushed; push works **only over SSH** on the author's network (HTTPS throttles to ~3KB/s) — `origin`'s push URL is SSH, keep it.
- Security posture unchanged since 2026-07-29: secret scanning + push protection on; `/security-review` of the M1+M2 diff clean; keychain residue 0/0.
- Production DB untouched (1 meeting / 50 segments).

## Open concerns

- **Check 11 (decoupled from ship, note 29):** real full-length no-key meeting with `lsof -i -a -p $(pgrep -x macapy)` empty throughout — runs at the author's next real meeting; passing retires M1 exit criterion 4. The author must remember to run it; nothing else blocks on it.
- **App-complete manual walk (one, at the end):** pixels only — Settings field wiring, Keychain Access visual, Spend-tab rendering, plus whatever later slices defer to it.
- FluidAudio vetting before slice 4 (license/size/maintenance + two-voice `say`-fixture separation run).
- Booking logs-and-continues on ledger-write failure; M3 owes in-flight spend reservation.
- 7 NEEDS-CLARIFICATION markers in PRD/SPEC stand; none block M2.
