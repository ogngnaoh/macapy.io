# Slice 4 — GRDB Persistence, Meeting Lifecycle, Ephemeral Mode, Pause Hotkey, History List

**Status:** pending
**Plan approved:** 2026-07-16 (front-loaded batch review of slices 2–5; acceptance checks reviewed before implementation)
**References:** ../../SPEC.md §6.2, ./milestone.md, ./slice-02-mic-live-transcript.md

The plan for this slice is also its record (working-doc convention). Checklist below is current state.

## Design

### Decisions (made during planning, 2026-07-16)

1. **GRDB becomes the package's first external dependency** (SPEC §5 sanctioned). `PersistKit` gains deps on GRDB and TranscribeKit (for `Segment`).
2. **One database wrapper, two factories:** `MacapyDatabase.onDisk(at:)` (WAL, migrator v1) and `.inMemory()`. Ephemeral mode and **all tests** use the same in-memory code path — which is why ephemeral is nearly free and trustworthy: zero disk rows by construction.
3. **Schema v1** (SPEC §6.2): `meetings(id, title, started_at, ended_at, status, ephemeral)`, `segments(id, meeting_id FK cascade, source TEXT us|them, text, t_start, t_end, is_final)`, `settings(key, value)`. Code keeps `AudioSource.mic/.system`; PersistKit maps to `us`/`them` at the row boundary.
4. **Meeting lifecycle is owned by `MeetingPipeline`:** creates the `meetings` row in `start()`, closes it in `stop()`. `start` takes `PersistenceMode { .persistent(MeetingStore), .ephemeral }`; ephemeral builds a fresh in-memory store per meeting — identical write path.
5. **`SegmentWriter` actor** subscribes to `TranscriptStore.finalsStream()` and batches inserts: flush on ~1s debounce or 25 segments, plus a final flush on meeting end. Segments append-only during a meeting (SPEC invariant).
6. **`SessionController` grows `.paused(startedAt:)` additively** plus `pause()/resume()`; `toggle()`'s guard changes from `isCapturing` to `state != .idle` (stop works from paused). No slice-1 test touches `.paused`, so they pass unmodified; `PanelView`'s exhaustive switch forces the paused-UI update at compile time.
7. **Pause hotkey ⌥⌘P** → `coordinator.togglePause()` → `pipeline.pause()` — a **capture-layer halt** (`AudioCaptureSource.pause()`, designed into the protocol in slice 2) so pause verifiably stops audio delivery, not just UI. Panel shows a Paused state.
8. **History:** `HistoryView` replaces the placeholder — fetch-on-appear list from `MeetingStore.listMeetings()` → read-only transcript detail. No `ValueObservation` in M1 (verification surface, not the M2 feature).
9. **Ephemeral control:** menu-bar toggle applying to the *next* meeting.
10. **DB location:** `~/Library/Application Support/macapy/macapy.sqlite` (SPEC §5).

### Layout

```
Sources/PersistKit/MacapyDatabase.swift   onDisk/inMemory factories + migrator v1
Sources/PersistKit/MeetingRecord.swift    row types + AudioSource↔us/them mapping
Sources/PersistKit/MeetingStore.swift     actor: begin/end/append/list/segments/delete
Sources/PersistKit/SegmentWriter.swift    actor: batched finalsStream consumer
Sources/AppShell/SessionController.swift  .paused + pause()/resume()
Sources/AppShell/HotKey.swift             second hotkey ⌥⌘P
Sources/AppShell/MeetingPipeline.swift    PersistenceMode + meeting row lifecycle
Sources/AppShell/HistoryView.swift        replaces HistoryPlaceholderView
Tests/PersistKitTests/                    migration/lifecycle/writer/cascade/ephemeral
Tests/AppShellTests/                      .paused transition matrix
Package.swift                             + GRDB; PersistKit deps; PersistKitTests target
```

### Components

```swift
// PersistKit
public struct MacapyDatabase: Sendable {
    public static func onDisk(at url: URL) throws -> MacapyDatabase   // WAL + migrator "v1"
    public static func inMemory() throws -> MacapyDatabase            // ephemeral + tests
}

public struct MeetingRecord: Codable, Sendable, Identifiable {
    public let id: UUID; public var title: String
    public var startedAt: Date; public var endedAt: Date?
    public var status: String; public var ephemeral: Bool
}

public actor MeetingStore {
    public init(database: MacapyDatabase)
    public func beginMeeting(startedAt: Date, ephemeral: Bool) throws -> MeetingRecord
    public func endMeeting(id: MeetingRecord.ID, endedAt: Date) throws
    public func append(_ segments: [Segment], to meetingID: MeetingRecord.ID) throws
    public func listMeetings() throws -> [MeetingRecord]
    public func segments(for meetingID: MeetingRecord.ID) throws -> [Segment]
    public func deleteMeeting(id: MeetingRecord.ID) throws           // FK cascade
}

public actor SegmentWriter {
    public init(store: MeetingStore, meetingID: MeetingRecord.ID)
    public func run(consuming finals: AsyncStream<Segment>) async    // 1s debounce / 25 rows
    public func flushAndStop() async throws                          // final flush on end
}
```

