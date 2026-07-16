# PRD: macapy — Local-First Agentic Meeting Assistant

**Status:** Approved
**Last updated:** 2026-07-16

## 1. Problem

Knowledge workers in back-to-back online meetings face a set of compounding failures: they cannot take notes and genuinely participate at the same time; nearly half of action items agreed in meetings are never completed; attention lapses mean losing the thread with no way to catch up; and decisions from prior meetings vanish into a black hole nobody can recall. Existing AI meeting tools fail these users in structural ways: most send a visible bot into the call, which kills candor and creates consent problems; nearly all ship audio and transcripts to vendor clouds, where they may be retained or used for training; all are subscriptions with a history of shrinking what the money buys; and almost all process meetings only *after* the fact, doing nothing for the in-the-moment pains — being put on the spot, zoning out, walking in without context. There is no meeting assistant that is invisible to other participants, keeps everything on the user's own machine, acts *during* the meeting, and is free and open for anyone to run.

## 2. Target users

- **Primary:** Me — a developer who attends frequent online meetings, wants to stay fully present without typing notes, and wants this project to stand as a portfolio-grade demonstration of native app and system design.
- **Secondary:** Privacy-conscious knowledge workers on a Mac who are comfortable cloning an open-source project and supplying their own AI-provider credentials, and who cannot or will not send meeting audio to a third-party service.
- **Deferred:** Interview candidates seeking real-time coaching (a later mode, not v1).

## 3. Goals & success metrics

- **G1 — Portfolio-grade quality bar.** The repository demonstrates professional system design and native engineering.
  - **Metric:** At public launch, a newcomer can go from cloning the repository to a running app in under 10 minutes following only the README; architecture documentation is complete and current; a demo video exists.
- **G2 — Replaces manual notes for its author.** The app is genuinely used, not just built.
  - **Metric:** Within 1 month of the first shippable version, used on 100% of the author's real meetings, with manual note-taking abandoned.
- **G3 — Speed above everything.** The app feels instantaneous.
  - **Metric:** Transcribed speech visible within 1 second of words being spoken; a proactive suggestion appears within 3 seconds of the utterance that triggered it; post-meeting artifacts are drafted within 60 seconds of the meeting ending; app cold-starts in under 2 seconds; active memory footprint stays under 400 MB.
- **G4 — Nothing leaves the machine except what the user explicitly configured.**
  - **Metric:** Zero audio ever persisted to disk or transmitted anywhere; the only network traffic the app produces goes to the AI provider the user configured, and a meeting can be run end-to-end (capture, transcript, history) with zero network traffic at all.

## 4. Non-goals (out of scope)

- **N1: No cloud or SaaS component, ever.** No hosted backend, no user accounts, no telemetry, no analytics phoning home. This is permanent, not just a v1 deferral.
- **N2: No Windows, Linux, or mobile.** Mac-only, in exchange for native depth.
- **N3: No bot or virtual participant.** The assistant never joins a meeting as a visible participant and never interacts with meeting platforms directly; it hears only what the user's own machine plays and records.
- **N4: Not a general-purpose note editor.** Users can jot scratch notes during a meeting, but document editing, wikis, and knowledge-base features belong to other tools.
- **N5: No autonomous actions during a live meeting.** The in-meeting copilot only ever *shows* the user things. It never types, clicks, speaks, or sends anything on the user's behalf. Post-meeting actions with real-world effects always pass a user review step.

## 5. User stories

### Story 1 — Present in the meeting, not in my notes
**As a** knowledge worker on a video call, **I want** everything said to be captured and transcribed live on my machine, **so that** I can participate fully without typing notes.

**Acceptance scenarios:**
- Given a meeting is playing through my machine and capture is started, when anyone speaks, then their words appear in the live transcript within 1 second, visually distinguished as me vs. others.
- Given capture is running, when I check the meeting platform as another participant, then there is no bot, no participant entry, and no indication visible to others that transcription is happening on my machine.
- Given I have configured no AI-provider credentials at all, when I run a meeting, then capture, live transcript, and history still work fully.

### Story 2 — Put on the spot
**As a** meeting participant asked a question directly, **I want** a privately displayed suggested answer drawing on the conversation and my own context, **so that** I can respond well under pressure.

**Acceptance scenarios:**
- Given the conversation contains a question directed at me, when the question is spoken, then a private suggestion appears within 3 seconds, visible only on my screen.
- Given a suggestion is displayed, when I ignore it, then it disappears on its own without requiring interaction.

### Story 3 — I zoned out
**As a** fatigued participant who lost the thread, **I want** a one-glance recap of the last minute, **so that** I can rejoin the conversation without asking anyone to repeat themselves.

**Acceptance scenarios:**
- Given at least a minute of conversation has occurred, when I trigger the catch-up control, then a compact recap of the most recent conversation appears in under 2 seconds.

### Story 4 — The meeting actually produces its artifacts
**As a** meeting participant, **I want** the meeting to end with a drafted summary, decisions, and action items with owners and deadlines, **so that** follow-through stops depending on my memory.

**Acceptance scenarios:**
- Given a meeting just ended, when I open the meeting record, then a draft summary, decision list, and action-item list (each with owner and deadline where stated) are present within 60 seconds.
- Given drafted action items assigned to me, when I approve them in review, then corresponding entries appear in my system task list and calendar; when I reject one, then no entry is created.

