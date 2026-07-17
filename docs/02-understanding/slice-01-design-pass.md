# Slice 1 — Whole-Product Design Pass + SwiftUI Design System + Reskin

**Status:** pending
**Plan written:** 2026-07-17 (M2 planning session; acceptance checks below precede implementation — user review of this doc is the first act of M2 kickoff)
**References:** ./milestone.md (exit criterion 1), ../../SPEC.md §6.1 (app shell), PRD G1 (portfolio bar), M1 non-goal "no visual design investment … until the dedicated frontend design session" — this is that session.

The plan for this slice is also its record (working-doc convention).

## Design

### Decisions (planning, 2026-07-17)

1. **Whole-product scope.** One design system + mockups for every primary screen through M5, so M3–M5 implement inside a settled visual language instead of reskinning twice. M4/M5 screens are accepted as higher-churn (their features aren't fully specced); their mockups are directional, the design *system* is the durable artifact.
2. **Workflow: Claude generates, author reviews.** Aesthetic-direction interview (frontend-design skill) → mockups built locally as HTML → new Claude Design project created and synced (`/design-sync`) → author iterates in the browser → approval → hand-translation to SwiftUI.
3. **SwiftUI home: `Sources/AppShell/Design/`** — tokens (color light+dark, type scale, spacing, radii) + reusable components. No new SPM target (AppShell is the only SwiftUI module; YAGNI).
4. **Reskin only what exists:** floating panel, History window, Settings window, menu bar menu. New M2 screens (meeting detail, Providers/Spend tabs) are *built* in their own slices, *to this design*.
5. **Constraints carried from M1/SPEC:** volatile vs. final must stay unmistakable (M1's `.secondary`-color-alone miss); non-activating panel with no close button; full keyboard operability + VoiceOver labels (SPEC §8); panel stays compact and glanceable — it is not a window.

### Screen inventory (the design deliverable)

- **Floating panel:** idle/starting; live (dual-source transcript, speaker chips, volatile/final treatment); paused; M3 states: copilot moment card, query box, catch-up overlay, rolling-summary strip
- **History window:** meeting list, search state (M2), empty state
- **Meeting detail:** transcript replay + artifacts pane (summary / decisions / action items) + review approve/reject flow
- **Settings:** General (hotkeys, ephemeral default); Providers (endpoint profiles, key entry, jurisdiction notes, model tiers); Spend (per-meeting usage, est. cost, cap); Diagnostics (latency percentiles, error rates, memory)
- **M4 pre-meeting brief card** (panel surface); **M5 onboarding/permissions flow** (mic + system-audio TCC guidance)
- **Menu bar menu** states (idle / capturing / paused)
- **Design system page:** tokens + core components (transcript line, speaker chip, moment card, buttons/fields, list rows, empty states), light + dark

## Acceptance checks (written before implementation)

Machine-verifiable:

1. Full `swift test` green and `xcodebuild` clean after the reskin (no behavior change intended; state machine / hotkey / persistence tests untouched).
2. Reskinned AppShell views draw colors/fonts/spacing from `Design/` tokens — no ad-hoc `Color`/`Font` literals left in reskinned views (grep-audited, exceptions justified in Notes).

User-live:

3. Every screen in the inventory exists as a card in the Claude Design project and the author has approved each (browser review).
4. Side-by-side: running app vs. approved mockups for panel, History, Settings, menu bar — author signs off, in **both light and dark** mode.
5. Volatile → final transition remains unmistakable at a glance during a real capture; panel readable at its compact size.
6. Keyboard operability and VoiceOver labels preserved on all reskinned controls.

## Checklist

- [ ] Acceptance checks user-reviewed (M2 kickoff gate)
- [ ] Aesthetic-direction interview (frontend-design skill) → direction recorded in Notes
- [ ] Design system (tokens + components) built locally, light + dark
- [ ] All inventory screens mocked
- [ ] Claude Design project created; `/design-sync` upload
- [ ] Author browser review → iterate → approval (record project link + date)
- [ ] SwiftUI translation: `AppShell/Design/` tokens + components
- [ ] Reskin panel / History / Settings / menu bar
- [ ] Checks 1–2 (machine) + 3–6 (live) pass
- [ ] Ship rituals: slice table, integration notes, handoff, commit

## Notes / dead ends

(append as work proceeds)
