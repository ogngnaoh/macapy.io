import AppKit
import Testing

@testable import AppShell

/// The design system's machine face (Martian Mono, bundled OFL) must be
/// registered process-wide before any view asks for it — named instances
/// resolve by PostScript name after registration.
struct FontRegistrarTests {
    @Test func registersMartianMonoNamedInstances() {
        #expect(FontRegistrar.registerIfNeeded())
        for name in ["MartianMono-Regular", "MartianMono-SemiBold", "MartianMono-Bold"] {
            #expect(NSFont(name: name, size: 12) != nil, "\(name) should resolve after registration")
        }
    }

    @Test func registrationIsIdempotent() {
        #expect(FontRegistrar.registerIfNeeded())
        #expect(FontRegistrar.registerIfNeeded())
    }
}
