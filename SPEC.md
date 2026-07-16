# SPEC: macapy — Native macOS Agentic Meeting Assistant

**Status:** Draft
**Last updated:** 2026-07-16
**Related PRD:** ./PRD.md
**Prior art:** docs/superpowers/specs/2026-07-16-macapy-revival-design.md (brainstorming outcome + research); the archived Electron/FastAPI v0 is the negative example this design corrects.

## 1. TL;DR

macapy is a single-process native macOS app (Swift 6 / SwiftUI, macOS 26+, Apple Silicon) that captures meeting audio in-process via a Core Audio process tap plus the microphone, transcribes it on-device with Apple's SpeechAnalyzer, and runs an agentic LLM layer over the live transcript using a two-tier cascade — near-free heuristic gates, then a nano-class classifier, then a streaming generator — through a single OpenAI-compatible BYO-key client. Persistence is one SQLite database via GRDB; there is no server, no second runtime, no network traffic except to the user's configured LLM endpoint. The biggest accepted trade-off: macOS 26-only and a single provider implementation in v1, in exchange for one engine, one client surface, and latency headroom everywhere else.

## 2. Context

v0 (Electron + FastAPI + Postgres/pgvector) needed four runtimes to run one meeting and paid for it in latency (3–5s batch transcription, 7.3s query first-token) and fragility. Per PRD.md, the rebuild is local-first, open-source, BYO-key, speed-over-everything. This SPEC covers the whole v1 system across milestones M1–M5 (spine → understanding → live intelligence → memory → launch); each milestone still gets its own implementation plan.

## 3. Goals

- **G1:** Speech-to-visible-transcript < 1s (PRD FR-002); volatile results render immediately, finals replace them in place.
- **G2:** Trigger utterance → first token of a copilot suggestion < 3s (PRD FR-004); internal budget: gates ≈ 0ms, classifier ≤ 1s, generation first-token ≤ 1.5s.
- **G3:** Meeting end → draft artifacts < 60s (PRD FR-008).
- **G4:** Cold start < 2s; active memory < 400MB; UI stays at 60fps during capture.
- **G5:** Default-config AI cost for a 1-hour meeting ≤ $0.25 on the user's key, enforced by a per-meeting cap (PRD FR-015).
- **G6:** Zero audio persisted or transmitted; zero network traffic with no provider configured (PRD FR-003, G4).

## 4. Non-goals

- **N1:** No second STT engine in v1 (no whisper.cpp/Parakeet path; the `STTEngine` protocol keeps the door open).
- **N2:** No native Anthropic client in v1 — fast-follow after launch; OpenRouter covers Claude models meanwhile.
- **N3:** No bundled local LLM inference — users who want local models point the client at Ollama/LM Studio.
- **N4:** No meeting-platform integration (Zoom/Meet/Teams APIs) — audio is the only capture surface (PRD N3).
- **N5:** No plugin/extension system in v1.

## 5. Technical context

- **Language:** Swift 6.x, strict concurrency; SwiftUI for all UI.
- **Platform:** macOS 26+ (Tahoe), Apple Silicon only.
- **Key frameworks:** Core Audio process taps (`CATapDescription`) + AVAudioEngine (capture); SpeechAnalyzer/SpeechTranscriber (STT); EventKit (Reminders/Calendar, M4); Keychain Services (credentials).
- **Dependencies (SPM):** GRDB (SQLite); FluidAudio (diarization, M2); sqlite-vec (embeddings, M4); swift-log. Deliberately nothing else — no networking lib (URLSession), no DI framework.
- **Persistence:** single SQLite database in `~/Library/Application Support/macapy/`; WAL mode.
- **Testing:** swift-testing; fixture audio files; a local fake OpenAI-compatible server for LLM tests.
- **Distribution:** SPM-based Xcode project; Developer ID signed + notarized; Sparkle auto-update (M5).
- **Scale:** single user, meetings up to ~4h, years of history (≈ thousands of meetings, millions of segment rows).

## 6. Proposed design

### 6.1 Architecture overview

Single process, actor-isolated pipeline stages connected by `AsyncStream`s; SwiftUI observes store objects.

