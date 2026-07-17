# Slice 3 — System-Audio Process Tap → Dual-Stream You/Them

**Status:** active
**Plan approved:** 2026-07-16 (front-loaded batch review of slices 2–5; acceptance checks reviewed before implementation)
**References:** ../../SPEC.md §6.1, §6.4, ./milestone.md, ./slice-02-mic-live-transcript.md

The plan for this slice is also its record (working-doc convention). Checklist below is current state.

## Design

### Decisions (made during planning, 2026-07-16)

1. **Config before code.** TCC/entitlement misconfiguration presents as silent audio and burns debugging time, so the slice opens with: the sandbox decision, the usage-description key, a build, and a user-walked TCC prompt — before any pipeline work.
2. **Sandbox decision (deferred from slice 1): unsandboxed.** Distribution is Developer ID + notarization (SPEC §5), not App Store; process taps and App Sandbox are a known bad mix. Entitlements stay minimal. Validate hands-on this slice; record as the SPEC §8 clarification.
3. **Usage key:** believed to be `NSAudioCaptureUsageDescription` (system-audio-recording TCC for process taps) — the exact key is verified hands-on as step one; correct key recorded here.
4. **Tap shape:** global mixdown `CATapDescription` excluding our own process (tap is pre-output, so exit criterion 3 — capture with headphones connected — holds by construction). `AudioHardwareCreateProcessTap` + an aggregate device wrapping the tap; IOProc callback → `BufferConverter` (reused from slice 2) → yield. API presence confirmed against SDK 26.5 during planning (`CoreAudio/AudioHardwareTapping.h`, macOS 14.2+; `bundleIDs`/`processRestoreEnabled` props are macOS 26-only).
5. **`pause()` stops the IOProc** — same protocol contract as `MicCapture`, no special-casing.
6. **No engine or store changes.** The pipeline constructs two capture sources and two `transcribe()` calls; both event tasks funnel into the one `TranscriptStore`. Interleaving comes free from the store's ordered insert plus the shared session-relative timeline designed in slice 2 (decision 6 there).
7. **Panel:** per-line "You"/"Them" label derived from `segment.source` (`.mic` → You, `.system` → Them). Still functional-minimal.

### Layout

```
Sources/CaptureKit/SystemAudioCapture.swift  actor; CATapDescription tap → aggregate device → IOProc → convert → yield
Sources/AppShell/MeetingPipeline.swift       gains second source; no structural change
Sources/AppShell/PanelView.swift             You/Them labels
Tests/AppShellTests/                         dual-fake-source interleave test
Tests/TranscribeKitTests/                    concurrent dual real-engine fixture test
App/Info.plist                               + system-audio usage key (exact key verified hands-on)
App/macapy.entitlements                      sandbox decision recorded (unsandboxed)
```

### Components

```swift
// CaptureKit
public actor SystemAudioCapture: AudioCaptureSource {
    public init()
    public nonisolated var source: AudioSource { .system }
    // start(format:): build CATapDescription (global mixdown, exclude own PID),
    // AudioHardwareCreateProcessTap, aggregate device w/ tap, install IOProc,
    // convert via BufferConverter, yield AudioChunks. stop(): tear down IOProc,
    // destroy aggregate + tap. pause()/resume(): stop/start the IOProc only.
}
```

## Acceptance checks (written before implementation; user-reviewed 2026-07-16)

Machine-verifiable:

1. Dual-fake-source pipeline test: two fake sources emit overlapping scripted events; the store interleaves segments correctly by `tStart` with correct You/Them source tags. *(Added 2026-07-17, carried from slice-2 verifier caveat, user-notified at slice-2 ship:)* the same test also asserts per-source cross-event timestamps are non-decreasing.
2. Concurrent real-engine test: two fixture wavs transcribed through two concurrent `SpeechAnalyzerEngine.transcribe()` calls both complete with sane transcripts (validates the two-analyzer resource assumption on real hardware).
3. All slice-1/2 tests pass unmodified; full `swift test` green; `xcodebuild` clean.

User-live:

4. First system-audio start triggers the system-audio TCC prompt with our usage string; grant proceeds.
5. Play a video with speech while staying silent → lines appear labeled **Them**.
6. Speak → lines appear labeled **You**.
7. **With headphones connected**, system audio is still captured and transcribed (exit criterion 3).
8. Real-meeting dogfood: dual-source transcript live in the panel for a real call.

## Checklist

- [x] Acceptance checks user-reviewed 2026-07-16 (front-loaded batch gate)
- [x] Config step: entitlements/sandbox decision + usage key verified & shipped (ef5ec58; key + technique in Notes); user walked the TCC prompt 2026-07-17 — prompt shown with our string, grant OK, no crash (live check 4 PASS early)
- [ ] Builder: SystemAudioCapture (tap, aggregate device, IOProc; tests where fakeable)
- [ ] Builder: pipeline second source + panel You/Them labels (dual-fake test red→green)
- [ ] Builder: concurrent real-engine fixture test
- [ ] Critic pass (IOProc real-time safety, teardown ordering, tap lifecycle)
- [ ] Verifier: independent re-run of checks 1–3 with evidence
- [ ] Live checks 4–8 walked with the user
- [ ] Ship rituals: milestone table, integration notes (incl. sandbox + usage-key findings), handoff, final commit

## Notes / dead ends

(append as work proceeds)

- 2026-07-17 (builder, Phase A — config/TCC de-risk, ef5ec58): usage key **`NSAudioCaptureUsageDescription`** confirmed (service `kTCCServiceAudioCapture`). Verification technique worth reusing: TCC keys are NOT in public SDK headers anywhere — the authoritative mapping is the adjacent service→key string pairs inside `/System/Library/PrivateFrameworks/TCC.framework/Support/tccd`. Tap API availability re-confirmed in SDK 26.5 (create/destroy macos 14.2+, `bundleIDs`/`processRestoreEnabled` 26.0+). Key verified present in the **built** bundle; codesign shows no sandbox entitlement (unsandboxed decision recorded in entitlements comment). Phase A tap: mono global mixdown excluding own PID, `.unmuted`, auto-start aggregate device, deliberately **no-op IOProc** (yields nothing) — the checkpoint only proves prompt-appears-and-grant-survives. Gotcha: `CATapDescription.uuid.uuidString` *is* the tap UID for the aggregate's tap list — no runtime `kAudioTapPropertyUID` query needed. Note: from Phase A on, production spins up two concurrent SpeechAnalyzers (system one gets an empty stream and finalizes cleanly); the real concurrent-resource proof stays machine check 2 in Phase B.
