# Slice 4 — Diarization (FluidAudio) + Memory-Watch Hardening

**Status:** pending
**Plan written:** 2026-07-17 (M2 planning session; acceptance checks precede implementation)
**References:** ../../SPEC.md §5 (FluidAudio dep), §6.2 (speakers schema), G4; ./milestone.md exit criteria 4 & 7; M1 backlog (unbounded-stream memory watch).

The plan for this slice is also its record.

## Design

### Decisions (planning, 2026-07-17)

1. **FluidAudio** (second external SPM dep after GRDB — license, size, and maintenance posture vetted and recorded in Notes before adding). Vetting also includes an **empirical sanity run against the two-voice `say` fixture** before the slice commits to that fixture design — check 1 silently assumes TTS voices separate well under diarization, and that assumption must be tested first (amendment from kickoff gate 2026-07-24). Diarization runs on the **them stream only**; the mic stream is the user by definition (M1's you/them split is untouched).
2. **Schema migration adds `speakers`** (SPEC §6.2: label, embedding BLOB, camelCase); `segments.speakerId` starts being populated for them-segments. Within-meeting clustering only; labels are automatic ("Speaker 1", "Speaker 2", …). No renaming, no cross-meeting identity (M4 non-goal).
3. **Rendering:** speaker chips per the slice-1 design in panel and meeting detail; segments without a speaker (mic side, or pre-cluster confidence) render exactly as in M1.
4. **Pipeline placement:** diarization consumes the same them-stream audio the analyzer gets (fan-out in TranscribeKit), attributes speaker ids to final segments by time overlap; volatile rendering never waits on diarization (G1 must be unaffected).
5. **Memory-watch hardening (G4 pull-in):** the capture→analyzer feed gets a bounded buffer with an explicit overflow policy (drop-oldest + surfaced drop counter) so an analyzer stall can no longer grow memory without bound; diagnostics gains an app-memory-footprint readout next to the drop counter.

## Acceptance checks (written before implementation)

Machine-verifiable:

1. Two-voice fixture (machine-generated with two distinct `say` voices, M1 fixture technique) → them-segments carry ≥ 2 distinct speaker ids, stable across the fixture (same voice ⇒ same id).
2. Mic-stream segments never get a diarization speaker id; all M1 you/them tests stay green unmodified.
3. G1 regression: fixture-playback harness p95 still passes with diarization active.
4. Stall test: a fake analyzer that stops consuming ⇒ buffer stays at its bound, drop counter increments, process memory stays flat (no unbounded growth).
5. Migration round-trip for `speakers`; meeting deletion cascades speaker rows.
6. Full `swift test` green; `xcodebuild` clean.

User-live:

7. A real multi-party meeting (≥ 2 remote participants): panel and meeting detail show ≥ 2 distinct, consistently-assigned them-speakers; you-attribution unchanged. (Doubles as milestone exit criterion 4.)
8. Memory readout in diagnostics stays < 400MB across a ~1-hour meeting (milestone exit criterion 7).

## Checklist

- [x] Acceptance checks user-reviewed (M2 kickoff gate — approved 2026-07-24, amendments in ./milestone.md Integration notes)
- [ ] FluidAudio vetting note (license/size/maintenance) + empirical two-voice `say`-fixture separation run + dep added
- [ ] `speakers` migration + segment attribution by time overlap (TDD)
- [ ] Them-stream fan-out + diarization actor
- [ ] Two-voice fixture + clustering tests
- [ ] Bounded feed buffer + drop counter + stall test
- [ ] Diagnostics memory readout
- [ ] Speaker chips in panel + meeting detail (to slice-1 design)
- [ ] Verifier re-runs checks 1–6 with evidence
- [ ] Live checks 7–8 walked with author
- [ ] Ship rituals: slice table, integration notes, handoff, commit

## Notes / dead ends

(append as work proceeds)
