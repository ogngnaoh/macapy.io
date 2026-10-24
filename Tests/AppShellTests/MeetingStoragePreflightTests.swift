import Foundation
import Testing

@testable import AppShell

struct MeetingStoragePreflightTests {
    final class Counter: @unchecked Sendable {
        let lock = NSLock()
        var writes = 0
        func write() { lock.withLock { writes += 1 } }
        var count: Int { lock.withLock { writes } }
    }

    @Test func insufficientOrUnknownCapacityDoesNotAttemptAWrite() async {
        let counter = Counter()
        for capacity in [Int64(0), MeetingStoragePreflight.minimumFreeBytes - 1, nil] {
            let preflight = MeetingStoragePreflight(inspect: { _ in capacity }, probeWrite: { _ in counter.write() })
            await #expect(throws: MeetingStoragePreflight.Failure.self) {
                try await preflight.check(directory: URL(fileURLWithPath: "/tmp/fictional-preflight"))
            }
        }
        #expect(counter.count == 0)
    }

    @Test func nativeFailureBecomesSanitizedStorageFailure() async {
        let preflight = MeetingStoragePreflight(inspect: { _ in MeetingStoragePreflight.minimumFreeBytes }, probeWrite: { _ in
            throw NSError(domain: "Fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "private path and contents"])
        })
        do { try await preflight.check(directory: URL(fileURLWithPath: "/tmp/fixture")); Issue.record("Expected refusal") }
        catch {
            #expect(error is MeetingStoragePreflight.Failure)
            await MainActor.run { #expect(SessionFailure.classify(error) == .storage) }
            #expect(!String(describing: error).contains("private"))
        }
    }

    @Test func realEmptyProbeLeavesNoFilesAndDoesNotTouchExistingContent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("macapy-preflight-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let existing = directory.appendingPathComponent("fixture.txt")
        try Data("fixture".utf8).write(to: existing)
        let preflight = MeetingStoragePreflight(inspect: { _ in MeetingStoragePreflight.minimumFreeBytes })
        try await preflight.check(directory: directory)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["fixture.txt"])
        #expect(try String(contentsOf: existing, encoding: .utf8) == "fixture")
    }

    @Test func remoteDestinationIsRejectedBeforeAnyProbe() async {
        let counter = Counter()
        let preflight = MeetingStoragePreflight(inspect: { _ in counter.write(); return Int64.max }, probeWrite: { _ in counter.write() })
        await #expect(throws: MeetingStoragePreflight.Failure.self) {
            try await preflight.check(directory: URL(string: "https://example.invalid/storage")!)
        }
        #expect(counter.count == 0)
    }
}
