# Contributing

macapy is a local-first native macOS meeting assistant. Useful contributions make the meeting workflow more reliable, understandable, and accessible while keeping the privacy boundary small.

Start with the [product guide](guide/product.md), [architecture](guide/architecture.md), and [development instructions](guide/development.md). The supported development target is Apple Silicon, macOS 26+, and Xcode 26+. No provider key is needed for ordinary development or the sample tour.

## Propose a focused change

For a bug, [open an issue](https://github.com/ogngnaoh/macapy.io/issues) with the app revision, macOS/Xcode versions, steps to reproduce, and expected versus observed behavior. Use fictional meeting text and redact account names, file paths, credentials, and participant information. Follow [SECURITY](SECURITY.md) for vulnerabilities.

For a material feature or new dependency, discuss the problem and proposed boundary before building it. The project has no backend, accounts, telemetry, meeting bot, or meeting-platform integration. Changes that introduce those systems require a product decision rather than an incidental implementation.

## Preserve the contracts

- Capture and local transcription must continue when optional diarization or AI fails, stalls, is cancelled, or reaches its spending limit.
- Never persist or transmit raw audio. Asset installation must remain an explicit setup action, separate from meeting-time work.
- Keep credentials in Keychain and private content out of logs, fixtures, screenshots, and issue reports.
- Own asynchronous tasks explicitly. Check meeting, provider, and revision identity after suspension points; cancellation alone does not prevent stale writes.
- Keep database migrations forward-only. Test deletion, search-index consistency, ephemeral storage, and concurrent edits through production store interfaces.
- Keep external actions behind explicit review and approval. A generated action item is not permission to perform it.

`AppShell` owns application composition and UI. Lower modules should not import SwiftUI app plumbing. GRDB stays in persistence, FluidAudio in diarization, and `ProviderTestSupport` in tests. Prefer a small contract over a new dependency.

## Validate and submit

Run focused tests while iterating, then run:

```bash
scripts/verify.sh offline
```

Real-model and live-provider checks are opt-in; see the [verification lanes](guide/development.md). Do not run billable calls just because a credential happens to be available. Report which checks ran, which skipped, and any remaining uncertainty.

A pull request should explain the user-visible problem, the resulting behavior, the relevant ownership or data changes, and verification. Include native screenshots for visible UI changes, using the fictional sample or other synthetic content. Keep text legible, support light and dark appearances, and preserve keyboard and accessibility labels. Do not substitute generated UI mockups for screenshots of the implementation.

Keep changes focused and preserve unrelated work. Do not include build outputs, credentials, real meeting data, or private planning material. Original contributions are made under the project’s [MIT license](LICENSE); preserve third-party attribution and document any new redistribution requirements.
