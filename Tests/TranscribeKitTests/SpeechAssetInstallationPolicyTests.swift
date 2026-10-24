import Foundation
import Testing

@testable import TranscribeKit

struct SpeechAssetInstallationPolicyTests {
    private let locale = Locale(identifier: "en_US")

    @Test(arguments: [true, false])
    func installedOnlyNeverInvokesInstaller(_ installed: Bool) async throws {
        var installerCalls = 0
        var failure: (any Error)?
        do {
            try await SpeechAnalyzerEngine.prepareAssets(
                locale: locale, policy: .installedOnly,
                isInstalled: { installed },
                install: { installerCalls += 1 }
            )
        } catch {
            failure = error
        }

        #expect(installerCalls == 0, "An installed-only run must never request a download")
        if installed {
            #expect(failure == nil)
        } else {
            let error = try #require(failure as? TranscribeError)
            guard case .assetsUnavailable(let unavailableLocale, _) = error else {
                Issue.record("Missing local assets must report assetsUnavailable")
                return
            }
            #expect(unavailableLocale == locale)
        }
    }

    @Test func setupPolicyDelegatesInstallationToTheInstaller() async throws {
        var installerCalls = 0
        try await SpeechAnalyzerEngine.prepareAssets(
            locale: locale, policy: .allowDownload,
            isInstalled: { Issue.record("Setup delegates the availability check to the platform installer"); return false },
            install: { installerCalls += 1 }
        )
        #expect(installerCalls == 1)
    }

    @Test func setupPropagatesInstallationFailure() async {
        enum InstallationFailure: Error { case rejected }
        await #expect(throws: InstallationFailure.rejected) {
            try await SpeechAnalyzerEngine.prepareAssets(
                locale: locale, policy: .allowDownload,
                isInstalled: { false },
                install: { throw InstallationFailure.rejected }
            )
        }
    }
}