```
┌─ CaptureKit ─────────────┐   ┌─ TranscribeKit ─────────────┐
│ Core Audio process tap    │   │ SpeechAnalyzer (system)      │
│  (system audio, 16kHz)   ─┼──▶│ SpeechAnalyzer (mic)         │
│ AVAudioEngine (mic,16kHz)─┼──▶│  volatile + final events     │
└──────────────────────────┘   └──────────────┬───────────────┘
                                              ▼
                               ┌─ TranscriptStore (actor) ─────┐
                               │ ordered segments, you/them,   │
                               │ speaker ids (M2), turn ends   │
                               └──┬──────────┬──────────┬──────┘
                                  ▼          ▼          ▼
                            SwiftUI      PersistKit   AgentKit
                            (panel,      (GRDB,       (copilot
                             window)      async        orchestrator,
                                          writes)      post-meeting
                                                       agent, memory)
                                                          │
                                                          ▼
                                                   ProviderKit
                                                   (OpenAI-compatible
                                                    client, quirks,
                                                    spend metering)
```

Module = SPM target: `CaptureKit`, `TranscribeKit`, `PersistKit`, `AgentKit`, `ProviderKit`, `AppShell` (menu bar extra, floating `NSPanel`, main window). Each module is independently testable; `AppShell` is the only one that imports SwiftUI app plumbing.

**App shell:** menu bar item always present; starting capture opens the compact always-on-top floating panel (live transcript, copilot moments, query box); history/review/settings live in a regular window. Meeting start/stop is manual in v1 (global hotkey + menu bar).

### 6.2 Data model

SQLite via GRDB migrations (schema v1; additive per milestone):

```
meetings(id, title, started_at, ended_at, status, ephemeral)
segments(id, meeting_id→, source TEXT us|them, speaker_id→?, text,
         t_start, t_end, is_final)                       -- M1
speakers(id, meeting_id→, label, embedding BLOB)          -- M2 (FluidAudio)
artifacts(id, meeting_id→, kind summary|decision|action_item|brief,
          payload JSON, status draft|approved|rejected, created_at) -- M2
spend_ledger(id, meeting_id→, model, prompt_tokens, cached_tokens,
             completion_tokens, est_cost_usd, purpose, at) -- M2
memory_entities(id, kind person|project, name, aliases JSON) -- M4
memory_facts(id, entity_id→, fact, source_meeting_id→,
             stated_at, embedding BLOB)                    -- M4
documents(id, meeting_id→?, name, parsed_text) / doc_chunks(…, embedding) -- M4
settings(key, value)
```

Invariants: `segments` is append-only during a meeting (finals may replace their volatile predecessor by id, never reorder). Ephemeral meetings write to an in-memory database and never touch disk. Deleting a meeting cascades to segments/artifacts/spend, and nulls `memory_facts.source_meeting_id` (facts survive unless the user deletes them or uses delete-everything — surfaced in the deletion confirm UI). Embeddings in BLOBs until sqlite-vec lands in M4.

### 6.3 Interfaces / contracts

```swift
protocol STTEngine {                     // one impl in v1: SpeechAnalyzerEngine
  func transcribe(_ stream: AsyncStream<AudioChunk>, source: AudioSource)
      -> AsyncThrowingStream<TranscriptEvent, Error>
}
// TranscriptEvent: .volatile(text, range) | .final(Segment) | .turnEnded(source)

protocol LLMProvider {                   // one impl in v1: OpenAICompatibleClient
  func stream(_ req: CompletionRequest) -> AsyncThrowingStream<LLMEvent, Error>
  func complete<T: Decodable>(_ req: CompletionRequest, as: T.Type) async throws -> T
}
// CompletionRequest carries model id, messages, JSON-schema response format,
// and a Purpose tag (classifier|generation|artifact|memory) for the spend ledger.
```

`OpenAICompatibleClient` is configured per **endpoint profile**: base URL, key (Keychain), model ids for the two tiers (fast/deep), and a **quirks descriptor** — e.g. DeepSeek requires `reasoning_content` passback on continuations and ignores sampling params in thinking mode. Built-in profiles ship for OpenAI, OpenRouter, DeepSeek (with a data-jurisdiction note shown in setup UI), Ollama; users can define custom ones. Streaming structured output: render partial JSON fields as they arrive, validate only the final object.

**Copilot actions** are one enum: `.suggestAnswer`, `.catchUp`, `.flagCommitment` (+ later additions). Each defines its trigger features, its prompt template, and its panel presentation.

### 6.4 Key flows

**Live transcript (G1).** Tap/mic callback → 16kHz chunk → per-source SpeechAnalyzer → volatile event rendered immediately in the panel (grey), final event replaces it (solid) and is queued for a batched GRDB write. No network, no cross-process hop; the <1s budget is spent almost entirely inside SpeechAnalyzer.

