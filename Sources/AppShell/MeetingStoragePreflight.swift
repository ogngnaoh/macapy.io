import Foundation

/// A small reserve for SQLite/WAL and transcript writes, not a promise that a
/// disk cannot fill later. The existing bounded persistence fallback remains
/// responsible for failures after capture starts.
struct MeetingStoragePreflight: Sendable {
    enum Failure: Error, Sendable { case unavailable, insufficientCapacity }
    static let minimumFreeBytes: Int64 = 64 * 1_024 * 1_024
    let inspect: @Sendable (URL) throws -> Int64?
    let probeWrite: @Sendable (URL) throws -> Void

    init(
        inspect: @escaping @Sendable (URL) throws -> Int64? = Self.availableCapacity,
        probeWrite: @escaping @Sendable (URL) throws -> Void = Self.checkWritable
    ) {
        self.inspect = inspect
        self.probeWrite = probeWrite
    }

    func check(directory: URL) async throws {
        guard directory.isFileURL else { throw Failure.unavailable }
        try await Task.detached(priority: .userInitiated) {
            do {
                guard let capacity = try inspect(directory) else { throw Failure.unavailable }
                guard capacity >= Self.minimumFreeBytes else { throw Failure.insufficientCapacity }
                try probeWrite(directory)
            } catch let error as Failure { throw error }
            catch { throw Failure.unavailable }
        }.value
    }

    /// Production-only injection before a *persistent* meeting. History reads,
    /// ephemeral meetings, sample entry, and tests do not call this by default.
    static func production() async throws {
        let directory: URL
        do {
            directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: true)
                .appendingPathComponent("macapy", isDirectory: true)
        } catch { throw Failure.unavailable }
        try await Self().check(directory: directory)
    }

    private static func availableCapacity(_ directory: URL) throws -> Int64? {
        // An uncreated app directory shares its existing parent's volume.
        var existing = directory
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            existing.deleteLastPathComponent()
        }
        let values = try existing.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        return values.volumeAvailableCapacityForImportantUsage ?? values.volumeAvailableCapacity.map(Int64.init)
    }

    private static func checkWritable(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let probe = directory.appendingPathComponent(".macapy-write-probe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: probe) }
        guard FileManager.default.createFile(atPath: probe.path, contents: Data(), attributes: [.posixPermissions: 0o600]) else {
            throw Failure.unavailable
        }
        try FileManager.default.removeItem(at: probe)
    }
}
