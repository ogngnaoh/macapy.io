# macapy.io Revival — Design Direction & Milestone Outline

**Date:** 2026-07-16
**Status:** Approved (brainstorming session outcome)
**Role of this doc:** Input to the PRD/SPEC interview (doc-system). Records the direction, decisions, and research from the revival brainstorming session. The authoritative product/system documents are `docs/PRD.md` and `docs/SPEC.md` once regenerated; where they disagree with this doc, they win.

## Context

macapy.io v0 was an AI meeting assistant built as Electron + FastAPI + PostgreSQL/pgvector. A teardown of that implementation found four runtimes doing one desktop app's job:

- To run one meeting: Python venv + uvicorn (:8000) + Postgres/pgvector in Docker (:5432) + Alembic migrations + Vite (:5173) + Electron. Electron did **zero** audio or AI work — it was a Chromium runtime serving as a window and keychain.
- One transcript line traveled: ScreenCaptureKit callback (via PyObjC) → Python module-global dict → asyncio queue → Whisper API (3–5s) → sentence batching (up to 3s more) → Postgres commit → WebSocket → renderer. Measured query first-token latency: 7.3s.
- Known fragility: a deliberate crash workaround skipping ScreenCaptureKit teardown (SIGTRAP through PyObjC), per-chunk scipy FFT resampling, duplicated capture/transcription services, dead API stubs, a half-finished Realtime API migration that still used whisper-1.
- Postgres + pgvector + Docker to store plain text and 1536-dim vectors — absurd weight for a local desktop app.

**The revival:** strip to zero and rebuild as an **open-source, native macOS app (Swift/SwiftUI), local-first, users clone and bring their own API credentials — not SaaS.** Top priority: **efficiency and speed over everything.**

## Product identity

**A proactive in-meeting copilot + post-meeting agent** for general knowledge-worker meetings.

