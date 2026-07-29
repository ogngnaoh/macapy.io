// swift-tools-version: 6.0

// macapy's module layout (SPEC §6.1): each module is an SPM target, AppShell is
// the only one that touches SwiftUI app plumbing. The thin app target in
// macapy.xcodeproj imports the AppShell product; everything else hangs off it.
import PackageDescription

let package = Package(
    name: "macapy",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "AppShell", targets: ["AppShell"]),
        // The latency harness executable (slice-05 doc decision 2): a
        // separate product so `swift run -c release macapy-latency
        // <fixture.wav>` gives the authoritative G1 number.
        .executable(name: "macapy-latency", targets: ["LatencyHarness"]),
    ],
    dependencies: [
        // PersistKit's one external dependency (SPEC §5 sanctioned; slice 4).
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1")
    ],
    targets: [
        .target(name: "CaptureKit"),
        .target(name: "TranscribeKit", dependencies: ["CaptureKit"]),
        // Depends on ProviderKit for the `SpendLedger` contract and `SpendEntry`
        // (slice 2). The edge points this way on purpose: persistence knowing a
        // few provider value types is cheap, whereas ProviderKit depending on
        // PersistKit would drag GRDB into what must stay a thin network layer.
        .target(name: "PersistKit", dependencies: [
            "TranscribeKit",
            "ProviderKit",
            .product(name: "GRDB", package: "GRDB.swift"),
        ]),
        .target(name: "AgentKit"),
        .target(name: "ProviderKit"),
        // The fake OpenAI-compatible server (slice-02 doc decision 6) lives in
        // its own library target, not inside ProviderKitTests, because slice 3
        // (post-meeting agent) and M3 (copilot cascade) reuse it from *their*
        // test targets. It is deliberately absent from `products`, so the app
        // can never link it.
        //
        // The ProviderKit edge is declared even though the current build
        // tolerates its absence: `FakeProfile.swift` imports ProviderKit, and
        // an undeclared import is a clean-checkout failure waiting to happen.
        .target(name: "ProviderTestSupport", dependencies: ["ProviderKit"]),
        .target(
            name: "AppShell",
            dependencies: ["CaptureKit", "TranscribeKit", "PersistKit", "AgentKit", "ProviderKit"],
            // Martian Mono (OFL, license alongside): the design system's
            // "machine voice" face, registered at startup by FontRegistrar.
            resources: [.copy("Resources/Fonts")]
        ),
        // Shared by the LatencyHarness executable and G1BudgetTests
        // (slice-05 doc layout) — one `runHarness(fixtureURL:)` code path,
        // two configs/fixtures/consumers.
        .target(name: "LatencyHarnessLib", dependencies: ["CaptureKit", "TranscribeKit"]),
        .executableTarget(name: "LatencyHarness", dependencies: ["LatencyHarnessLib"]),
        .testTarget(name: "CaptureKitTests", dependencies: ["CaptureKit"]),
        .testTarget(
            name: "TranscribeKitTests",
            dependencies: ["TranscribeKit", "CaptureKit"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "AppShellTests",
            dependencies: ["AppShell", "PersistKit", "ProviderKit", "ProviderTestSupport"]
        ),
        // PersistKit is here for the key-leak check (acceptance check 5): the
        // test writes a canary key, runs real calls, then greps the actual
        // database files and the process's own log entries for it.
        .testTarget(
            name: "ProviderKitTests",
            dependencies: ["ProviderKit", "ProviderTestSupport", "PersistKit"]
        ),
        .testTarget(
            name: "PersistKitTests",
            dependencies: ["PersistKit", "TranscribeKit", "CaptureKit", "ProviderKit"]
        ),
        .testTarget(
            name: "G1BudgetTests",
            dependencies: ["LatencyHarnessLib"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
