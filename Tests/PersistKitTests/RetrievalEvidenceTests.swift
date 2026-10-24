import CryptoKit
import Darwin
import Foundation
import GRDB
import MemoryKit
import Testing
@testable import PersistKit

private struct EvidenceCorpus: Decodable, Sendable {
    let version: Int
    let baseEpoch: Double
    let sources: [EvidenceSource]
    let questions: [EvidenceQuestion]
}
private struct EvidenceSource: Decodable, Sendable {
    let key: Int
    let title: String
    let text: String
    let day: Int
    let state: String
}
private struct EvidenceQuestion: Decodable, Sendable {
    let id: String
    let category: String
    let query: String
    let expected: [Int]
    let prohibited: [Int]
    let asOfDay: Int?
    let allowed: [Int]?
    let expectEmpty: Bool
    let heldOut: Bool
    let prohibitedConclusions: [String]

    func request(baseEpoch: Double) -> RetrievalRequest {
        .init(query: query, allowedDocumentIDs: allowed.map { Set($0.map { evidenceID($0 + 10_000) }) },
              asOf: asOfDay.map { Date(timeIntervalSince1970: baseEpoch + Double($0) * 86_400) })
    }
}
private struct EvidenceResult: Codable {
    let id: String
    let category: String
    let heldOut: Bool
    let expectedSourceKeys: [Int]
    let returnedSourceKeys: [Int]
    let validSourceReferences: Bool
    let prohibitedSourcesAbsent: Bool
    let expectedEmptyEvidence: Bool
    let emptyEvidence: Bool
    let elapsedMilliseconds: Double
}
private struct EvidenceMetric: Codable {
    let samples: Int
    let p50Milliseconds: Double
    let p95Milliseconds: Double
    let maximumMilliseconds: Double
    init(_ values: [Double]) {
        let sorted = values.sorted()
        samples = sorted.count
        func percentile(_ fraction: Double) -> Double {
            sorted.isEmpty ? 0 : sorted[max(0, Int(ceil(Double(sorted.count) * fraction)) - 1)]
        }
        p50Milliseconds = percentile(0.50); p95Milliseconds = percentile(0.95)
        maximumMilliseconds = sorted.last ?? 0
    }
}
private struct VectorEvidence: Codable {
    var status: String
    var reason: String?
    var language: String?
    var modelRevision: Int?
    var dimension: Int?
    var embeddedChunks: Int = 0
    var indexingMilliseconds: Double = 0
    var exactRecallAt8: Double?
    var hybridRecallAt8: Double?
    var exactLatency: EvidenceMetric?
    var hybridLatency: EvidenceMetric?
    var queryResults: [VectorQueryEvidence] = []
    var productionEnabled = false
}
private struct VectorQueryEvidence: Codable {
    let id: String
    let exactSourceKeys: [Int]
    let hybridSourceKeys: [Int]
}
private struct EvidenceReport: Codable {
    let schemaVersion: Int
    let measuredAt: Date
    let fixtureSHA256: String
    let sourceTreeSHA256: String
    let configuration: String
    let os: String
    let architecture: String
    let machineModel: String
    let cpu: String
    let logicalCPUCount: Int
    let physicalMemoryBytes: UInt64
    let swiftVersion: String
    let segments: Int
    let documentChunks: Int
    let documentChunkerVersion: Int
    let transcriptFixtureVersion: Int
    let transcriptFixtureScale: Int
    let processPeakRSSBytes: Int64
    let lexicalRecallAt8: Double
    let temporalRecallAt8: Double
    let validSourceReferenceRate: Double
    let filteredEmptyEvidenceRate: Double
    let retrievalLatency: EvidenceMetric
    let historyLatency: EvidenceMetric
    let vectorExperiment: VectorEvidence
    let results: [EvidenceResult]
    let limitations: [String]
}

private func evidenceID(_ number: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-4000-8000-%012llx", Int64(number)))!
}
private func evidenceKey(_ id: UUID) -> Int {
    Int(id.uuidString.suffix(12), radix: 16) ?? -1
}
private func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
private func systemString(_ name: String) -> String {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0, size < 4_096 else { return "unavailable" }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "unavailable" }
    return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

