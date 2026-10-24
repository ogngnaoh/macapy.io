# Release preparation

The release tooling prepares reviewable local archives, packages, and evidence. It does not publish GitHub releases, tags, or repository changes. An unsigned local candidate is useful for review; it is not a completed Developer ID distribution.

## Local candidate

Finish the automated [development checks](development.md) first. Stop changing source/resources during an archive so its recorded source snapshot remains meaningful. Existing staged and uncommitted work is preserved and recorded honestly.

```bash
scripts/build-release.sh --mode local --output .build/release-artifacts/review-01
scripts/package-release.sh .build/release-artifacts/review-01 local
```

The output directory must be new. The build uses Release configuration, `arm64`, hardened-runtime configuration, locked package versions, and disabled signing. The package contains the `.app` in a ZIP and produces:

- `source.json`: HEAD commit/tree, whether local changes exist, hashes of the actual public source files, and both dependency lockfile hashes.
- `bundle-verification.json`: architecture, signature classification, hardened-runtime/notarization observations, and pending clean-install status.
- `release-manifest.json`: source snapshot, version/build, toolchain/SDK, artifact size/checksum, notarization identity when available, and explicit unpublished status.
- `SHA256SUMS`: checksum of the final ZIP.

Source changes between archiving and packaging cause a failure, including uncommitted edits and new public files. Rebuild after any code, resource, dependency, or release-tool repair. A dirty candidate is identified by its actual source digest; its HEAD commit is not falsely presented as the exact built source tree.

To reuse an already-resolved Xcode package cache, set `MACAPY_SOURCE_PACKAGES` to its existing `SourcePackages` directory when running the archive script. The script validates the directory and forwards it to Xcode; it never creates or discovers one. The cache must already contain the pinned dependencies. Missing dependencies require a separate, explicitly intended setup step.

Inspect an existing app without launching it:

```bash
scripts/verify-release.sh .build/release-artifacts/review-01/macapy.xcarchive/Products/Applications/macapy.app --mode local
```

Local inspection checks resolved bundle metadata, capture/EventKit privacy descriptions, Apple Silicon architecture, exclusion of test/private material, and `LICENSE` plus `THIRD_PARTY_NOTICES.md` inside the app's resources. Archive/package scripts compare both notice hashes against the captured source snapshot; standalone inspection can do the same with `--source path/to/source.json`. Developer ID mode additionally checks the signature, hardened runtime, and unsafe entitlements. A valid signature alone does not prove successful capture permissions, Keychain access, or a clean-machine installation.

Run `python3 scripts/check-licenses.py` to detect exact dependency, notice, font, and synthetic-fixture inventory drift. Its optional `--release` mode also rejects explicitly unresolved provenance reviews. Historical speech WAVs are excluded from the current source tree under the documented [fixture policy](development.md#installed-model-evidence); older Git objects have not been rewritten. The separately downloaded legacy diarization assets still need asset-specific terms/provenance resolution before a distribution claim includes that feature. A source-code license does not settle model-weight rights.

## Developer ID and notarization

Distribution requires an Apple Developer membership, a valid Developer ID Application certificate/private key installed by its owner, the correct team ID, and a separately configured `notarytool` credential profile. The scripts never discover/export signing identities or credentials. These prerequisites and networked operations must be explicitly authorized before use.

With those prerequisites provided to the shell:

```bash
export MACAPY_ALLOW_SIGNING=1
export DEVELOPER_ID_APPLICATION='Developer ID Application: YOUR NAME (TEAMID)'
export DEVELOPMENT_TEAM='YOURTEAMID'
scripts/build-release.sh --mode developer-id --output .build/release-artifacts/signed-01
```

The team identifier must be the real ten-character Apple team ID. The identity value is the certificate label, not a credential. The archive and export use manual signing; the scripts do not create provisioning assets or silently obtain account access.

After reviewing and authorizing the upload to Apple:

```bash
MACAPY_ALLOW_NOTARIZATION=1 MACAPY_NOTARY_PROFILE='your-existing-profile' \
  scripts/notarize-release.sh .build/release-artifacts/signed-01
scripts/package-release.sh .build/release-artifacts/signed-01 notarized
```

The notarization step submits a temporary ZIP, requires Apple's `Accepted` response, and staples the app. The final distributable ZIP is created **after** stapling, so its checksum describes the ticket-bearing artifact. A stored submission identity is retained for investigation; reruns do not silently overwrite it. No step publishes the result.

Before a public release, verify the final artifact against the final tagged source tree, version/build, lockfiles, and release notes. The local tooling deliberately leaves the publication tag and release-note verification pending. Verify the downloaded archive checksum, Gatekeeper behavior on a supported clean installation, capture permissions, model readiness, Keychain continuity, and upgrade/migration behavior in an agent-controlled test environment. Hosted CI, notarization, clean-machine behavior, and upgrade evidence must be recorded as pending until actually executed.

## Install, data, upgrade, and removal

A completed distribution will be a signed, notarized macOS app for Apple Silicon and macOS 26 or later. Move the verified `.app` to Applications before launching it. A local unsigned candidate may be blocked by Gatekeeper; do not describe it as the user-ready download or recommend disabling system security controls.

The persistent meeting database lives at `~/Library/Application Support/macapy/macapy.sqlite`, including SQLite sidecars while open. Provider credentials live in Keychain under the `io.macapy.app` service. Speech assets are managed by macOS. Optional diarization assets use the shared FluidAudio model cache under `~/Library/Application Support/FluidAudio/Models/speaker-diarization/`.

Removing the app bundle alone does not delete its database or Keychain items. To clear app-managed content and retained preferences before uninstalling, use **Delete all meeting data** in Settings and confirm **DELETE**, then choose **Review preferences reset…** and confirm **RESET**. The second action clears provider/app and capture/setup preferences, macapy-owned API keys, customized shortcuts, and local usage records/budget counters, and turns off launch at login. Finish or resolve any reported partial reset before quitting and removing the app. Individual provider keys can also be removed separately in provider settings.

An explicit budget reset starts fresh local accounting; it does not refund or cancel charges, and uncertain requests may already have incurred charges. Shared installed speech/speaker models, macOS permissions, exported files, external Calendar/Reminders items, provider-held data, and backups remain. Shared model assets may be used by other applications and should not be removed indiscriminately. See [Privacy](privacy.md#retention-deletion-and-recovery) for these separate retention boundaries.

Quit the app before replacing it during a manual upgrade. Schema migrations are forward-only: replacing a newer app with an older binary is not a supported database rollback. Preserve approved local backups before an upgrade when required; never restore a snapshot that would resurrect content the user deleted.

Automatic update distribution, update signing, and a verified update from a previous signed version are separate release gates. They are not established by these packaging scripts. Until the updater's bounded cancellation and meeting-time network isolation are implemented and verified, keep automatic update scheduling disabled and describe the update path as manual.

Apple's primary references: [Developer ID distribution](https://developer.apple.com/developer-id/) and [notarizing macOS software](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).