**Copilot moment (G2), the two-tier cascade.** On `.turnEnded` from the *them* stream:
1. **Gates (≈0ms, local):** skip if turn < minimum length, user currently speaking, cooldown active (max 1 moment per N seconds), or spending cap reached. Cheap features: interrogative form, user's name mentioned, second-person address, silence-after-question.
2. **Classifier (≤1s):** if gates pass, one fast-tier call (nano-class, e.g. `gpt-5-nano` / `deepseek-v4-flash` non-thinking) with the last ~10 turns returns `{action, confidence, target}` as strict JSON. Below threshold → drop silently. Sensitivity is a user setting mapped to the threshold.
3. **Generation (first token ≤1.5s):** deep-tier streaming call with the assembled context; suggestion streams into the panel, auto-dismisses if ignored (PRD Story 2).

**Context assembly (caching-aware).** Prompt = `[stable system prompt][meeting header + memory brief][rolling summary of older turns][last N turns verbatim][task]`. The transcript block is **append-only** so provider prefix caching keeps hitting (OpenAI auto-cache 0.5×; DeepSeek 0.02×). At ~70% of the context budget, the oldest verbatim turns are folded into the rolling summary *in place* — the head of the prompt never changes, so compaction doesn't invalidate the cached prefix. The rolling summary doubles as the panel's glanceable summary (FR-006) and the catch-up source (FR-005).

**Post-meeting agent (G3).** On meeting end: one structured-output extraction pass (deep tier) over summary + rolling notes → `artifacts` rows in `draft` status → review UI. Approve → EventKit writes (Reminders/Calendar) + status flip; reject → status flip only (FR-009: nothing external without approval). Then the **memory pipeline** (M4): extract facts → entity resolution against `memory_entities` (aliases) → timestamp → embed → store.

**Pre-meeting brief (M4, FR-016).** EventKit calendar read → attendee names matched to entities → fused retrieval (entity match + keyword + vector) → brief artifact surfaced in the panel at meeting start, and open action items from prior meetings with the same people re-surfaced.

**Query box (FR-007).** Same context assembly, user question as task, streamed into the panel. No agentic loop in v1 — one call, meeting-scoped.

## 7. Alternatives considered

### Alt A: Revive the Electron/FastAPI stack (fix v0 in place)
- **What:** keep the four-runtime architecture, migrate batch Whisper to a realtime API, bundle Python + Postgres.
- **Why rejected:** v0's own measurements are the argument — every latency problem traced to process/network hops the architecture forces; install weight ~160MB+ before models; Meetily already occupies "cross-platform webview OSS assistant." Speed-over-everything rules it out.

### Alt B: Fully local LLM (MLX/llama.cpp bundled)
- **What:** ship a local model so no key is ever needed.
- **Why rejected for v1:** copilot/artifact quality drops sharply below hosted frontier-nano tiers; 8–64GB RAM cost on the user's machine during meetings; doubles the inference surface to maintain. Users who want it get it anyway via the Ollama endpoint profile (N3), and the classifier tier could move local post-v1.

### Alt C: whisper.cpp/Parakeet STT for macOS < 26
- **What:** bundle a portable STT engine to widen the supported OS range.
- **Why rejected for v1:** second engine means model downloads, Metal/ANE tuning, and quality-parity testing — the exact surface-multiplication this rebuild strips; SpeechAnalyzer is more accurate and faster than Whisper-large and free. `STTEngine` protocol + backlog entry instead.

### Alt D: First-class multi-provider clients (native OpenAI + Anthropic + …)
- **What:** N native clients with per-provider streaming/caching/tool implementations at launch.
- **Why rejected for v1:** each client is its own streaming/error/caching test matrix; OpenRouter exposes Anthropic/Google models through the compatible surface today. Cost: forgoing Anthropic's 0.10× cache reads until the fast-follow (N2).

### "Do nothing" baseline
- **What happens:** v0 stays dead — it no longer runs (model IDs rotted, stack requires Docker+venv+Node ritual). The author keeps taking manual notes; the portfolio shows an abandoned Electron repo; Granola (cloud) and Hyprnote (passive notes) keep the native niche.
- **Why worse:** every PRD goal fails by default; the researched whitespace (native + local + proactive + BYO-key) stays unclaimed by anyone.

## 8. Cross-cutting concerns