### Story 5 — What happened last time
**As a** participant in a recurring meeting, **I want** prior commitments and decisions involving these people surfaced before and during the meeting, **so that** context stops evaporating between sessions.

**Acceptance scenarios:**
- Given a past meeting with the same attendees produced action items, when a new meeting with them begins, then open items and key prior decisions are surfaced to me privately.
- Given weeks of accumulated meetings, when I search my history for a topic, then matching meetings, transcript passages, and artifacts are returned in under 1 second.

## 6. Functional requirements

- **FR-001:** System MUST capture both the machine's meeting audio and the user's microphone locally, with no participant-visible presence in any meeting platform.
- **FR-002:** System MUST display a live transcript within 1 second of speech, distinguishing the user's speech from other participants'.
- **FR-003:** System MUST perform transcription entirely on-device; raw audio MUST never be written to disk nor transmitted off the machine.
- **FR-004:** System MUST proactively detect questions directed at the user and display a private suggested response within 3 seconds.
- **FR-005:** System MUST provide an on-demand catch-up recap of the most recent conversation in under 2 seconds.
- **FR-006:** System MUST maintain a rolling, glanceable summary of the meeting as it progresses.
- **FR-007:** System MUST let the user ask free-form questions mid-meeting, answered with meeting context, with the response streaming in as it is generated.
- **FR-008:** System MUST produce post-meeting draft artifacts — summary, decisions, and action items with owner and deadline where stated — within 60 seconds of meeting end.
- **FR-009:** System MUST create entries in the user's system task list and calendar for approved action items, and MUST NOT take any action with effects outside the app without explicit user approval.
- **FR-010:** System MUST persist all meetings, transcripts, and artifacts locally indefinitely by default, searchable in under 1 second.
- **FR-011:** System MUST maintain memory across meetings — people, projects, and open commitments — and surface relevant memory when meetings involving the same people or topics occur.
- **FR-012:** Users MUST be able to attach documents to a meeting so suggestions and answers are grounded in them.
- **FR-013:** System MUST provide privacy controls: a pause-capture hotkey, an ephemeral mode that persists nothing for that meeting, per-meeting deletion, and delete-everything.
- **FR-014:** Users MUST be able to supply their own AI-provider credentials, stored in the operating system's secure credential store; every capability that does not require an AI provider MUST work without credentials.
- **FR-015:** System MUST show the user their AI usage per meeting, including an estimated cost, and MUST let the user set a per-meeting spending cap that halts AI features (never capture or transcription) when reached.
- **FR-016:** System MUST assemble a pre-meeting brief from memory and attached documents when an upcoming calendar event involves known attendees [NEEDS CLARIFICATION: requires read access to the user's calendar — confirm which calendar sources v1 reads].

## 7. Non-functional requirements

- **Performance:** All targets in G3; the app remains responsive during multi-hour meetings.
- **Privacy:** No telemetry of any kind. The only data leaving the machine is transcript text sent to the user's configured AI provider; the user can see exactly what is sent.
- **Reliability:** Capture and transcription MUST continue unaffected if the AI provider is unreachable; AI features degrade gracefully and recover when connectivity returns.
- **Accessibility:** Full keyboard operability for core flows; screen-reader labels on all controls.
- **Open source:** Permissive license; reproducible build from a clean clone with no proprietary tooling beyond the platform's standard developer tools.

## 8. Edge cases

- No AI credentials configured → app runs as a pure local transcriber; AI surfaces show a quiet setup prompt, never an error.
- AI provider outage or rate-limit mid-meeting → suggestions and summaries pause with a subtle indicator; transcript is unaffected; post-meeting artifacts can be generated retroactively once the provider recovers.
- Meeting runs 3+ hours → transcript remains scrollable and searchable without slowdown; AI context management keeps working (no hard failure at any meeting length).
- In-person meeting (no meeting platform, mic only) → capture works with the microphone alone; everything downstream behaves identically.
- Two meetings' audio at once (e.g., user joins a second call) → [NEEDS CLARIFICATION: v1 behavior — treat all system audio as one meeting, or explicitly out of scope?]
- User denies microphone or system-audio permission → clear guided prompt to grant it; app never silently records nothing.
- Non-English meetings → [NEEDS CLARIFICATION: v1 locale scope — English-only, or all locales the on-device engine supports?]
- Spending cap reached mid-meeting → AI features stop with a visible notice; capture, transcription, and history continue.
- Disk nearly full → warn before starting capture rather than failing mid-meeting.

## 9. Assumptions & dependencies

- **Assume:** The user runs a recent-generation Mac with current OS, meets meetings through this machine's audio, and is comfortable with a clone-and-run installation.
- **Assume:** The user has (or will create) an account with at least one supported AI provider and accepts that transcript excerpts are sent to it when AI features are used.
- **Depend on:** The operating system's on-device speech engine for transcription quality and locale coverage.
- **Depend on:** Third-party AI provider APIs for reasoning features; their latency bounds G3's suggestion target.

## 10. Open questions

- [NEEDS CLARIFICATION: FR-016 calendar sources — system calendar only, or others?]
- [NEEDS CLARIFICATION: locale scope for v1 transcription.]
- [NEEDS CLARIFICATION: dual-simultaneous-meeting behavior (Edge cases).]
- Export formats (plain text, structured) are deferred to post-v1 and intentionally unspecified here.
