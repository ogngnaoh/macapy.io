import Foundation
import ProviderTestSupport
import Testing

struct LocalAudioFixturesTests {
    @Test func fixturesRequireAnExplicitAbsoluteDirectoryAndExistingFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("macapy-audio-policy-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("synthetic bytes, not audio".utf8).write(to: root.appendingPathComponent("fox.wav"))
        #expect(LocalAudioFixtures.url(named: "fox.wav", environment: [:]) == nil)
        #expect(LocalAudioFixtures.url(named: "fox.wav", environment: [LocalAudioFixtures.directoryVariable: "relative"]) == nil)
        let environment = [LocalAudioFixtures.directoryVariable: root.path]
        #expect(LocalAudioFixtures.url(named: "fox.wav", environment: environment) != nil)
        #expect(LocalAudioFixtures.url(named: "missing.wav", environment: environment) == nil)
        #expect(LocalAudioFixtures.url(named: "../fox.wav", environment: environment) == nil)
        #expect(LocalAudioFixtures.url(named: ".", environment: environment) == nil)
    }
}
