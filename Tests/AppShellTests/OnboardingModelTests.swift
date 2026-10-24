import Foundation
import Testing
@testable import AppShell

@MainActor
struct OnboardingModelTests {
    @Test func downloadLeaseExcludesSessionsUntilItIsReleased() {
        let gate = SetupActivityGate()
        let lease = gate.beginDownload()
        #expect(lease != nil)
        #expect(!gate.beginMeeting())
        #expect(gate.beginDownload() == nil)
        gate.endDownload(UUID())
        #expect(gate.isBusy)
        gate.endDownload(lease!)
        #expect(gate.beginMeeting())
        #expect(gate.beginDownload() == nil)
        gate.endMeeting()
        #expect(gate.beginDownload() != nil)
    }

    @Test func speechCannotInstallWhileMeetingOwnsGate() async {
        let environment = FakeSetupEnvironment()
        let gate = SetupActivityGate()
        let model = OnboardingModel(environment: environment, defaults: nil, activity: gate)
        #expect(gate.beginMeeting())
        await model.installSpeech()
        #expect(environment.installCount == 0)
        #expect(model.installationMessage != nil)
    }

    @Test func refreshOnlyInspectsAndNoKeyIsRequired() async {
        let environment = FakeSetupEnvironment()
        let model = OnboardingModel(environment: environment, defaults: nil)
        await model.refresh()
        #expect(environment.installCount == 0)
        #expect(environment.permissionRequests == 0)
        #expect(model.speechReady)
        #expect(model.microphone == .allowed)
        #expect(model.canFinish)
    }

    @Test func permissionDenialIsAnActionableState() async {
        let environment = FakeSetupEnvironment()
        environment.grantsMicrophone = false
        let model = OnboardingModel(environment: environment, defaults: nil)
        await model.requestMicrophone()
        #expect(model.microphone == .denied)
        #expect(!model.canFinish)
        #expect(environment.permissionRequests == 1)
    }

    @Test func assetInstallationIsExplicitAndFailureDoesNotExposeErrorText() async {
        let environment = FakeSetupEnvironment()
        environment.installed = false
        environment.installFails = true
        let model = OnboardingModel(environment: environment, defaults: nil)
        await model.refresh()
        #expect(environment.installCount == 0)
        await model.installSpeech()
        #expect(environment.installCount == 1)
        #expect(model.installationMessage != nil)
        #expect(model.installationMessage?.contains("secret") == false)
        #expect(!model.isInstalling)
    }

    @Test func cannotFinishBeforeSpeechAndMicrophoneAreReady() async {
        let environment = FakeSetupEnvironment()
        environment.installed = false
        let model = OnboardingModel(environment: environment, defaults: nil)
        await model.refresh()
        #expect(!model.finish())
        await model.installSpeech()
        #expect(model.finish())
        #expect(model.isComplete)
    }
}

@MainActor
private final class FakeSetupEnvironment: SetupEnvironment {
    var installed = true
    var grantsMicrophone = true
    var installFails = false
    var installCount = 0
    var permissionRequests = 0
    func microphoneStatus() -> MicrophonePermission { .allowed }
    func requestMicrophone() async -> Bool { permissionRequests += 1; return grantsMicrophone }
    func speechInstalled() async -> Bool { installed }
    func installSpeech() async throws {
        installCount += 1
        if installFails { throw NSError(domain: "secret", code: 1) }
        installed = true
    }
}
