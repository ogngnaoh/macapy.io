import Foundation

/// Where the *real* provider key comes from when a live check runs.
///
/// The key is read from the process environment and never from a file in the
/// repo. That is a deliberate consequence of SPEC §8 ("API keys only in
/// Keychain — never in the DB, config files, or logs"): a plaintext `.env`
/// would contradict, in the project's own working tree, the guarantee the app
/// makes to its users. `.envrc` seeds this variable from a Keychain item
/// (`security add-generic-password -s io.macapy.dev -a deepseek -w`), so the
/// secret stays encrypted at rest and rotation has exactly one place to happen.
///
/// **Absence is the normal case.** A fresh clone, CI, and every contributor
/// runs `swift test` with no key at all; live suites gate on `hasDeepSeek` and
/// *skip*, never fail. That is what keeps acceptance check 8 ("full `swift
/// test` green") an honest claim for someone who has never opened a provider
/// account.
public enum LiveCredentials {
    /// Seeded by `.envrc` from the `io.macapy.dev` Keychain item.
    public static let deepSeekVariable = "MACAPY_DEEPSEEK_KEY"

    /// The key, or `nil` when unset *or empty*.
    ///
    /// Empty counts as absent on purpose: `.envrc` exports unconditionally
    /// (`... || true`), so a machine with no Keychain item produces `""` rather
    /// than an unset variable. Without this, a live suite would look enabled
    /// and then send `Authorization: Bearer ` upstream — a confusing 401 in
    /// place of a clean skip.
    public static var deepSeekKey: String? {
        value(of: deepSeekVariable)
    }

    /// Whether the DeepSeek live suite can run at all.
    public static var hasDeepSeek: Bool { deepSeekKey != nil }

    /// Reads one environment variable, treating whitespace-only as absent.
    ///
    /// `environment` is injectable so the absent/empty/whitespace cases can be
    /// tested as pure data. The first version of these tests drove real
    /// `setenv`/`unsetenv` instead, which raced: swift-testing runs a suite's
    /// tests concurrently, they all mutated one process-global variable, and
    /// `--filter LiveCredentialsTests` failed roughly one run in four. A test
    /// that needs serialization to pass is hiding a race rather than
    /// tolerating one (M1 slice-4 lesson) — so the global mutation is gone
    /// instead of merely ordered.
    static func value(
        of name: String,
        in environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        guard let raw = environment[name] else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
