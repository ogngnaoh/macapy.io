import Foundation
import Testing

@testable import ProviderTestSupport

/// The gate that decides whether a live suite runs or skips.
///
/// Worth real tests despite its size, because the failure it prevents is
/// silent: if an empty value counted as "present", `DeepSeekLiveTests` would
/// look enabled on every machine, send `Authorization: Bearer ` to the real
/// endpoint, and report a 401 that looks like a broken key rather than a
/// missing one. `.envrc` exports unconditionally (`... || true`), so empty is
/// the *expected* state on any machine without the Keychain item — which is
/// most of them.
///
/// These read from an injected dictionary rather than the real environment.
/// The first version drove `setenv`/`unsetenv` and raced: swift-testing runs a
/// suite's tests concurrently, all five mutated one process-global variable,
/// and `--filter LiveCredentialsTests` failed about one run in four. Caught by
/// the slice's evaluator, not by the suite itself — a full run's extra
/// scheduling noise happened to hide it every time.
struct LiveCredentialsTests {

    private static let name = "MACAPY_PROBE_KEY"

    @Test func anUnsetVariableReadsAsAbsent() {
        #expect(LiveCredentials.value(of: Self.name, in: [:]) == nil)
    }

    @Test func anEmptyVariableReadsAsAbsent() {
        #expect(
            LiveCredentials.value(of: Self.name, in: [Self.name: ""]) == nil,
            "empty must skip the suite, not send an empty bearer token"
        )
    }

    @Test func aWhitespaceOnlyVariableReadsAsAbsent() {
        #expect(LiveCredentials.value(of: Self.name, in: [Self.name: "  \n\t "]) == nil)
    }

    @Test func aRealValueIsReadAndTrimmed() {
        #expect(
            LiveCredentials.value(of: Self.name, in: [Self.name: "  sk-not-a-real-key\n"]) == "sk-not-a-real-key"
        )
    }

    /// A neighbouring variable must not satisfy the lookup — otherwise the
    /// "absent" cases above could pass for the wrong reason.
    @Test func anUnrelatedVariableDoesNotSatisfyTheLookup() {
        #expect(LiveCredentials.value(of: Self.name, in: ["SOMETHING_ELSE": "sk-real"]) == nil)
    }

    /// The invariant the `@Suite(.enabled(if:))` trait actually rests on, read
    /// against the *real* process environment: the flag and the value can never
    /// disagree, whatever this machine happens to have set.
    @Test func theEnableFlagAlwaysAgreesWithTheKeysPresence() {
        #expect(LiveCredentials.hasDeepSeek == (LiveCredentials.deepSeekKey != nil))
    }
}
