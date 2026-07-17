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
        .target(name: "PersistKit", dependencies: [
            "TranscribeKit",
            .product(name: "GRDB", package: "GRDB.swift"),
        ]),
        .target(name: "AgentKit"),
        .target(name: "ProviderKit"),
        .target(
            name: "AppShell",
            dependencies: ["CaptureKit", "TranscribeKit", "PersistKit", "AgentKit", "ProviderKit"]
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
        .testTarget(name: "AppShellTests", dependencies: ["AppShell", "PersistKit"]),
        .testTarget(name: "PersistKitTests", dependencies: ["PersistKit", "TranscribeKit", "CaptureKit"]),
        .testTarget(
            name: "G1BudgetTests",
            dependencies: ["LatencyHarnessLib"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
