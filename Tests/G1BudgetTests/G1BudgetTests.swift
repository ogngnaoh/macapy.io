import Foundation
import LatencyHarnessLib
import Testing

/// Check 3 (slice 5) — regression tripwire, explicitly **NOT** the G1 proof
/// (slice-05 doc decision 6). Runs the shared harness library, in whatever
/// config `swift test` was built with (normally debug), against a short
/// committed fixture. Debug is measurably slower than a release build, so
/// this only asserts a loose ceiling meant to catch gross regressions in
/// CI-ish runs — the authoritative G1 number is the user's
/// `swift run -c release macapy-latency <fixture>`, recorded in
/// milestone.md.
struct G1BudgetTests {

    @Test func shortFixtureStaysUnderTheDebugConfigCeiling() async throws {
        guard let url = Bundle.module.url(forResource: "fox", withExtension: "wav", subdirectory: "Fixtures") else {
            Issue.record("environment-blocked: fixture fox.wav missing from test bundle")
            return
        }

        let report: HarnessReport
        do {
            report = try await runHarness(fixtureURL: url)
        } catch {
            Issue.record("environment-blocked: harness run failed — \(error)")
            return
        }

        #expect(report.fixture == "fox.wav")
        #expect(report.nVolatile > 0, "expected at least one volatile event")
        #expect(report.nFinal > 0, "expected at least one final event")
        // Loose debug-config ceiling — NOT the G1 claim. See doc comment above.
        #expect(
            report.p95Ms < 1_500,
            "debug-config regression ceiling breached: p95=\(report.p95Ms)ms"
        )
        // passG1 (the strict <1000ms check) is intentionally not asserted
        // here: debug builds are legitimately slower than the release
        // harness run that actually proves G1.
    }
}
