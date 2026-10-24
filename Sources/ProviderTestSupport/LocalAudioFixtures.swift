import Foundation

/// Speech fixture audio is supplied explicitly by its local owner, never
/// bundled or downloaded. Only this test-support target reads the path.
public enum LocalAudioFixtures {
    public static let directoryVariable = "MACAPY_LOCAL_AUDIO_FIXTURES"

    public static func url(named name: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        guard !name.isEmpty, !name.contains("/"), !name.contains("\\"), name != ".", name != "..",
              let directory = environment[directoryVariable], directory.hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(name)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
        return url
    }

    public static func has(_ names: [String]) -> Bool { names.allSatisfy { url(named: $0) != nil } }
}
