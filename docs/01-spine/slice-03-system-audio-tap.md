# Slice 3 — System-Audio Process Tap → Dual-Stream You/Them

**Status:** pending
**Plan approved:** pending user review (front-loaded batch for slices 2–5, 2026-07-16)
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

## Acceptance checks (written before implementation; user review pending)

Machine-verifiable:

1. Dual-fake-source pipeline test: two fake sources emit overlapping scripted events; the store interleaves segments correctly by `tStart` with correct You/Them source tags.
2. Concurrent real-engine test: two fixture wavs transcribed through two concurrent `SpeechAnalyzerEngine.transcribe()` calls both complete with sane transcripts (validates the two-analyzer resource assumption on real hardware).
3. All slice-1/2 tests pass unmodified; full `swift test` green; `xcodebuild` clean.

User-live:

4. First system-audio start triggers the system-audio TCC prompt with our usage string; grant proceeds.
5. Play a video with speech while staying silent → lines appear labeled **Them**.
6. Speak → lines appear labeled **You**.
7. **With headphones connected**, system audio is still captured and transcribed (exit criterion 3).
8. Real-meeting dogfood: dual-source transcript live in the panel for a real call.

## Checklist

- [ ] Acceptance checks user-reviewed (front-loaded batch gate)
- [ ] Config step: entitlements/sandbox decision + usage key + user-walked TCC prompt (exact key recorded in Notes)
- [ ] Builder: SystemAudioCapture (tap, aggregate device, IOProc; tests where fakeable)
- [ ] Builder: pipeline second source + panel You/Them labels (dual-fake test red→green)
- [ ] Builder: concurrent real-engine fixture test
- [ ] Critic pass (IOProc real-time safety, teardown ordering, tap lifecycle)
- [ ] Verifier: independent re-run of checks 1–3 with evidence
- [ ] Live checks 4–8 walked with the user
- [ ] Ship rituals: milestone table, integration notes (incl. sandbox + usage-key findings), handoff, final commit

## Notes / dead ends

(append as work proceeds)
