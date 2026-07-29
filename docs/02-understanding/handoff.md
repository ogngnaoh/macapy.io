# Handoff — Milestone 02 (Understanding)

## Start here next session

Slice 2's **code is built and its machine checks (1–8) pass**; what remains is review and the author's live checks. In order:

1. **Critic pass on the streaming client** — the slice checklist calls for it and this is the risky surface (SSE decode, truncation detection, cancellation, the metering decorator). Not yet run.
2. **Independent verifier** re-runs checks 1–8 from a clean tree and records the evidence.
3. **One-time Keychain setup, then live checks 9–11 with the author.** Setup (author only — the agent is denied `security find-generic-password`): `security add-generic-password -s io.macapy.dev -a deepseek -w` (prompts, so the key stays out of shell history), then `direnv allow`. That lights up `DeepSeekLiveTests`, which has **never been run** and makes real calls. Check 9: enter the key in Settings ▸ Providers, "Test connection" streams a reply, key visible in Keychain Access under service `io.macapy.app` and nowhere on disk, Remove deletes it. Check 10: Spend tab shows those rows. Check 11: a **real full-length meeting with no key configured**, `lsof -i -a -p $(pgrep -x macapy)` running throughout — passing it retires M1 exit criterion 4.
4. Then ship rituals (slice table, integration notes, handoff, commit).

**Confirm before trusting the Spend numbers:** the built-in `PricingTable.defaults` rates are unverified starting points written from memory, not published facts. Check them against DeepSeek's pricing page during live check 10; they're editable, and the est-cost math is tested against explicit rates rather than these.

**Decide before slice 3 starts metering:** D3 (ephemeral × spend ledger) and D2 (transcript routing) in the slice doc, notes 18–19. Both are cheap now and expensive after real transcripts have moved.

## Current state

- **Two commits this session:** `59b91f5` (security cleanup) and the slice-2 body of work — all of ProviderKit, the settings surface, the live-check plumbing, and these docs. Committed as one because splitting it leaves a non-building tree: `Package.swift` declares targets whose sources would otherwise be untracked. The slice is **committed, not shipped** — critic, verifier, and live checks 9–11 all still owe.
- **160 tests / 31 suites green with no key present; `xcodebuild` clean.** Was 152/29 before this session's additions. `swift test --filter LiveCredentialsTests` was run 20× consecutively with zero failures, because the first version of that suite raced (slice doc note 23) and a full-suite green did not catch it.
- New in `Sources/ProviderKit`: LLMProvider/CompletionRequest/LLMEvent, OpenAICompatibleClient, EndpointProfile+Quirks with four built-ins, CredentialStore/Keychain, ProviderRegistry+ProviderSettings, Spend (PricingTable/SpendMeter/MeteredProvider), ProviderLog. Plus `Sources/ProviderTestSupport` (FakeOpenAIServer, OpenAIFixtures, RecordingURLProtocol, InMemorySpendLedger, **LiveCredentials** — a *non-product* target so slice 3 and M3 reuse it), `Sources/PersistKit/SpendLedgerStore.swift` + `SettingsStore.swift` (schema **v2** adds `spend_ledger`), `Sources/AppShell/ProviderSettingsModel.swift` + `SettingsView.swift` + `Design/SettingsComponents.swift`.
- **Credential handling is now decided and written down** — slice doc notes 15–22 (D1–D6). Short version: dev keys come from the Keychain via a committed `.envrc` that holds a lookup rather than a value; live suites gate on the key and skip without it; guardrails live in a tracked `.claude/settings.json`.
- **A leaked secret was found and closed.** `.claude/settings.local.json` was tracked and carried a plaintext Postgres password reachable from public `origin/main` and `origin/legacy` — written there by the permission allowlist recording an approved command verbatim, not by any source file. Full-history scan across all refs: **no LLM API key was ever committed**. Details and the rotation caveat in slice doc note 15.
- Three platform findings worth not rediscovering, all in the slice doc Notes: `NWListener` can't bind here (fake server is POSIX sockets); **a truncated SSE stream does not surface as a URLSession error** (truncation is caught at the protocol level via `[DONE]`/`finish_reason`, and that guard must not be weakened); the data-protection Keychain rejects unsigned binaries (`-34018`), so storage is the file-based keychain until M5 signing.
- Injection change to know about: `AppShellCoordinator` now takes `makeDatabase` (not `makePersistentStore`) so meetings, settings, and spend share one connection. The no-default guard against M1's test-pollution defect is intact.
- Slices 3–5 pending, unchanged. Slice 1 shipped 2026-07-25.

## Open concerns

- **The leaked v0 Postgres password is still public** on `origin/main` and `origin/legacy` (value deliberately not repeated here — see `git show 7be9733`). Rotate it anywhere else it is reused; that is the only remediation, and history rewriting was considered and rejected. GitHub secret scanning + push protection are **disabled** and should be turned on (repo Settings ▸ Code security).
- `DeepSeekLiveTests` has never been executed. Its gate is proven both ways without network, but the assertions themselves are unrun until the author supplies a key.
- DeepSeek key + small balance still gates live checks 9–11; everything machine-checkable is done without one.
- Pricing defaults unverified (above). Ollama's zero rates are the only ones certainly correct.
- `MeteredProvider` books nothing when a call dies mid-stream without reporting usage — deliberate (the provider *did* bill something, but no counts exist to record). Revisit if real DeepSeek usage shows this often.
- FluidAudio vetting before slice 4: license/size/maintenance **plus** the empirical two-voice `say`-fixture separation run (gate amendment).
- M1 exit criterion 4 (zero-network) still owner-attested until live check 11.
- 7 NEEDS-CLARIFICATION markers in PRD/SPEC stand; none block M2.
