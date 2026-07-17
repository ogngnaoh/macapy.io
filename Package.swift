// swift-tools-version: 6.0

// macapy's module layout (SPEC §6.1): each module is an SPM target, AppShell is
// the only one that touches SwiftUI app plumbing. The thin app target in
// macapy.xcodeproj imports the AppShell product; everything else hangs off it.
import PackageDescription

let package = Package(
    name: "macapy",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "AppShell", targets: ["AppShell"])
    ],
    targets: [
        .target(name: "CaptureKit"),
        .target(name: "TranscribeKit", dependencies: ["CaptureKit"]),
        .target(name: "PersistKit"),
        .target(name: "AgentKit"),
        .target(name: "ProviderKit"),
        .target(
            name: "AppShell",
            dependencies: ["CaptureKit", "TranscribeKit", "PersistKit", "AgentKit", "ProviderKit"]
        ),
        .testTarget(name: "CaptureKitTests", dependencies: ["CaptureKit"]),
        .testTarget(
            name: "TranscribeKitTests",
            dependencies: ["TranscribeKit", "CaptureKit"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "AppShellTests", dependencies: ["AppShell"]),
    ]
)
