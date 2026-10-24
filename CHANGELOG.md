# Changelog

Changes are recorded by user-visible behavior. **Unreleased** describes the native source preview; it does not imply an available signed download.

## Unreleased

- Native menu-bar app and floating meeting panel with local microphone/system-audio transcription, pause/resume, capture-source selection, and ephemeral meetings.
- Explicit setup for microphone permission and English speech assets, plus optional diarization setup.
- Optional live AI: catch-up, meeting questions, contextual suggestions, post-meeting extraction, and per-meeting spending controls. DeepSeek is the currently wired provider.
- Searchable local history; editable summaries, decisions, and action items; separate review and completion states; explicit copy and file export.
- Opt-in memory for saved meetings, reviewable source-linked facts, explicit people/project associations and aliases, and local search with source and date filters.
- Local Markdown, UTF-8 text, and text-based PDF import with atomic snapshots, reimport, attachment management, and AI consent disabled by default.
- Optional source-backed answers in Memory and live Ask, with evidence previews, bounded selections, validated citations, and stale-source rejection.
- Explicit Calendar/Reminders action review, exact destination/field approval, and a persistent journal that blocks duplicate retries while a save outcome is uncertain.
- Calendar briefs for explicitly selected calendars and associated people/projects: local evidence first, optional manual synthesis, and separately enabled automatic summaries with daily spending/count limits.
- Durable AI reservations, restart recovery for uncertain usage, and separate brief budgets. Content deletion keeps anonymous budget totals so it cannot silently reset a spending limit.
- A fictional Atlas sample tour using in-memory stores, scripted AI, and fake Calendar/Reminders adapters across Live, History, Memory, and Briefs, including direct `--sample` launch.
- Square native presentation with neutral surfaces, pink branding, cobalt accents, readable typography, and light/dark appearances.
- Memory-only inspection of recent outgoing AI JSON bodies, excluding headers and responses.
- Visible preparation, interrupted-session, and storage-warning states. Committed transcript can be recovered after interruption; audio and uncommitted words cannot.
- Device/sleep interruption handling, bounded optional diarization work, launch-at-login controls, configurable global shortcuts, and local review/export of sanitized diagnostics.
- Offline verification entrypoint, opt-in installed-model/live-provider lanes, public contributor guides, and local release-packaging tools.

Signed distribution, hosted CI evidence, and clean-install/upgrade verification remain release work. See [Release preparation](guide/release.md).
