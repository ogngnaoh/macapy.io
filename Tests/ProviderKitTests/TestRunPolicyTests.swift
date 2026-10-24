import Testing

@testable import ProviderTestSupport

struct TestRunPolicyTests {
    @Test func incidentalCredentialsDoNotEnableAnyOptionalLane() {
        let environment = [LiveCredentials.deepSeekVariable: "synthetic-key"]
        #expect(!TestRunPolicy.liveProviderEnabled(in: environment))
        #expect(!TestRunPolicy.localModelsEnabled(in: environment))
    }

    @Test(arguments: [nil, "", "0", "true", "yes", " 1", "1 "])
    func onlyAnExactOneEnablesTheLocalModelLane(_ flag: String?) {
        var environment: [String: String] = [:]
        environment[TestRunPolicy.localModelsVariable] = flag
        #expect(!TestRunPolicy.localModelsEnabled(in: environment))
    }

    @Test func localModelsAndLiveProviderAreIndependentOptIns() {
        let environment = [TestRunPolicy.localModelsVariable: "1"]
        #expect(TestRunPolicy.localModelsEnabled(in: environment))
        #expect(!TestRunPolicy.liveProviderEnabled(in: environment))
    }

    @Test(arguments: [nil, "", " \n\t"])
    func explicitLiveOptInStillRequiresANonemptyCredential(_ credential: String?) {
        var environment = [TestRunPolicy.liveProviderVariable: "1"]
        environment[LiveCredentials.deepSeekVariable] = credential
        #expect(!TestRunPolicy.liveProviderEnabled(in: environment))
    }

    @Test(arguments: [nil, "", "0", "true", "yes", " 1", "1 "])
    func credentialsNeverSubstituteForExactLiveOptIn(_ flag: String?) {
        var environment = [LiveCredentials.deepSeekVariable: "synthetic-key"]
        environment[TestRunPolicy.liveProviderVariable] = flag
        #expect(!TestRunPolicy.liveProviderEnabled(in: environment))
    }

    @Test func explicitLiveOptInAndCredentialEnableOnlyTheLiveLane() {
        let environment = [
            LiveCredentials.deepSeekVariable: " synthetic-key ",
            TestRunPolicy.liveProviderVariable: "1",
        ]
        #expect(TestRunPolicy.liveProviderEnabled(in: environment))
        #expect(!TestRunPolicy.localModelsEnabled(in: environment))
    }
}
