import Foundation
import GRDB

/// Builds and caches the seeded-scale search fixture (slice-05 doc decision
/// 10): a real on-disk database at history scale — ≥ 50 meetings (two spanning
/// 3+ hours), ≥ 1.2×10⁵ segments, ~150 artifacts — with planted needle
/// tokens, written through raw prepared statements in chunked transactions
/// (bypassing row-by-row `append`) and cached at a version-keyed temp path.
/// The cache is rebuilt only on `version` bump; `MACAPY_SEARCH_SCALE`
/// multiplies segment volume to reach the 10⁶ band ad hoc.
///
/// Lives in PersistKit (not a test target) per the slice plan so the scale
/// suite and any future harness share one seeding path. Nothing in the app
/// calls it.
public enum SearchFixtureSeeder {
    /// Bump to invalidate every cached fixture.
    public static let version = 1

    /// Planted exactly once, in a segment of the largest meeting.
    public static let needleToken = "kestrelmauve"
    /// Planted exactly once, in one meeting's title.
    public static let titleNeedleToken = "peregrinegold"
    /// Planted exactly once, in one action-item artifact's title.
    public static let artifactNeedleToken = "quailsilver"
    /// Present in every ninth segment — the "common token" perf query.
    public static let commonToken = "milestone"

    /// The floors check 6 asserts (scaled by `scale()` for segments).
    public enum Floors {
        public static let meetings = 50
        public static let segments = 120_000
        public static let artifacts = 150
        public static let threeHourMeetings = 2
    }

    public struct Fixture {
        public let url: URL
        public let builtThisCall: Bool
        public let buildSeconds: Double?
    }

    /// `MACAPY_SEARCH_SCALE` (default 1) multiplies per-meeting segment
    /// counts.
    public static func scale() -> Int {
        max(1, ProcessInfo.processInfo.environment["MACAPY_SEARCH_SCALE"].flatMap(Int.init) ?? 1)
    }

