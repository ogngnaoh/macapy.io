# Security

macapy is currently a source preview. There is no supported stable binary release or guaranteed security-response timetable. Fixes are developed against the current native source; the archived legacy implementation is not maintained.

## Reporting a concern

If GitHub displays **Report a vulnerability** in this repository’s Security tab, use that private reporting flow. Availability of that channel has not yet been confirmed for this preview.

Otherwise, open a [minimal issue](https://github.com/ogngnaoh/macapy.io/issues/new) titled **Request private security contact**. Include only a request to coordinate privately and a safe way to reach you. Do not post exploit details, credentials, transcripts, database files, private request bodies, or personal information. Wait for a private channel before sending sensitive reproduction material. Public issue reporting is enabled; a dedicated private contact must be verified before a stable release.

A useful private report describes the affected revision, supported macOS version, attack prerequisites, observed impact, and a minimal reproduction using synthetic data. Avoid testing against other people’s meetings, provider accounts, or devices.

## Boundaries to preserve

Raw audio is transient and must never be persisted or sent to a provider. Provider credentials belong in Keychain. Optional AI can transmit meeting text to the configured endpoint; the endpoint’s own handling is outside macapy’s control. Local SQLite data is not application-encrypted, and deletion is not a secure-erasure guarantee. See the [privacy guide](guide/privacy.md) for the complete storage boundary.

Particularly useful reports concern unintended network destinations, credential or content disclosure in logs, stale tasks restoring deleted content, ephemeral meetings writing persistent data, and optional work interfering with capture. Findings should identify a concrete behavior rather than assuming that local-first means all text always remains offline.
