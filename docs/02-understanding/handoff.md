# Handoff — Milestone 02 (Understanding)

## Start here next session

Slice 2 is **committed, not shipped**. Critic, un-anchored verifier, the decisions, and a second un-anchored fix-review are all done (slice doc notes 25–28) — **do not re-run any review; the chain is complete and its residuals are accepted and recorded (note 28).** Sanity check on arrival: `swift test` → 193 tests / 39 suites green, HEAD `e452864`, clean tree. The author confirmed this order at 2026-07-29 session end; only author-side items remain:

1. **Live checks 9–11.** One-time setup: `security add-generic-password -s io.macapy.dev -a deepseek -w`, then `source .envrc` (**direnv is not installed** — `brew install direnv` or source per shell). Walk-through notes from the verifier: the key field appears only after clicking a provider row (not a bug); after a test connection the Spend headline reads "Latest meeting: —" by design (test connections have no meeting). Check 9: key in Settings ▸ Providers, test connection streams, key in Keychain Access under `io.macapy.app` and nowhere on disk, Remove deletes it — which also tees up check 11's no-key precondition. Check 10: ledger rows + est. cost; **confirm live DeepSeek V4 rates** against the Spend numbers (defaults re-pinned from api-docs.deepseek.com 2026-07-29: v4-flash 0.14/0.0028/0.28, v4-pro 0.435/0.003625/0.87 per M). Check 9 is also the first-ever run of `DeepSeekLiveTests` and the live proof of the V4 model ids. Check 11: real full-length meeting, no key, `lsof -i -a -p $(pgrep -x macapy)` throughout — passing retires M1 exit criterion 4.
2. **Keychain residue audit** (agent-denied by our own rules): `security dump-keychain 2>/dev/null | grep -c io.macapy` before/after one `swift test` — the single audit hole both verifiers had to leave open.
3. **At ship: sign off the check-2 rewording** — `complete<T>` validates via Swift `Decodable`; the JSON Schema is enforced upstream via `strict: true` (verifier scope correction, note 27).
4. Then the ship ritual: slice table, integration notes, handoff, commit.
5. **GitHub secret scanning + push protection are still fully disabled** (public repo, 68 commits unpushed). Enable before any push — Settings ▸ Code security, or say the word and the agent runs the API call.

## Current state

- **Three commits this session; 68 unpushed.** `2473457` (review-round: six confirmed defects + API drift), plus the fix-review round. 193 tests / 39 suites green, `xcodebuild` clean, production DB untouched all session (1 meeting / 50 segments, md5-identical).
- **Review chain:** 5-lens adversarial critic + un-anchored verifier (checks 1–8 PASS; 5/7 mutation-proven with planted leaks) → six confirmed defects fixed TDD (headline: `stream_options.include_usage` was never sent — OpenAI/OpenRouter spend was unmeterable and the cap blind; SSE parsing rewritten spec-correct; in-band errors typed; URLError mapped; booking shielded from consumer cancellation; SpendMeter doc honesty) → **second** un-anchored review of the fixes (revert-spot-checks, real-GRDB premise probes) → six more findings fixed, worst being a regression the first fix round introduced (ledger-write failure destroyed completed results — now logs-and-survives).
- **Decisions ruled (note 25):** D2 **overturned** — real transcripts go to first-party DeepSeek, tradeoff author-accepted; slice 3 needs no OpenRouter key. D3 (ledger follows the meeting's DB) and D6 (fixtures until check 9 shows divergence) confirmed.
- **API drift fixed against live sources:** DeepSeek defaults `deepseek-v4-flash`/`-v4-pro` (old ids retired), thinking is a quirk-gated request field, OpenRouter deep default `anthropic/claude-sonnet-5` (the 4.5 slug is gone from their catalog), and `PricingDefaultsTests` locks every built-in profile's models to shipped rates.

## Open concerns

- **`DeepSeekLiveTests` has never executed**; the V4 model ids rest on offline evidence until check 9.
- Booking now deliberately logs-and-continues on a ledger-write failure (result > bookkeeping row; fires only when the meeting row is gone mid-call or the DB is unwritable). Abandoned streams still book nothing — M3 consumers must drain to `.completed`.
- The D-fix round itself had no third review — accepted residual (note 28); live checks + ship review are the remaining gates. Slice 3 owes: cap wiring (V5), `finish_reason: length|content_filter` surfacing. M3 owes: in-flight spend reservation.
- FluidAudio vetting before slice 4 (license/size/maintenance + the two-voice `say`-fixture separation run).
- Leaked v0 Postgres password: still public on `origin/*`; personal-reuse check (macOS Passwords ▸ Security Recommendations) still owed. Secret scanning off (above).
- 7 NEEDS-CLARIFICATION markers in PRD/SPEC stand; none block M2.