- *Proactive in-meeting copilot:* watches the live transcript and acts unprompted at the right moments — surfaces answers when a question is directed at the user, pulls relevant context, flags commitments as they're made. Genuinely reactive to context, not timer-driven like v0.
- *Post-meeting agent:* autonomously produces the artifacts after a meeting — action items, decisions, follow-ups — and maintains memory across meetings.
- The on-demand query box is a supporting feature, not the centerpiece.
- Interview-candidate mode (v0's primary persona) becomes a later layer, not the core identity.

## Positioning (from landscape research)

The unclaimed market position: **"Granola's bot-free UX, but truly native Swift, actually local, with real speaker diarization and a proactive + post-meeting agent — BYO keys."**

- **Bot-join SaaS tools** (Otter, Fireflies, Fathom, tl;dv): the visible bot kills candor, creates consent-law exposure (11 all-party consent states; Otter faces a consent class action), and enterprises increasingly block them. All are cloud-first SaaS with pricing rug-pull history.
- **Granola** — strongest native bot-free incumbent, but *not local-first*: audio goes to Deepgram/AssemblyAI, notes to OpenAI/Anthropic, stored in AWS, trains on user data by default (org opt-out only at $35 Enterprise tier). No reliable speaker labels (its #1 user complaint), no audio playback, no cross-meeting proactivity.
- **Hyprnote** (YC S25) — the closest OSS analog: native macOS, local-first, mic+system audio on-device, BYOK. But it's a note-taker — no proactive copilot, no post-meeting agent story. The project to watch and differentiate against.
- **Meetily** — most mature cross-platform OSS (Rust + Tauri/Next.js, MIT, local STT + Ollama), but a webview app, not native-fast.
- **Cluely** — cautionary tale: proved demand for live copilots, burned trust with stealth/cheating positioning (plus an 83k-user breach and ~5–10s real latency vs "300ms" claims). **We position explicitly non-stealth** — trust is a differentiator.

Sources: granola.ai/blog + docs, itsconvo.com Granola review, basilai.app architecture comparison, github.com/fastrepl/hyprnote (+ HN 44725306), github.com/Zackriya-Solutions/meetily, tldv.io Cluely review, circleback.ai bot-vs-desktop, aitooldiscovery.com Otter/Granola Reddit digests.

## Pain-point research → feature ideas

Ranked pain points from meeting-culture research (Reddit, HN, HBR, surveys), each with the feature a *local, always-present, no-bot, cross-meeting-memory* app can uniquely build:

1. **Meeting overload / back-to-back fatigue** (78% say meetings block real work) → calendar-aware pre-skim; flag skippable/async-able recurring meetings. *(Backlog)*
2. **Can't take notes AND participate** → capture everything locally, zero typing; user's scratch notes fused with transcript. *(Core, M1+)*
3. **Action items die** (44% never completed) → extract owner+deadline, create real Reminders/Calendar entries via EventKit, re-surface open items when the same people meet again. *(M4)*
4. **Zoning out / losing the thread** (24% admit sleeping on calls) → **catch-up glance**: private "last 60 seconds you missed" recap. *(M3)*
5. **Bot stigma + privacy** → no bot ever joins; system-audio capture; local-first; BYO keys. *(Architecture)*
6. **"What was decided last time?" black hole** → persistent local memory per person/project; surface prior commitments when attendees rejoin. *(M4)*
7. **Pre-meeting context scramble** → on calendar event, auto-assemble a brief from prior meetings + docs with those attendees. *(M4)*
8. **Multilingual / accents / jargon** (22% cite accents as major obstacle) → live plain-language paraphrase + jargon glossary. *(Backlog — continuous LLM cost)*
9. **Put on the spot** → detect a question aimed at the user, privately surface a suggested answer + relevant fact. *(M3, copilot core)*
10. **Status meetings that could've been an email** → recognize recurring status meetings, pre-draft the user's update. *(Backlog)*

Sources: Atlassian/Flowtrace meeting statistics, HBR "Stop Zoning Out in Zoom Meetings", Fellow action-item research, granola.ai consent blog, Cornell 2024 algorithmic-monitoring study, arXiv 2504.18988 (multilingual meetings), Forbes/Truity on interruption dynamics.

## Technical state of the art (mid-2026)

- **Apple SpeechAnalyzer/SpeechTranscriber (macOS 26+):** most accurate on-device STT tested — beats all Whisper models, ~55% faster than MacWhisper Large-v3-Turbo, ~30 locales, streaming with volatile+final results, free, no network. Caveats: macOS 26 only, no built-in diarization, tap audio at 16kHz to avoid ~200ms resample cost.
- **Core Audio process taps** (`CATapDescription`, macOS 14.4+): clean audio-only system capture — **no screen-recording permission**, no capture-session overhead. Beats ScreenCaptureKit for an audio-only assistant (v0 used SCK because Python forced its hand). Reference: insidegui/AudioCap.
- **FluidAudio diarization** (pyannote Community-1 ported to CoreML/ANE): 0.017 RTF (~60× realtime) on M1. Local speaker diarization is now solved — v0 called it a non-goal purely on feasibility.
- **Fallback engines for older macOS (backlog):** whisper.cpp (~10× realtime large-v3 via Metal) or Parakeet via FluidAudio (~2.5% WER, 66MB on ANE).

Sources: get-inscribe.com Apple speech benchmark, MacRumors WWDC25 coverage, dgrlabs.co system-audio capture guide, Apple Core Audio taps docs, github.com/FluidInference/FluidAudio, inference.plus diarization benchmark, macparakeet.com.

## Decisions locked

| Decision | Choice |
|---|---|
| Product identity | Proactive in-meeting copilot + post-meeting agent |
| Primary user | General knowledge-worker meetings (interview mode = later layer) |
| Platform | Native macOS, Swift/SwiftUI; **macOS 26+ only** (STT behind a protocol so older-OS engines can be added without redesign) |
| STT | Apple SpeechAnalyzer/SpeechTranscriber, on-device, streaming |
| Audio capture | Core Audio process taps (system) + AVAudioEngine (mic), dual-stream, in-process |
| Diarization | FluidAudio (CoreML/ANE) as its own early slice (M2); M1 ships you-vs-them from the two streams |
| Persistence | SQLite (GRDB); vectors via sqlite-vec when RAG lands |
| App shell | Menu bar presence + compact floating panel (live) + full window (history/review); full screen/state inventory in a dedicated design session |
| Sequencing | Spine first — M1 is the capture→transcribe→store engine, independently useful |
| Keys/secrets | User's own API keys in macOS Keychain |
| Positioning | Explicitly non-stealth; trust as differentiator |

## Milestone outline (draft — finalized after PRD/SPEC)

- **M1 — The Spine** *(ships: the fastest fully-local live meeting transcriber on macOS)* — app skeleton; menu bar + minimal floating panel; process tap + mic capture; SpeechAnalyzer streaming behind an `STTEngine` protocol; SQLite persistence; live transcript with you/them labels; manual start/stop.
- **M2 — Understanding** *(ships: meetings end with real notes and named speakers)* — FluidAudio diarization; BYO-key setup + LLM provider layer; post-meeting agent v1 (summary, decisions, action items with owner+deadline); history + search. *Gate: agentic-reasoning architecture settled (SPEC or focused follow-up) before this milestone's design.*
- **M3 — Live intelligence** *(ships: copilot moments during meetings)* — proactive copilot loop (question-directed-at-you detection → private suggestions); catch-up glance; rolling glanceable summaries; on-demand streaming query box.
- **M4 — Memory & context** *(ships: an assistant that remembers)* — cross-meeting memory (people, projects, commitments); action items → EventKit + re-surfacing; document RAG (sqlite-vec); pre-meeting briefs via calendar.
- **M5 — Launch** *(ships: public OSS release)* — onboarding + permissions flow; notarized builds + Sparkle; clone-and-run docs; license (MIT suggested).
- **Post-launch backlog:** live paraphrase/jargon glossary; interview mode; older-macOS STT engines; status-meeting pre-drafts; skippable-meeting detection; export/integrations.

## Pipeline from here

1. ✅ This design doc (committed).
2. **doc-system: PRD.md + SPEC.md** — thorough interview + research; SPEC absorbs the agentic-LLM-reasoning architecture discussion (orchestration, provider abstraction, context/prompt architecture, cost controls).
3. Derive `docs/milestones.md` + `docs/01-spine/{milestone,handoff}.md` from the approved PRD/SPEC.
4. Old-code disposition (user confirms): archive Electron/FastAPI code to a `legacy` branch; brownfield inventory runs before archival; regenerate CLAUDE.md once the new repo shape exists.
5. Frontend design session (full screen/state inventory).
6. M1 implementation planning. No Swift code before this.
