# Using macapy

macapy keeps a live transcript beside your meeting and can add optional AI help. It runs as a native menu-bar app. It does not join calls, install meeting-platform integrations, or record an audio file.

## Start with the sample

Choose **Sample meeting** from the menu bar, or **Explore a sample meeting** from Setup. The fictional Atlas scenario covers Live, Review & history, Memory & sources, and Before meeting. Replay a conversation, edit its outcomes, inspect a source-backed answer, or review a fictional action. Reset restores the initial state.

The sample uses isolated in-memory stores, scripted AI, and fake calendar/action adapters. It does not request microphone or calendar access, download models, use provider credentials, make AI calls, or create real Calendar/Reminders items. Launching with `--sample` also avoids constructing the production service coordinator. Sample output illustrates the product workflow; it does not measure speech quality or provider performance.

## Prepare a real meeting

1. Build and run the macOS app using the [development instructions](development.md).
2. In Setup, choose microphone only or microphone plus system audio. System audio includes other audio playing on the Mac, not just a meeting application.
3. Choose **Allow microphone**. If access was denied, use the System Settings link, grant permission, and return to Setup.
4. Choose **Install speech support** to prepare English (US). This is an explicit asset download from Apple; normal meeting startup only uses installed assets.
5. Optionally add a preferred name and configure AI in Settings. Finish Setup and start a meeting from the menu bar.

System audio may also require macOS consent. If preparation fails, the panel shows the failure and a route back to Setup; it does not claim capture has started. Close unrelated audio sources before recording a conversation. Obtain any participant permission required for your situation.

