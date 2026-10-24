# Privacy and data lifecycle

macapy is local-first. Audio processing and saved meeting history run on your Mac. Optional AI sends text to the configured provider. There are no macapy accounts, backend, telemetry, or meeting bots.

## What exists where

| Data | Location and lifetime |
|---|---|
| Raw audio | Bounded in-memory capture/transcription/diarization buffers. Never written to a recording file or sent to an AI endpoint. No audio playback or recovery copy. |
| Persistent meetings | Local SQLite: titles, timestamps, transcript text, speaker labels and optional speaker embeddings, generated/reviewed artifacts, search indexes, and spend records. Kept until deleted. |
| Memory | Local SQLite: opted-in meeting links, candidate/reviewed facts and their source references, explicit people/projects and aliases. Only approved, eligible facts enter retrieval. |
| Imported documents | Local SQLite text snapshots, file names, chunks, page references, search indexes, and attachment/AI-consent state. The original file is not copied or watched. New documents start with AI eligibility off. |
| Calendar briefs | Local selected-calendar/event identifiers, event titles and timing, explicit entity associations, source-linked briefs, and cached synthesis. No descriptions, attendee lists, locations, or URLs in the brief snapshot. |
| Approved actions | Local journal of the exact approved fields, destination, operation marker, status, and external receipt. The created Calendar/Reminders item also exists outside macapy. |
| Usage admission | Local attempt identifiers, model/purpose, estimated/known costs, and uncertain reservations. Content deletion removes source/job identifiers while preserving anonymous aggregate budget totals and counts. |
| Ephemeral meetings | A fresh in-memory database for that meeting. No saved history, post-meeting artifact export, or persisted memory/document lookup. Configured live AI can still transmit its text. |
| Settings | Local preferences/database settings, including provider/model choices and spending limits. No API keys in these rows. |
| Provider credentials | macOS Keychain, service `io.macapy.app`. Stored separately from meeting data. |
| Outgoing request inspection | At most three recent encoded request bodies, up to 512 KiB total in memory. No authorization headers, credentials, responses, or disk log. |
| Exports and clipboard | Created only by explicit copy/save actions. Their lifetime belongs to the destination and is not controlled by later meeting deletion. |
| Fictional sample | Isolated in-memory records, scripted responses, and fake calendar/action adapters. No real Calendar/Reminders writes. Reset or exit discards the sample session. |

The persistent database is `~/Library/Application Support/macapy/macapy.sqlite`, with SQLite sidecars while open. The app does not add database encryption. macOS account permissions and any device encryption you enable protect local files; this is not a guarantee against another process with access to your account or device. Optional speaker embeddings are derived voice data and receive the same deletion treatment as their meeting.

## Network boundary

Speech support downloads from Apple through an explicit setup action. Optional diarization models download separately after an explicit action and live in the shared FluidAudio model cache. Build dependencies also download during first-time development setup. These asset/build operations are separate from meeting-time capture.

After required assets are installed, transcription, history, and lexical source retrieval can work without a network connection. During a meeting, optional app network work is limited to the configured LLM endpoint. A provider request can contain transcript context, your question, preferred-name context, system instructions, and output schemas/settings. Explicit source-backed requests may also include selected reviewed facts and AI-consented document excerpts. The current app exposes DeepSeek; definitions for other endpoints in source are not evidence of wired support.

Memory extraction is an explicit action for an opted-in saved meeting. Opening a source picker, reading a document, or running local search does not call a provider. Optional live Ask grounding previews a bounded recent-transcript snapshot and selected saved excerpts before sending. Replacing a provider, disabling AI, changing a selected source, or deleting content invalidates relevant pending work and visible answers. Source validation cannot retract text already dispatched.

Calendar briefs and automatic synthesis have separate opt-ins. Local briefs need calendar read permission but no AI. A manually sent synthesis includes the selected evidence and only includes the event title if you choose its checkbox. Automatic synthesis sends associated reviewed history and AI-consented document evidence; it excludes event titles and other calendar content. Descriptions, attendees, locations, and URLs are not part of either brief request path. Brief work pauses during meetings.

EventKit is a separate user-approved boundary. Creating a Calendar event or Reminder sends only the exact approved item to the selected destination through macOS. That destination may belong to iCloud, Exchange, or another account whose synchronization is managed outside macapy. No transcript, attendee invitations, or unrelated drafts are automatically added. Deleting local macapy content does not delete that external item.