## Acceptance checks (written before implementation; user-reviewed 2026-07-16)

Machine-verifiable:

1. Migration v1 round-trips on an in-memory database; all three tables exist with expected columns.
2. Lifecycle: `beginMeeting` → `append` → `endMeeting`; `listMeetings()`/`segments(for:)` return the written data with correct `us`/`them` mapping and ordering.
3. `SegmentWriter` batching: flushes on debounce and on the 25-row threshold; order preserved; final flush on end loses nothing.
4. `deleteMeeting` cascades: segments rows removed.
5. Ephemeral proof: an ephemeral meeting run leaves **zero rows** in an on-disk database in a temp dir and does not grow its file; the same run in persistent mode writes the expected rows.
6. `SessionController` `.paused` transition matrix: pause only from capturing; resume only from paused; stop from paused; toggle from paused stops. Slice-1 tests pass unmodified.
7. Full `swift test` green; `xcodebuild` clean.

User-live:

8. ⌥⌘P mid-meeting verifiably halts capture — speaking while paused produces no new segments; resume picks the transcript back up. *(Strengthened 2026-07-17, user-notified at walk time:)* also press ⌥⌘M and ⌥⌘P in quick succession and confirm each hotkey only ever fires its own action — exercises the Carbon handler ID-filtering fix, which no unit test can reach.
9. An ephemeral meeting never appears in history and leaves nothing on disk.
10. History window lists past meetings and reopens a persisted transcript read-only (exit criterion 2 component).

## Checklist

- [x] Acceptance checks user-reviewed 2026-07-16 (front-loaded batch gate)
- [x] Builder: GRDB 7.11.1 dep + MacapyDatabase + migration v1 (red 0e889a1 → green 21d70da)
- [x] Builder: MeetingStore + cascade delete (21d70da)
- [x] Builder: SegmentWriter batching + binding attach-ordering constraint w/ converse non-vacuity test (21d70da)
- [x] Builder: SessionController .paused + ⌥⌘P + panel Paused state (21d70da; incl. latent slice-1 HotKey bug fix — see Notes)
- [x] Builder: MeetingPipeline PersistenceMode + lifecycle + ephemeral toggle (21d70da)
- [x] Builder: HistoryView list + transcript detail (21d70da)
- [ ] Verifier: independent re-run of checks 1–7 with evidence
- [ ] Live checks 8–10 walked with the user
- [ ] Ship rituals: milestone table, integration notes, handoff, final commit

## Notes / dead ends

(append as work proceeds)

- 2026-07-17 (builder, red 0e889a1 → green 21d70da, GRDB 7.11.1): Binding attach-ordering constraint honored structurally (writer attach is the first act of `pipeline.start(mode:)`, before prepare/captures) and proven three ways, including a converse test showing a late attach really loses an early final. **Latent slice-1 bug found & fixed in HotKey.swift**: each instance installed an unfiltered Carbon handler returning `noErr` unconditionally — a second hotkey would have made the newest handler swallow both keys; fixed via `GetEventParameter` → `EventHotKeyID` match, `eventNotHandledErr` otherwise. Not unit-testable (live check 8 strengthened instead). Deviations: DB columns camelCase not SPEC's snake_case sketch (1:1 with record types, storage-layer only — SPEC §6.2 amendment note); `MeetingStore` methods sync-`throws` using GRDB synchronous write/read inside the actor (matches doc signatures; cross-actor callers still `await`); coordinator became `@Observable` for the ephemeral toggle; menu gained Pause/Resume item; `historyStore()` memoizes the on-disk store so History shows prior-run meetings. Gotchas: GRDB `foreignKeysEnabled` defaults true (cascade free); UUIDs stored as BLOBs (CLI inspection shows binary); `beginMeeting` synthesizes a title. Residual (verifier to scrutinize): `SegmentWriter.flushAndStop()` relies on actor-executor enqueue-order draining — sound in practice, not a language-level guarantee; integration tests for check 5 + attach ordering live in MeetingPipelineTests (AppShell) since they need PersistenceMode/coordinator.
- 2026-07-17 (from slice-2 critic, binding on this slice's design): `TranscriptStore.finalsStream()` has **no replay** — `apply(.final:)` yields only to already-attached continuations, and `reset()` finishes all continuations. The `SegmentWriter` therefore MUST attach `finalsStream()` **before** `pipeline.start()` for each meeting and re-attach after every `reset()`, or early/boundary finals are silently lost. Add an explicit test for the attach-before-start ordering and for a final emitted immediately after start.