Optional speaker diarization is configured in Settings. Its separate model download is unavailable during an active meeting. Without it, the transcript uses source labels; speaker clustering is not cross-meeting identity recognition. The current optional legacy model assets have a remaining [attribution/provenance release gate](../THIRD_PARTY_NOTICES.md#optional-model-assets).

## During the meeting

The floating panel displays the transcript and capture state. Pause stops capture; resume continues the current meeting. An ephemeral meeting must be selected before starting and is not saved to persistent history. It still permits configured AI text requests when AI is enabled.

| Action | Shortcut |
|---|---|
| Start / stop meeting | ⌥⌘M |
| Pause / resume capture | ⌥⌘P |
| Catch up | ⌥⌘C |
| Ask | ⌥⌘K |
| Dismiss copilot | ⌥⌘D |

Optional AI currently exposes DeepSeek in Settings. Other endpoint profiles in the transport code are not supported product choices yet. A provider key is stored in Keychain. Review the provider’s current data policy before enabling it; transcription and history remain usable without a key.

Catch up summarizes recent context; Ask sends your question with meeting context. AI output can be wrong or incomplete, so check it against the transcript. A per-meeting spending limit stops new AI work when its budget is exhausted. The displayed cost is an estimate based on configured token rates, not the provider’s invoice. Optional failures or spending limits do not stop local capture.

For a persistent meeting, **Add sources…** opens a local review before an Ask request. Select saved meetings or AI-consented documents and find relevant excerpts. This path uses up to four saved excerpts and four recent transcript excerpts, at most 8,000 characters combined. The recent transcript is a snapshot of the last 90 transcript seconds when the review opened; new speech is not added silently. Deselect anything you do not want included, then send explicitly. The resulting **Sources** menu opens supporting evidence. Ephemeral meetings do not offer saved-source lookup.

Choose **Outgoing AI text** from the menu or Settings → Diagnostics to inspect the exact recent JSON request bodies. This view excludes authorization headers, credentials, and responses. It retains at most three requests within a total 512 KiB memory budget; older requests are unavailable. Use **Clear** to discard the retained bodies.

## After the meeting

Open History to search saved transcript and artifact text. If AI is configured, a completed persistent meeting can produce a draft summary, decisions, and action items. Generation can be retried explicitly when output is unavailable; an interrupted session does not silently restart provider work.

Correct draft text, owners, and deadlines before approving it. **Review approval means the wording has been reviewed. Completion means the action has been done.** These are separate states. Copy individual items or export selected content as Markdown, plain text, or JSON through the native save panel. Files and clipboard copies you create are outside the app’s later deletion controls.

Delete an individual meeting in History, or type **DELETE** in Settings to delete all meeting data. Provider/app preferences, API keys, installed models, and anonymous budget counters are kept by that action. Deletion is disabled while a meeting is active.

## Memory and documents

Open **Memory & sources** and select a completed saved meeting. Enable **Memory for this meeting**, review the transcript excerpts eligible for extraction, and explicitly send the selected text if you want AI to propose candidates. Candidate facts stay out of retrieval until approved. Review, edit, supersede, or remove them; open their evidence before relying on them. A retained fact is invalidated when its underlying source changes or disappears.

Create people and projects explicitly, add aliases, and link them to meetings. macapy does not infer a person's identity from a voice or calendar title. Alias collisions are rejected; merging records is an explicit choice.

Import local Markdown, UTF-8 text, or text-based PDF files into a saved meeting. macapy stores a text snapshot, not a live filesystem watcher or a copy of the original binary. Imports are limited to 10 MiB, 200 PDF pages, and one million extracted characters; encrypted, scanned/image-only, or unreadable PDFs are unsupported. Reimport updates a snapshot atomically. Detach removes one meeting association; detaching its last association removes the snapshot. Removing a document removes every association.

**Allow in AI context** starts off for each new document. Reading it locally does not send it anywhere. Enable consent only for sources you intend to make eligible for retrieval and AI context. Memory search can be scoped by meeting, document, person/project, and an as-of date; this date filters eligible evidence, not a historical archive of every old revision. Search is local and lexical. Select eligible results and review them before explicitly asking AI for a cited answer. An answer without sufficient supported evidence is reported as such.

## Approved Calendar and Reminders actions

From a reviewed action item, open the Calendar or Reminder action flow. Grant the needed permission only when you want to use it. Choose the destination, edit the title and notes, set dates and time zone, then choose **Review exact item**. Only **Approve & create** writes the reviewed item. A draft deadline is not automatically interpreted, and creating an external item does not mark the task complete.

Each operation creates one item: no attendee invitations, recurring series, updates, or deletes. The displayed notes include an operation marker so an uncertain outcome can be looked up. If saving was interrupted, another attempt stays blocked until **Check outcome** reconciles it. Closing the sheet or deleting local history cannot undo an item already saved in Calendar or Reminders. Your destination account may sync that item independently of macapy.

## Before the next meeting

Enable calendar briefs separately and choose which calendars may be read. **Before you meet** shows upcoming events within the next 24 hours. Associate an event with people or projects yourself. A local brief collects source-linked, reviewed history and eligible documents without a provider.

For manual AI synthesis, review and select the displayed evidence, then choose **Send selected context for synthesis**. The event title is excluded unless you explicitly enable its checkbox. Descriptions, attendee lists, locations, and URLs are excluded from brief context.

**Automatic AI summaries** is a separate opt-in, off by default. While macapy is open, it may synthesize evidence for explicitly associated upcoming events. Automatic synthesis excludes calendar titles and other calendar content, pauses during meetings, and uses the same source validation as manual synthesis. Brief AI has a separate $0.10 daily estimated budget, a $0.02 per-generation admission bound, and at most five automatic generations per day. Unknown usage remains reserved after interruptions; restarting or deleting content does not silently free it. The budget panel shows its reset time.

## Startup and diagnostics

Settings includes **Launch macapy at login** and configurable global shortcuts. Launching never starts recording automatically. macOS may require approval in Login Items; availability depends on how the app is installed. Shortcut conflicts preserve the existing working binding.

To reset retained preferences, first use **Delete all meeting data**, then choose **Review preferences reset…** and type **RESET**. This clears provider/app and setup preferences, saved API keys, shortcut customization, and local budget counters; launch at login is turned off. Installed shared models, macOS permissions, exports, and external Calendar/Reminders items remain. Open Setup again before your next meeting. If reset reports a partial failure, some settings may already be cleared; review the message and explicitly confirm a retry.

Resetting local accounting does not refund or cancel provider charges. Uncertain calls may already have incurred charges. Future requests start fresh local budget accounting only after this separate, explicit reset. See [Privacy](privacy.md#retention-deletion-and-recovery) for the full retention boundary.

Diagnostics can prepare a local JSON report containing counters and app/macOS versions. Review it before saving. It excludes meeting text, request bodies, credentials, identifiers, and file paths and is never uploaded automatically.

## Recovery and current limits

After an interruption, macapy recovers transcript already committed to its database and marks the meeting Interrupted. Audio and unsaved words cannot be recovered. If storage fails during capture, a visible warning explains that recent text is temporarily buffered in memory; free disk space or stop the meeting. This buffer is bounded and is not an audio backup.

Audio-device changes, capture interruptions, and system sleep can stop a recording rather than silently continue with a different source. Start a new meeting after resolving the interruption. Optional diarization can fall behind or fail without stopping transcription; the panel reports that condition. If quitting times out while recording is still draining, macapy stays open and asks you to try again after it finishes.

The current preview targets Apple Silicon and macOS 26+, English (US), and one active meeting. It has no audio playback, account sync, meeting bot, automatic updater, or signed download. Semantic retrieval remains experimental and disabled; the supported retrieval path is lexical. Model accuracy, live EventKit permissions, provider compatibility, and clean-install behavior need their own evidence beyond the scripted sample and deterministic tests.

See [Privacy](privacy.md) for retention and network boundaries, [Development](development.md) for verification, and [Release preparation](release.md) for distribution status.
