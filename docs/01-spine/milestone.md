# Milestone 01 — The Spine

**Status:** active
**References:** ../../PRD.md (FR-001, FR-002, FR-003, FR-010 partial, FR-013 partial, FR-014 partial), ../../SPEC.md §6

## Goal

Ship the fastest fully-local live meeting transcriber on macOS — the author can run a real meeting end-to-end (capture → live you/them transcript → persisted history) with zero credentials and zero network traffic.

## Scope

- Swift 6 / SwiftUI app skeleton with the SPM module layout from SPEC §6.1 (`AppShell`, `CaptureKit`, `TranscribeKit`, `PersistKit`; `AgentKit`/`ProviderKit` as empty stubs).
- Menu bar presence + compact always-on-top floating panel; manual start/stop with global hotkey.
- Microphone capture via AVAudioEngine; system-audio capture via Core Audio process tap (`CATapDescription`), both at 16kHz.
- On-device streaming transcription via SpeechAnalyzer behind the `STTEngine` protocol (volatile results render grey, finals replace in place).
- SQLite persistence via GRDB (`meetings`, `segments`, `settings`; schema v1 from SPEC §6.2), including ephemeral (in-memory) mode and pause-capture hotkey.
- Minimal past-meetings list to reopen a persisted transcript (verification surface, not the M2 history feature).
- Latency instrumentation + fixture-playback harness measuring the G1 budget.

## Non-goals

- No diarization (you/them comes free from the two streams; speakers are M2).
- No LLM calls of any kind — `ProviderKit` stays a stub; no key-entry UI.
- No search, no artifacts, no memory (M2+).
- No visual design investment — panel is functional-minimal until the dedicated frontend design session.
- No support for macOS < 26, no second STT engine.

## Slices

| # | Slice (end-to-end, independently shippable) | Status |
|---|---|---|
| 1 | App skeleton: SPM targets, menu bar item, empty floating panel, start/stop state machine | active |
| 2 | Mic → SpeechAnalyzer → live transcript rendering in panel (volatile/final) | pending |
| 3 | System-audio process tap → dual-stream transcription → you/them labels | pending |
| 4 | GRDB persistence + meeting lifecycle + ephemeral mode + pause hotkey + minimal history list | pending |
| 5 | Latency instrumentation, diagnostics basics, fixture-playback test harness proving G1 | pending |

## Integration notes

(Decisions and dead ends worth remembering — append as work proceeds.)

- 2026-07-16: Milestone derived from approved SPEC; no code exists yet. v0 (Electron/FastAPI) still occupies the repo pending archival decision.

## Exit criteria

Written before implementation (verification convention):

1. Fixture-playback harness shows speech-to-visible-transcript < 1s (G1) on base Apple Silicon.
2. Author runs one real meeting end-to-end: dual-source transcript live in the panel, persisted, reopenable from the list.
3. Capture works with headphones connected (process tap is pre-output).
4. Zero-credential, zero-network run confirmed (no outbound traffic observed during a full meeting).
5. Cold start < 2s; pause hotkey verifiably halts capture; ephemeral meeting leaves no rows on disk.