    /// Version-keyed cache location: a version or scale bump changes the
    /// path, so a stale cache can never be mistaken for a current one.
    public static func cacheURL(version: Int, scale: Int) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("macapy-search-fixture-v\(version)-x\(scale)", isDirectory: true)
            .appendingPathComponent("fixture.sqlite")
    }

    /// Returns the cached fixture, building it first if absent. The build
    /// lands in a scratch directory and is renamed into place, so a crashed
    /// build can't leave a torn cache behind.
    public static func fixture() throws -> Fixture {
        let scale = scale()
        let url = cacheURL(version: version, scale: scale)
        if FileManager.default.fileExists(atPath: url.path) {
            return Fixture(url: url, builtThisCall: false, buildSeconds: nil)
        }

        let scratchDir = url.deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("building-\(UUID().uuidString)", isDirectory: true)
        let scratchURL = scratchDir.appendingPathComponent(url.lastPathComponent)
        let start = ContinuousClock.now
        try build(at: scratchURL, scale: scale)
        let elapsed = (ContinuousClock.now - start).seconds
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent().deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try FileManager.default.moveItem(
                at: scratchDir, to: url.deletingLastPathComponent())
        } catch {
            // Lost a build race: someone else's fixture is in place — use it.
            guard FileManager.default.fileExists(atPath: url.path) else { throw error }
            try? FileManager.default.removeItem(at: scratchDir)
            return Fixture(url: url, builtThisCall: false, buildSeconds: nil)
        }
        return Fixture(url: url, builtThisCall: true, buildSeconds: elapsed)
    }

    // MARK: - Build

    private static func build(at url: URL, scale: Int) throws {
        let database = try MacapyDatabase.onDisk(at: url)
        var rng = SplitMix64(seed: 0x5EED_0F_5EED)

        // Per-meeting segment counts: two large meetings, the rest sampled.
        // Sum ≥ 120_000 × scale by construction (2×25_000 + 48×⌊1_500…2_500⌋).
        var segmentCounts = [25_000 * scale, 25_000 * scale]
        for _ in 2..<Floors.meetings {
            segmentCounts.append(Int.random(in: 1_500...2_500, using: &rng) * scale)
        }

        try database.dbWriter.writeWithoutTransaction { db in
            var meetingIDs: [UUID] = []
            try db.inTransaction {
                let insertMeeting = try db.cachedStatement(
                    sql: """
                        INSERT INTO meetings (id, title, startedAt, endedAt, status, ephemeral)
                        VALUES (?, ?, ?, ?, 'ended', 0)
                        """)
                for (index, count) in segmentCounts.enumerated() {
                    let id = UUID()
                    meetingIDs.append(id)
                    var title = "Meeting \(index) \(words(2, &rng))"
                    if index == 7 {
                        title = "The \(titleNeedleToken) review"
                    }
                    // 2.5 s per segment; the two large meetings clear 3 h by
                    // orders of magnitude, the rest stay ~1–2 h.
                    let startedAt = Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 90_000)
                    let endedAt = startedAt.addingTimeInterval(Double(count) * 2.5)
                    try insertMeeting.execute(arguments: [id, title, startedAt, endedAt])
                }
                return .commit
            }

            // Segments in chunked transactions of 10k — one prepared
            // statement, no per-row Record machinery.
            let insertSegment = try db.cachedStatement(
                sql: """
                    INSERT INTO segments (id, meetingID, source, text, tStart, tEnd, isFinal, speakerId)
                    VALUES (?, ?, ?, ?, ?, ?, 1, NULL)
                    """)
            var globalIndex = 0
            for (meetingIndex, count) in segmentCounts.enumerated() {
                let meetingID = meetingIDs[meetingIndex]
                var written = 0
                while written < count {
                    let chunk = min(10_000, count - written)
                    try db.inTransaction {
                        for row in 0..<chunk {
                            let index = written + row
                            var text = words(Int.random(in: 8...14, using: &rng), &rng)
                            if globalIndex % 9 == 0 {
                                text += " \(commonToken)"
                            }
                            if meetingIndex == 0 && index == 12_345 {
                                text = "the \(needleToken) baseline drifted overnight"
                            }
                            let tStart = Double(index) * 2.5
                            try insertSegment.execute(arguments: [
                                UUID(), meetingID,
                                index.isMultiple(of: 3) ? "us" : "them",
                                text, tStart, tStart + 2.4,
                            ])
                            globalIndex += 1
                        }
                        return .commit
                    }
                    written += chunk
                }
            }

            // ~150 artifacts cycling kinds, searchText derived by the same
            // function live inserts use.
            try db.inTransaction {
                let insertArtifact = try db.cachedStatement(
                    sql: """
                        INSERT INTO artifacts (id, meetingID, kind, payload, status, createdAt, searchText)
                        VALUES (?, ?, ?, ?, 'draft', ?, ?)
                        """)
                for index in 0..<Floors.artifacts {
                    let meetingID = meetingIDs[index % meetingIDs.count]
                    let kind: ArtifactKind = [.summary, .decision, .actionItem][index % 3]
                    let payload: String
                    switch kind {
                    case .summary:
                        payload = #"{"text":"\#(words(12, &rng))"}"#
                    case .decision:
                        payload = #"{"text":"\#(words(8, &rng))"}"#
                    case .actionItem:
                        let title = index == 32  // 32 % 3 == 2 → this branch's kind
                            ? "chase the \(artifactNeedleToken) numbers"
                            : words(5, &rng)
                        payload = #"{"title":"\#(title)","owner":"\#(words(1, &rng))","deadline":"Friday"}"#
                    }
                    try insertArtifact.execute(arguments: [
                        UUID(), meetingID, kind.rawValue, payload,
                        Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 1_000),
                        ArtifactSearchText.derive(kind: kind.rawValue, payload: payload),
                    ])
                }
                return .commit
            }

            // Empty the WAL so the cache is the single .sqlite file — the
            // incremental-index test copies just that file.
            try db.checkpoint(.truncate)
        }
    }

    private static func words(_ count: Int, _ rng: inout SplitMix64) -> String {
        (0..<count).map { _ in wordBank[Int.random(in: 0..<wordBank.count, using: &rng)] }
            .joined(separator: " ")
    }

    /// Invented-but-plausible vocabulary; none of these collide with the
    /// needle tokens or with each other's prefixes in a way that would make
    /// prefix search counts nondeterministic.
    private static let wordBank: [String] = [
        "sprint", "review", "budget", "vendor", "launch", "metric", "signal",
        "roadmap", "handoff", "staging", "rollout", "backlog", "triage",
        "onboard", "pipeline", "quarter", "forecast", "headcount", "renewal",
        "contract", "latency", "uptime", "incident", "postmortem", "retro",
        "deadline", "scope", "estimate", "capacity", "hiring", "design",
        "prototype", "feedback", "customer", "churn", "revenue", "margin",
        "audit", "compliance", "security", "storage", "cluster", "deploy",
        "release", "regression", "coverage", "fixture", "schema", "index",
        "cache", "queue", "worker", "billing", "invoice", "payroll", "offsite",
        "agenda", "minutes", "action", "blocker", "status", "update", "sync",
    ]
}

/// Deterministic RNG for the fixture (SplitMix64): same seed, same corpus,
/// on every machine and every run.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

extension Duration {
    /// Seconds as a Double — for logging elapsed times as evidence.
    public var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