Review the selected provider’s current policies before enabling AI. Its processing, retention, location, and account settings are outside macapy’s control. macapy cannot retract a request already received by a provider. Removing a key, clearing the inspector, or deleting a local meeting does not delete copies held by that provider.

**Outgoing AI text** displays the actual encoded JSON body after request formatting. It is a recent-request inspection tool, not an audit log or per-request approval gate. Old requests are evicted; oversized bodies are not retained. Closing the view releases its displayed copies; **Clear** removes the shared retained bodies. The ring also clears at session/privacy boundaries. It does not offer raw-body copy, export, or logging.

## Retention, deletion, and recovery

Use History to delete a meeting. Its source-linked memory and attachments lose eligibility; a document shared with another meeting remains until its last attachment is removed. Turning memory off removes that meeting's retained facts. Reimporting a changed document atomically replaces its text/chunks and invalidates facts derived from the old version. Disabling a document's AI eligibility excludes it from retrieval; it does not delete the local snapshot. Source-linked previews and in-flight answers are cleared or rejected when their evidence is no longer current.

Settings provides a typed **DELETE** confirmation to delete all meeting data: meetings, transcript, notes, memory, people/projects, imported documents, calendar briefs, local action history, searchable content, and the preferred name. Other app/provider settings, API keys, installed models, and anonymous budget counters are preserved. Deletion is unavailable while a meeting is active.

Anonymous budget totals remain after content deletion so deleting a brief or meeting does not free uncertain usage or reset automatic-generation allowances. These aggregates contain scope/day, costs, and counts without meeting, event, job, model, or text identifiers. A provider call interrupted after dispatch may have incurred a cost even when no answer appeared; the reservation stays conservative. Restarting is not a budget reset.

For a separate preferences reset, first delete all meeting data, then choose **Review preferences reset…** in Settings and type **RESET**. This clears provider/app preferences, capture/setup choices, saved API keys owned by macapy, customized shortcuts, and retained local usage records and budget counters. It turns off launch at login and returns shortcuts to their defaults. An active meeting, setup download, or other owned operation can prevent reset; a partial failure is reported and requires a fresh confirmation to retry.

Clearing budget counters does not refund or cancel provider charges. Uncertain requests may already have incurred charges, even without a visible answer. Explicit reset starts fresh local accounting for future requests. Shared installed speech/speaker models, macOS permission grants, exports, and existing external Calendar/Reminders items remain. Reset does not delete provider-held data or backups. Individual provider keys can also be removed in provider settings without resetting other preferences.

Removing a calendar selection, disabling briefs, or revoking calendar read access removes the affected cached calendar content. Calendar refresh invalidates stale briefs and removes events that are no longer eligible. The app does not retain a historical calendar archive.

Deleting content is a logical database operation, not a promise of physical secure erasure from storage, OS memory, filesystem snapshots, or backups. The app cannot remove independently saved exports, clipboard copies, provider-held text, or external backups. Removing the app bundle alone does not delete its database or Keychain entries.

After interruption, only committed transcript is recoverable. Audio and unsaved words are gone. If the database becomes unavailable while capturing, the app shows a warning and buffers a bounded amount of text temporarily in memory. Continuing indefinitely with failed storage can lose text; there is no concealed recording fallback.

An upgrade may temporarily create `macapy.sqlite.pre-migration` beside the database using SQLite's consistent backup operation. Successful migration and integrity checks remove it. A failed migration may retain the snapshot for recovery; the app purges stale snapshots on a later open and removes them before content deletion or source revocation. It is app-managed recovery state, not an external backup or an audio recording.

Ephemeral mode changes local meeting retention. It does not anonymize the conversation, disable a configured provider, or change the provider’s policy. The sample is separate again: its fictional text and scripted AI require no production storage, microphone, credentials, or network client.

## Diagnostics and reports

Errors and diagnostics should contain sanitized types, states, and aggregate measurements rather than keys or private meeting text. Before sharing a screenshot or issue, inspect the whole image and remove names, titles, transcript text, file paths, and request bodies. Use the fictional sample for public demonstrations.

The diagnostic report action shows the entire JSON before saving locally. Its allowlist contains counters and app/macOS versions, without meeting text, request bodies, credentials, identifiers, or paths. It does not upload the report. This is separate from the sensitive, memory-only outgoing-request inspector.

Report unintended disclosure through [SECURITY](../SECURITY.md). See [Release preparation](release.md) for uninstall/upgrade details and [Third-party notices](../THIRD_PARTY_NOTICES.md) for the optional model provenance boundary.
