# Handoff — Milestone 02 (Understanding)

## Start here next session

Slice 2 (ProviderKit) is **committed, not shipped**. The full review chain is done — critic, un-anchored verifier, decisions D2/D3/D6 ruled, and a second un-anchored fix-review (slice doc notes 25–28). **Do not re-run any review; residuals are accepted and recorded (note 28).** All security pre-push items closed and everything is pushed — start directly on the author-walked live checks:

1. Sanity on arrival: `swift test` → 193 tests / 39 suites green, clean tree, no unpushed commits.
2. **Live checks 9–11.** One-time setup: `security add-generic-password -s io.macapy.dev -a deepseek -w`, then `source .envrc` (direnv not installed — source per shell). Verifier walk-through notes: the key field appears only after clicking a provider row (not a bug); after a test connection the Spend headline reads "Latest meeting: —" by design.
   - **Check 9:** key in Settings ▸ Providers, test connection streams, key in Keychain Access under `io.macapy.app` and nowhere on disk, Remove deletes it (tees up check 11's no-key precondition). Also the first-ever run of `DeepSeekLiveTests` and the live proof of the V4 model ids.
   - **Check 10:** ledger rows + est. cost; confirm live DeepSeek V4 rates (defaults pinned 2026-07-29: v4-flash 0.14/0.0028/0.28, v4-pro 0.435/0.003625/0.87 per M).
   - **Check 11:** real full-length meeting, no key, `lsof -i -a -p $(pgrep -x macapy)` throughout — passing retires M1 exit criterion 4.
3. **At ship:** sign off the check-2 rewording — `complete<T>` validates via Swift `Decodable`; the JSON Schema is enforced upstream via `strict: true` (note 27).
4. Ship ritual: slice table, integration notes, handoff, commit, push.

## Current state

- **Everything is pushed; the public repo is current.** Push works **only over SSH** on the author's network (HTTPS uploads throttle to ~3KB/s → 408s); `origin`'s push URL is switched to SSH — keep it.
- **Security items all closed 2026-07-29:** secret scanning + push protection enabled and verified (validity checks are GHAS-only, unavailable on a free public repo); keychain residue audit passed (0 before / 0 after a full green suite); `/security-review` over the entire M1+M2 diff returned **zero findings**; the leaked v0 Postgres password is purged from the tips of `main` and `legacy` (legacy cleanup commit `6eb9dce`).
- 193 tests / 39 suites green, `xcodebuild` clean, production DB untouched (1 meeting / 50 segments).
- Review chain summary: 12 defects found and fixed across two un-anchored rounds (headline: `stream_options.include_usage` never sent — OpenAI/OpenRouter spend was unmeterable; plus a self-introduced hold-back regression where a ledger-write failure destroyed completed results — now logs-and-survives).
- Decisions: **D2 overturned** (real transcripts → first-party DeepSeek, tradeoff author-accepted; no OpenRouter key needed), D3 (ledger follows the meeting's DB) and D6 (fixtures until check 9 shows divergence) confirmed.

## Open concerns

- **Password-pattern rotation (author-side):** the leaked 9-char value is a personal pattern and remains recoverable from public history (`7be9733`; rewrite declined — breaks doc-cited SHAs). Rotate wherever the pattern is used; drop this line once done.
- `DeepSeekLiveTests` has never executed; the V4 model ids rest on offline evidence until check 9.
- Booking deliberately logs-and-continues on ledger-write failure; abandoned streams book nothing — M3 consumers must drain to `.completed`.
- Slice 3 owes: cap wiring (V5), `finish_reason: length|content_filter` surfacing. M3 owes: in-flight spend reservation.
- FluidAudio vetting before slice 4 (license/size/maintenance + two-voice `say`-fixture separation run).
- 7 NEEDS-CLARIFICATION markers in PRD/SPEC stand; none block M2.
