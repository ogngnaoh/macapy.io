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
6. Keyboard operability and VoiceOver labels **present** on all reskinned controls — completing coverage where M1 left it partial, not merely preserving what existed (amendment from kickoff gate 2026-07-24).

## Checklist

- [x] Acceptance checks user-reviewed (M2 kickoff gate — approved 2026-07-24, amendments in ./milestone.md Integration notes)
- [x] Aesthetic-direction interview (frontend-design skill) → direction recorded in Notes (2026-07-24, "Quiet instrument" — user-approved)
- [x] Design system (tokens + components) built locally, light + dark (2026-07-24, `design/` at repo root: `tokens.css` + bundled Martian Mono)
- [x] All inventory screens mocked (2026-07-24, `design/0*.html` — every screen in both light and dark)
- [x] Claude Design project created; `/design-sync` upload (2026-07-24, project "macapy — Quiet instrument", id 551c0adb-9714-4d9b-86aa-5b6ed268d78f, 12 files)
- [ ] Author browser review → iterate → approval (record project link + date)
- [ ] SwiftUI translation: `AppShell/Design/` tokens + components
- [ ] Reskin panel / History / Settings / menu bar
- [ ] Checks 1–2 (machine) + 3–6 (live) pass
- [ ] Ship rituals: slice table, integration notes, handoff, commit

## Notes / dead ends

- 2026-07-24 (mockups built + synced): full bundle in `design/` (shared `tokens.css`, latin-subset Martian Mono woff2 bundled, 10 screen files, every screen light + dark side by side); synced to Claude Design project "macapy — Quiet instrument". Self-critique via headless-Chrome screenshots before sync caught: uniform signal-strip ticks read as decorative dashes when static → fixed with narrow ticks at varied heights (reads as a level meter even frozen); button text wrapping. Transcript fiction ("Payments API migration sync") reused consistently across panel/history/detail/search so screens read as one product; diagnostics use M1's real numbers (p50 32.97 / p95 85.36). Awaiting author browser review.
- 2026-07-24 (aesthetic direction — interviewed and approved): **"Quiet instrument."** Interview outcomes: native bones + own voice; calm-instrument panel; graphite + live signal color world; SF + one character face. Direction: palette `ink #16191D`, `carbon #23272C`, `slate #6B7683`, `fog #EEF0F2`, `paper #FBFBFC`, `signal #F2A33C` (VU-meter amber — live/capturing/primary only, never decoration; darkened variant for text-on-light contrast). Type: **machine speaks mono, humans speak SF** — SF for all UI chrome *and* transcript text; Martian Mono (OFL, bundled; license re-verified at build) reserved for the machine's voice: timestamps, speaker chips, timer, latency/spend numerals, wordmark. Volatile vs. final: volatile = `slate` + dotted baseline, final = `ink`, no baseline (two cues, no italics — retires the M1 `.secondary`-alone miss). Signature element: the **signal strip** — 2–3px tick-meter on the panel's top edge driven by real audio level (amber = mic/you, slate = them); doubles as recording indicator; reduced-motion fallback = steady amber dot. Panel: thin mono header strip (state + timer), bottom-anchored caption-style transcript, mono speaker gutter; copilot moments = one quiet card earning attention by contrast. Windows stay HIG-native; identity via type discipline + where amber may appear. Anti-default check recorded: no cream/serif/terracotta, not black+acid-green (light mode co-equal), hairlines instrument-grade with native continuous corners.
