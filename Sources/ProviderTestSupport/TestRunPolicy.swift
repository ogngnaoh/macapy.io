import Foundation

/// Explicit opt-in for tests that depend on installed models or a billable service.
/// Merely having model assets or credentials on a developer machine never enables
/// these lanes. This target is test support and is not linked into the app.
public enum TestRunPolicy {
    public static let localModelsVariable = "MACAPY_RUN_LOCAL_MODEL_TESTS"
    public static let liveProviderVariable = "MACAPY_RUN_LIVE_PROVIDER_TESTS"

    public static var runsLocalModels: Bool {
        localModelsEnabled(in: ProcessInfo.processInfo.environment)
    }

    public static var runsLiveProvider: Bool {
        liveProviderEnabled(in: ProcessInfo.processInfo.environment)
    }

    static func localModelsEnabled(in environment: [String: String]) -> Bool {
        environment[localModelsVariable] == "1"
    }

    static func liveProviderEnabled(in environment: [String: String]) -> Bool {
        environment[liveProviderVariable] == "1"
            && LiveCredentials.value(of: LiveCredentials.deepSeekVariable, in: environment) != nil
    }
}
