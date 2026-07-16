import AppShell
import SwiftUI

// Thin shim: the app target owns only the entry point; all real app plumbing
// lives in the AppShell module (SPEC §6.1).
@main
struct MacapyApp: App {
    var body: some Scene {
        AppShellScenes()
    }
}
