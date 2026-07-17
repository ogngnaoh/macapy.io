import Foundation
import LatencyHarnessLib

// Thin over LatencyHarnessLib (slice-05 doc decision 2): parse the one
// argument, run the shared harness, print the report as JSON to stdout, exit
// 0/1 on pass_g1. The authoritative run is
// `swift run -c release macapy-latency <fixture.wav>` — release config is
// what actually proves G1 (exit criterion 1); this file does no measurement
// of its own.

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: macapy-latency <fixture.wav>\n".utf8))
    exit(2)
}

let fixtureURL = URL(fileURLWithPath: arguments[1])

do {
    let report = try await runHarness(fixtureURL: fixtureURL)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(report)
    print(String(decoding: data, as: UTF8.self))
    exit(report.passG1 ? 0 : 1)
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(2)
}
