# Slice 3 — Post-Meeting Agent v1: Extraction → Draft Artifacts → Review

**Status:** pending
**Plan written:** 2026-07-17 (M2 planning session; acceptance checks precede implementation)
**References:** ../../SPEC.md §6.4 (post-meeting agent, G3), §6.2 (artifacts schema); PRD FR-008, FR-009 (review only — EventKit is M4), Story 4; ./milestone.md exit criteria 2 & 6.

The plan for this slice is also its record.

## Design

### Decisions (planning, 2026-07-17)

1. **`AgentKit` gets its first real component:** a post-meeting extractor triggered on meeting end (from `SessionController` stop, non-ephemeral meetings with a configured provider only). One deep-tier structured-output pass over the final transcript → `artifacts` rows (`summary`, `decision`, `action_item` with owner/deadline where stated) in `draft` status.
2. **No rolling summary in M2** (that's M3's context assembly). Long transcripts are handled by chunked map-reduce extraction (per-chunk extract → merge pass) — the mechanism must not hard-fail at any meeting length (PRD 3h+ edge case); exact chunk budget decided at build and recorded here.
3. **Schema migration adds `artifacts`** (SPEC §6.2, camelCase). Deleting a meeting cascades to artifacts (invariant already specced).
4. **Review UI lives in meeting detail** (new screen, built to slice-1 design): artifacts pane with per-item approve/reject. Approve/reject **only flips status** — no external effect of any kind in M2.
5. **Retroactive generation** (PRD edge case): if extraction failed or no provider was configured at meeting end, meeting detail offers "generate artifacts" once a provider is available. Same code path as the automatic trigger.
6. **Spend + cap integration:** extraction calls carry `Purpose.artifact`, row into the ledger, and respect the cap gate (cap reached ⇒ visible halt notice, transcript untouched).
7. **G3 measurement:** wall time from meeting-end to last artifact row written, surfaced in diagnostics; authoritative check is live on DeepSeek.

## Acceptance checks (written before implementation)

Machine-verifiable (fake server from slice 2):

1. End-to-end: meeting end → extraction request issued → artifacts rows land in `draft` with correct kinds and payloads (scripted response).
2. Decode robustness: malformed / truncated / schema-violating extraction payloads produce a typed failure and zero partial artifact rows (SPEC §10 unit case).
3. Approve flips status to `approved`, reject to `rejected`; nothing else in the DB or system changes (asserted: row diff only).
4. Long-transcript path: a synthetic 3h-scale transcript completes extraction via chunked map-reduce without error.
5. Retroactive path: extraction with no provider ⇒ meeting marked artifacts-pending, no crash; invoking generate later (fake server up) produces the same artifacts as the automatic path.
6. Cap: cap-reached before extraction ⇒ no request issued, visible-halt state set, meeting/transcript rows intact.
7. Ephemeral meetings never trigger extraction and never write artifacts.
8. Full `swift test` green; `xcodebuild` clean.

User-live (DeepSeek):

9. A real meeting ends → summary + decisions + action items visible in meeting detail **within 60s** (G3; time from diagnostics), owners/deadlines present where stated in the conversation.
10. Author walks approve on one item and reject on another; statuses flip; nothing appears anywhere outside the app.
11. Retroactive flow: end a meeting with network disabled → artifacts pending; re-enable → generate → drafts appear.

## Checklist

- [x] Acceptance checks user-reviewed (M2 kickoff gate — approved 2026-07-24, amendments in ./milestone.md Integration notes)
- [ ] `artifacts` migration + GRDB records
- [ ] Extraction prompt + JSON schema + decode layer (TDD, fake server)
- [ ] Chunked map-reduce for long transcripts
- [ ] Meeting-end trigger + retroactive generate path
- [ ] Meeting detail screen with artifacts pane + review flow (to slice-1 design)
- [ ] Spend purpose tagging + cap-halt notice
- [ ] Critic pass (risky slice: agent correctness + data integrity)
- [ ] Verifier re-runs checks 1–8 with evidence
- [ ] Live checks 9–11 walked with author (G3 number recorded in milestone.md)
- [ ] Ship rituals: slice table, integration notes, handoff, commit

## Notes / dead ends

(append as work proceeds)