- **Security:** API keys only in Keychain (never in the DB, config files, or logs). App is signed/notarized + hardened runtime; TCC prompts for microphone and system-audio capture with guided UX (PRD edge case). No dynamic code, no third-party analytics SDKs. Blast radius of a compromised machine = the local DB; it is not app-encrypted in v1 — FileVault is the stated mitigation, ephemeral mode the per-meeting alternative [NEEDS CLARIFICATION: is DB-level encryption (SQLCipher) worth its key-management UX before launch?].
- **Privacy:** raw audio exists only in memory (G6). Only assembled text context leaves the machine, only to the user's configured endpoint; a diagnostics view can show exactly what was sent (PRD §7). Endpoint profiles carry data-policy notes (e.g. first-party DeepSeek trains by default, non-GDPR jurisdiction). Deletion: per-meeting cascade, delete-everything, ephemeral mode, pause hotkey (FR-013). No telemetry, ever (PRD N1).
- **Observability:** structured local logging (os_log categories per module); in-app diagnostics panel showing pipeline latency percentiles (G1–G3 measured live), spend ledger per meeting/purpose (FR-015), and STT/LLM error rates. Debug builds assert latency budgets on fixture playback. Nothing leaves the machine.
- **Accessibility / i18n:** full keyboard operability of panel and review flows; VoiceOver labels on all controls. Locale scope [NEEDS CLARIFICATION: English-only v1 vs all SpeechAnalyzer locales — carried from PRD].

## 9. Rollout & migration

- **Greenfield repo reset:** archive Electron/FastAPI v0 to a `legacy` branch; Swift project starts clean at root. Old Postgres data is not migrated (v0 was never in real use).
- **Milestone-gated rollout (maps to docs/milestones.md):** M1 spine → M2 diarization + post-meeting agent + provider layer → M3 copilot cascade → M4 memory/RAG/briefs → M5 signed/notarized public release with Sparkle updates.
- **Kill switches:** AI features are globally toggleable (app remains a pure local transcriber — PRD Story 1); copilot sensitivity down to "off"; per-meeting spending cap halts AI, never capture.
- **Schema migrations:** GRDB migrator, additive per milestone, forward-only pre-1.0.

## 10. Testing & validation

- **Unit:** gate logic (feature extraction, cooldowns, cap enforcement); context assembler (property test: compaction never mutates the prompt prefix; budget never exceeded); quirks layer per endpoint profile; artifact JSON-schema decoding incl. malformed/partial payloads.
- **Integration:** fake OpenAI-compatible server exercising streaming, structured output, `reasoning_content` passback, mid-stream disconnects, 429/5xx degradation (PRD edge cases); STT pipeline driven by fixture audio files through the real SpeechAnalyzer; GRDB migration round-trips; EventKit writes against a test calendar.
- **End-to-end / performance:** scripted fixture-meeting playback measuring G1–G4 budgets on Apple Silicon base hardware; 3-hour synthetic meeting for memory/context behavior (PRD edge case).
- **In-use validation:** the diagnostics panel *is* the production instrumentation — dogfooding per PRD G2 with latency percentiles and spend visible; a launch-blocking checklist derives from PRD G1 (clone-to-run < 10 min, verified by a clean-machine run).
- **Verification discipline (per repo conventions):** each milestone's acceptance checks are written in its milestone doc *before* implementation begins.

## 11. Risks & open questions

- **Risk:** SpeechAnalyzer accuracy on accents/crosstalk/jargon is outside our control. — **Mitigation:** `STTEngine` protocol; fallback engine is a scoped backlog item, not a redesign.
- **Risk:** Copilot false positives make the panel annoying (the #1 way this product dies). — **Mitigation:** conservative default threshold, sensitivity setting, cooldowns, silent drops below confidence; M3 exit criteria include a measured false-positive rate during dogfooding.
- **Risk:** Classifier-tier spend creeps on long meetings. — **Mitigation:** gates before every call, prefix caching, spend ledger + cap; G5 measured in diagnostics.
- **Risk:** Core Audio process-tap API surface changes (macOS point releases have broken tap behavior before). — **Mitigation:** capture isolated in `CaptureKit` behind one interface; CI smoke test on OS updates.
- **Risk:** Single-developer scope creep across 5 milestones. — **Mitigation:** milestone/handoff discipline from global conventions; PRD non-goals enforced at review.
- [NEEDS CLARIFICATION: SQLCipher vs FileVault-only before public launch (§8 Security).]
- [NEEDS CLARIFICATION: v1 locale scope (§8).]
- [NEEDS CLARIFICATION: calendar sources for FR-016 — system EventKit only is the working assumption.]
- [NEEDS CLARIFICATION: dual-simultaneous-meeting audio (PRD §8) — working assumption: all system audio is one meeting in v1.]