/// Small frozen-corpus checks run offline by default. Scale/vector measurements
/// require an explicit Release-only lane; they never call a provider or download.
@Suite(.serialized)
struct RetrievalEvidenceTests {
    private let frozenHash = "c5da243216ce654272af03c8f3fe0568f36c571d9b17a81943ac4abc88cfe6b2"

    private func corpus() throws -> (EvidenceCorpus, Data) {
        let url = try #require(Bundle.module.url(forResource: "v1", withExtension: "json", subdirectory: "Fixtures/RetrievalEvidence"))
        let data = try Data(contentsOf: url)
        #expect(sha256(data) == frozenHash, "Freeze is versioned; do not silently retune the holdout")
        return (try JSONDecoder().decode(EvidenceCorpus.self, from: data), data)
    }

    @Test func frozenCorpusCoversSourcesChronologyConsentDeletionAndAdversarialText() async throws {
        let (corpus, _) = try corpus()
        #expect(corpus.questions.count == 40)
        #expect(corpus.questions.filter { $0.category == "answerable" }.count == 20)
        #expect(corpus.questions.filter { $0.category == "temporal" }.count == 10)
        #expect(corpus.questions.filter { $0.category == "insufficientOrAdversarial" }.count == 10)
        #expect(corpus.questions.filter(\.heldOut).count == 10)
        #expect(corpus.questions.allSatisfy { !$0.prohibitedConclusions.isEmpty })
        let database = try MacapyDatabase.inMemory()
        try await seed(corpus, into: database, totalChunks: 33)
        let results = try await evaluate(corpus, memory: MemoryStore(database: database))
        #expect(results.allSatisfy { $0.validSourceReferences })
        #expect(results.allSatisfy { $0.prohibitedSourcesAbsent })
        #expect(results.filter(\.expectedEmptyEvidence).allSatisfy { $0.emptyEvidence })
        #expect(recall(results, category: "answerable") >= 0.9)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MACAPY_RUN_RETRIEVAL_EVIDENCE"] == "1",
                   "Opt in with scripts/measure-retrieval.sh; scale and embedding work are excluded from ordinary tests"))
    func releaseScaleAndFrozenRetrievalEvidence() async throws {
        #if DEBUG
        Issue.record("Scale evidence requires a Release test build")
        return
        #else
        let (corpus, bytes) = try corpus()
        #expect(SearchFixtureSeeder.scale() == 1, "The evidence lane has one fixed, bounded transcript scale")
        guard SearchFixtureSeeder.scale() == 1 else { return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("macapy-retrieval-evidence-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let history = try SearchFixtureSeeder.fixture()
        let databaseURL = root.appendingPathComponent("synthetic.sqlite")
        try FileManager.default.copyItem(at: history.url, to: databaseURL)
        let database = try MacapyDatabase.onDisk(at: databaseURL)
        try await seed(corpus, into: database, totalChunks: 10_000)
        let counts = try await database.dbWriter.read { db in
            (try Int.fetchOne(db, sql: "SELECT count(*) FROM segments") ?? 0,
             try Int.fetchOne(db, sql: "SELECT count(*) FROM document_chunks") ?? 0)
        }
        #expect(counts.0 >= 146_000 && counts.1 == 10_000)
        let memory = MemoryStore(database: database)
        _ = try await evaluate(corpus, memory: memory) // one declared warm-up, no tuning
        var allResults: [EvidenceResult] = []
        for _ in 0..<5 { allResults += try await evaluate(corpus, memory: memory) }
        let search = SearchStore(database: database)
        let historyQueries = [SearchFixtureSeeder.needleToken, SearchFixtureSeeder.commonToken,
                              SearchFixtureSeeder.titleNeedleToken, SearchFixtureSeeder.artifactNeedleToken]
        for query in historyQueries { _ = try await search.search(matching: query) }
        var historyTimes: [Double] = []
        for _ in 0..<25 {
            for query in historyQueries {
                let start = ContinuousClock.now
                _ = try await search.search(matching: query)
                historyTimes.append((ContinuousClock.now - start).seconds * 1_000)
            }
        }
        let vector = try await vectorExperiment(corpus, database: database, lexical: Array(allResults.prefix(40)))
        var usage = rusage()
        _ = getrusage(RUSAGE_SELF, &usage)
        let env = ProcessInfo.processInfo.environment
        let report = EvidenceReport(schemaVersion: 1, measuredAt: Date(), fixtureSHA256: sha256(bytes),
            sourceTreeSHA256: env["MACAPY_EVIDENCE_SOURCE_HASH"] ?? "unrecorded", configuration: "Release",
            os: ProcessInfo.processInfo.operatingSystemVersionString, architecture: systemString("hw.machine"),
            machineModel: systemString("hw.model"), cpu: systemString("machdep.cpu.brand_string"),
            logicalCPUCount: ProcessInfo.processInfo.processorCount, physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            swiftVersion: env["MACAPY_EVIDENCE_SWIFT_VERSION"] ?? "unrecorded", segments: counts.0, documentChunks: counts.1, documentChunkerVersion: 1,
            transcriptFixtureVersion: SearchFixtureSeeder.version, transcriptFixtureScale: 1,
            processPeakRSSBytes: Int64(usage.ru_maxrss), lexicalRecallAt8: recall(allResults, category: "answerable"),
            temporalRecallAt8: recall(allResults, category: "temporal"),
            validSourceReferenceRate: Double(allResults.filter(\.validSourceReferences).count) / Double(allResults.count),
            filteredEmptyEvidenceRate: Double(allResults.filter { $0.expectedEmptyEvidence && $0.emptyEvidence }.count) / Double(allResults.filter(\.expectedEmptyEvidence).count),
            retrievalLatency: EvidenceMetric(allResults.map(\.elapsedMilliseconds)), historyLatency: EvidenceMetric(historyTimes),
            vectorExperiment: vector, results: Array(allResults.prefix(40)), limitations: [
                "Original English synthetic corpus: 20 answerable, 10 temporal/conflicting, 10 insufficient/adversarial cases; 10 held out before first run. No real meeting data.",
                "Five warm retrieval repetitions (200 samples); four warm history queries repeated 25 times (100 samples). Initial application startup and cold I/O are not measured.",
                "RSS is the peak Release test process including fixture construction and optional embeddings; it is not active app memory, a capture workload, or a one/three-hour soak measurement.",
                "No generated answers or provider calls. Empty evidence and citation/source integrity are structural checks, not semantic answer correctness, model abstention, or resistance to prompt injection.",
                "The optional vector/RRF comparison is an offline experiment over the same eligible chunks. It does not enable production semantic retrieval. Failed, null, and unavailable results remain recorded.",
                "Ten thousand synthetic document chunks are generated in bounded batches. The transcript corpus uses SearchFixtureSeeder's fixed-seed vocabulary; results are not representative field telemetry."
            ])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        let output = try #require(env["MACAPY_RETRIEVAL_EVIDENCE_OUTPUT"])
        let outputURL = URL(fileURLWithPath: output)
        #expect(!FileManager.default.fileExists(atPath: outputURL.path), "Evidence is never silently overwritten")
        try encoder.encode(report).write(to: outputURL, options: .withoutOverwriting)
        print("[retrieval] wrote synthetic aggregate evidence; lexical recall@8=\(report.lexicalRecallAt8), p95=\(report.retrievalLatency.p95Milliseconds) ms, peak test RSS=\(report.processPeakRSSBytes) bytes, vector=\(vector.status)")
        #expect(report.lexicalRecallAt8 >= 0.9)
        #expect(report.validSourceReferenceRate == 1)
        #expect(report.filteredEmptyEvidenceRate == 1)
        #expect(report.retrievalLatency.p95Milliseconds < 1_000)
        #expect(report.historyLatency.p95Milliseconds < 1_000)
        #endif
    }

    private func seed(_ corpus: EvidenceCorpus, into database: MacapyDatabase, totalChunks: Int) async throws {
        let meetingID = evidenceID(900_000)
        try await database.dbWriter.write { db in
            try db.execute(sql: "INSERT INTO meetings(id,title,startedAt,endedAt,status,ephemeral) VALUES(?,?,?,?,'ended',0)",
                           arguments: [meetingID,"Synthetic evidence meeting",Date(timeIntervalSince1970: corpus.baseEpoch),Date(timeIntervalSince1970: corpus.baseEpoch + 60)])
            for source in corpus.sources {
                try Self.insertDocument(db, key: source.key, title: source.title, texts: [(source.key,source.text)],
                    at: Date(timeIntervalSince1970: corpus.baseEpoch + Double(source.day) * 86_400), allowed: source.state != "denied", meetingID: meetingID)
            }
        }
        // Exercise the product deletion API and its synchronized FTS cascade.
        let documents = DocumentStore(database: database)
        for source in corpus.sources where source.state == "deleted" { try await documents.remove(id: evidenceID(source.key + 10_000)) }
        let fillerCount = totalChunks - corpus.sources.filter { $0.state != "deleted" }.count
        guard fillerCount > 0 else { return }
        let words = ["appendix","catalog","inventory","reference","orange","violet","granite","copper","willow","meadow","harbor","tunnel","ribbon","bucket","shelf","packet"]
        // One short transaction per 100 chunks; no giant retained text corpus.
        for start in stride(from: 0, to: fillerCount, by: 100) {
            try Task.checkCancellation()
            let texts = (start..<min(start + 100, fillerCount)).map { index -> (Int,String) in
                var value = UInt64(index + 1) &* 2_654_435_761
                let tokens = (0..<20).map { _ -> String in
                    value = value &* 6_364_136_223_846_793_005 &+ 1
                    return words[Int((value >> 32) % UInt64(words.count))]
                }
                return (1_000 + index, "Synthetic appendix \(index): " + tokens.joined(separator: " "))
            }
            try await database.dbWriter.write { db in
                try Self.insertDocument(db, key: 100_000 + start, title: "Synthetic appendix \(start / 100)", texts: texts,
                    at: Date(timeIntervalSince1970: corpus.baseEpoch), allowed: true, meetingID: meetingID)
            }
        }
    }

    private static func insertDocument(_ db: Database, key: Int, title: String, texts: [(Int,String)], at: Date,
                                       allowed: Bool, meetingID: UUID) throws {
        let id = evidenceID(key + 10_000), snapshot = texts.map(\.1).joined(separator: "\n")
        try db.execute(sql: "INSERT INTO documents(id,name,mediaType,snapshotText,textHash,revision,chunkerVersion,createdAt,updatedAt,allowedForAI) VALUES(?,?,'text/plain',?,?,1,1,?,?,?)",
                       arguments: [id,title,snapshot,sha256(Data(snapshot.utf8)),at,at,allowed])
        try db.execute(sql: "INSERT INTO document_links(documentID,meetingID) VALUES(?,?)", arguments: [id,meetingID])
        var offset = 0
        let insert = try db.cachedStatement(sql: "INSERT INTO document_chunks(id,documentID,revision,ordinal,pageNumber,startCharacter,endCharacter,text) VALUES(?,?,1,?,NULL,?,?,?)")
        for (ordinal, item) in texts.enumerated() {
            try insert.execute(arguments: [evidenceID(item.0),id,ordinal,offset,offset + item.1.count,item.1])
            offset += item.1.count + 1
        }
    }

    private func evaluate(_ corpus: EvidenceCorpus, memory: MemoryStore) async throws -> [EvidenceResult] {
        var results: [EvidenceResult] = []
        for question in corpus.questions {
            let request = question.request(baseEpoch: corpus.baseEpoch)
            let start = ContinuousClock.now
            let bundle = try await memory.retrieve(request)
            let elapsed = (ContinuousClock.now - start).seconds * 1_000
            let valid = try await memory.validate(bundle, for: request)
            let keys = bundle.excerpts.flatMap(\.sources).map { evidenceKey($0.sourceID) }
            #expect(!bundle.containsOnlyValidCitations(["forged-source"]))
            results.append(.init(id: question.id, category: question.category, heldOut: question.heldOut,
                expectedSourceKeys: question.expected, returnedSourceKeys: keys, validSourceReferences: valid,
                prohibitedSourcesAbsent: Set(keys).isDisjoint(with: question.prohibited), expectedEmptyEvidence: question.expectEmpty,
                emptyEvidence: bundle.isEmpty, elapsedMilliseconds: elapsed))
        }
        return results
    }

    private func recall(_ results: [EvidenceResult], category: String) -> Double {
        let selected = results.filter { $0.category == category && !$0.expectedSourceKeys.isEmpty }
        let expected = selected.reduce(0) { $0 + $1.expectedSourceKeys.count }
        let found = selected.reduce(0) { $0 + Set($1.expectedSourceKeys).intersection($1.returnedSourceKeys).count }
        return expected > 0 ? Double(found) / Double(expected) : 0
    }

    private func vectorExperiment(_ corpus: EvidenceCorpus, database: MacapyDatabase, lexical: [EvidenceResult]) async throws -> VectorEvidence {
        let embedder = PlatformSentenceEmbedder(enabledForExperiment: true)
        let first: EmbeddingVector
        do { first = try await embedder.embed("Synthetic retrieval evaluation") }
        catch LocalEmbeddingError.unavailable { return .init(status: "disabled", reason: "Platform sentence embeddings are unavailable; no asset installation was requested.") }
        catch { return .init(status: "disabled", reason: "Local embedding probe failed; no download or provider fallback.") }
        var report = VectorEvidence(status: "incomplete", language: first.language, modelRevision: first.modelRevision, dimension: first.dimension)
        let start = ContinuousClock.now
        struct Candidate: Sendable { let id: UUID; let documentID: UUID; let updatedAt: Date; let vector: EmbeddingVector }
        var candidates: [Candidate] = []
        for offset in stride(from: 0, to: 10_000, by: 100) {
            let rows = try await database.dbWriter.read { db in
                try Row.fetchAll(db, sql: "SELECT c.id,c.documentID,c.text,d.updatedAt FROM document_chunks c JOIN documents d ON d.id=c.documentID WHERE d.allowedForAI=1 ORDER BY c.id LIMIT 100 OFFSET ?", arguments: [offset]).map {
                    ($0["id"] as UUID,$0["documentID"] as UUID,$0["text"] as String,$0["updatedAt"] as Date)
                }
            }
            for row in rows {
                guard (ContinuousClock.now - start).seconds < 120 else {
                    report.reason = "Indexing exceeded the fixed 120-second experiment budget; no partial quality claim."
                    report.embeddedChunks = candidates.count; report.indexingMilliseconds = (ContinuousClock.now - start).seconds * 1_000
                    return report
                }
                do { candidates.append(.init(id: row.0, documentID: row.1, updatedAt: row.3, vector: try await embedder.embed(row.2))) }
                catch { report.reason = "Local chunk embedding failed; comparison incomplete."; report.embeddedChunks = candidates.count; return report }
            }
        }
        report.embeddedChunks = candidates.count; report.indexingMilliseconds = (ContinuousClock.now - start).seconds * 1_000
        var exactTimes: [Double] = [], hybridTimes: [Double] = [], exactFound = 0, hybridFound = 0, expected = 0
        for question in corpus.questions {
            let request = question.request(baseEpoch: corpus.baseEpoch)
            // Apply the same source/time filters before ranking. Kept explicit
            // below instead of allowing vector ranking to bypass source access.
            let eligible = candidates.filter { candidate in
                request.allowedDocumentIDs?.contains(candidate.documentID) != false && request.asOf.map { candidate.updatedAt <= $0 } != false
            }
            let queryStart = ContinuousClock.now
            let queryVector = try await embedder.embed(question.query)
            let exact = try ExactVectorSearch.rank(query: queryVector, candidates: eligible.map { ($0.id,$0.vector) }).map { evidenceKey($0.0) }
            let exactTime = (ContinuousClock.now - queryStart).seconds * 1_000
            exactTimes.append(exactTime)
            let fusionStart = ContinuousClock.now
            let baseline = lexical.first { $0.id == question.id }!
            var scores: [Int: Double] = [:]
            for ranking in [baseline.returnedSourceKeys,exact] {
                for (index,key) in ranking.enumerated() { scores[key,default: 0] += 1 / Double(60 + index + 1) }
            }
            let hybrid = Array(scores.keys.sorted { scores[$0] == scores[$1] ? $0 < $1 : scores[$0]! > scores[$1]! }.prefix(8))
            hybridTimes.append(exactTime + baseline.elapsedMilliseconds + (ContinuousClock.now - fusionStart).seconds * 1_000)
            report.queryResults.append(.init(id: question.id, exactSourceKeys: exact, hybridSourceKeys: hybrid))
            if question.category == "answerable" {
                expected += question.expected.count
                exactFound += Set(exact).intersection(question.expected).count
                hybridFound += Set(hybrid).intersection(question.expected).count
            }
        }
        report.status = "measured-experiment-only"
        report.exactRecallAt8 = Double(exactFound) / Double(expected)
        report.hybridRecallAt8 = Double(hybridFound) / Double(expected)
        report.exactLatency = EvidenceMetric(exactTimes); report.hybridLatency = EvidenceMetric(hybridTimes)
        return report
    }
}
