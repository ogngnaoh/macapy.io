import CryptoKit
import Foundation
import PDFKit

public struct DocumentLimits: Sendable {
    public var maximumBytes = 10 * 1_024 * 1_024
    public var maximumPages = 200
    public var maximumCharacters = 1_000_000
    public var maximumChunks = 10_000
    public init() {}
}

public enum DocumentParseError: Error, Equatable, Sendable {
    case unsupportedFormat, invalidEncoding, oversizedFile, tooManyPages, tooMuchText
    case corruptPDF, encryptedPDF, noExtractableText, notLocalFile
}

public struct ParsedDocument: Sendable, Equatable {
    public struct Page: Sendable, Equatable {
        public let number: Int?
        public let text: String
        public init(number: Int?, text: String) { self.number = number; self.text = text }
    }
    public let name: String
    public let mediaType: String
    public let pages: [Page]
    public let textHash: String
    public var text: String { pages.map(\.text).joined(separator: "\n\n") }
    public init(name: String, mediaType: String, pages: [Page]) {
        self.name = name; self.mediaType = mediaType; self.pages = pages
        textHash = SHA256.hash(data: Data(pages.map(\.text).joined(separator: "\n\n").utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}

/// One serial, local parser. It never opens document links or downloads assets.
/// No original-file bytes or filesystem bookmarks survive the returned value.
public actor LocalDocumentParser {
    private let limits: DocumentLimits
    public init(limits: DocumentLimits = .init()) { self.limits = limits }

    public func parse(url: URL) throws -> ParsedDocument {
        try Task.checkCancellation()
        guard url.isFileURL else { throw DocumentParseError.notLocalFile }
        let ext = url.pathExtension.lowercased()
        guard ["txt", "md", "markdown", "pdf"].contains(ext) else { throw DocumentParseError.unsupportedFormat }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limits.maximumBytes + 1) ?? Data()
        guard data.count <= limits.maximumBytes else { throw DocumentParseError.oversizedFile }
        return try parse(data: data, name: url.lastPathComponent, extension: ext)
    }

    public func parse(data: Data, name: String, extension ext: String) throws -> ParsedDocument {
        try Task.checkCancellation()
        guard data.count <= limits.maximumBytes else { throw DocumentParseError.oversizedFile }
        let ext = ext.lowercased()
        if ["txt", "md", "markdown"].contains(ext) {
            guard let text = String(data: data, encoding: .utf8), !text.contains("\0") else { throw DocumentParseError.invalidEncoding }
            let normalized = Self.normalize(text)
            guard normalized.count <= limits.maximumCharacters else { throw DocumentParseError.tooMuchText }
            guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DocumentParseError.noExtractableText }
            return ParsedDocument(name: String(name.prefix(255)), mediaType: ext == "txt" ? "text/plain" : "text/markdown",
                                  pages: [.init(number: nil, text: normalized)])
        }
        guard ext == "pdf" else { throw DocumentParseError.unsupportedFormat }
        guard let pdf = PDFDocument(data: data) else { throw DocumentParseError.corruptPDF }
        guard !pdf.isEncrypted else { throw DocumentParseError.encryptedPDF }
        guard pdf.pageCount <= limits.maximumPages else { throw DocumentParseError.tooManyPages }
        var pages: [ParsedDocument.Page] = [], count = 0
        for index in 0..<pdf.pageCount {
            try Task.checkCancellation()
            let text = Self.normalize(pdf.page(at: index)?.string ?? "")
            count += text.count + (index > 0 ? 2 : 0)
            guard count <= limits.maximumCharacters else { throw DocumentParseError.tooMuchText }
            pages.append(.init(number: index + 1, text: text))
        }
        guard pages.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw DocumentParseError.noExtractableText
        }
        return ParsedDocument(name: String(name.prefix(255)), mediaType: "application/pdf", pages: pages)
    }

    private static func normalize(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{FEFF}", with: "").precomposedStringWithCanonicalMapping
    }
}

public struct DocumentChunk: Sendable, Equatable {
    public let ordinal: Int
    public let pageNumber: Int?
    public let startCharacter: Int
    public let endCharacter: Int
    public let text: String
}

public enum DocumentChunker {
    public static let version = 1
    /// Character-safe, nonoverlapping windows keep locators exact and storage
    /// bounded. Whitespace boundary selection is intentionally deterministic.
    public static func chunks(_ document: ParsedDocument, maximumCharacters: Int = 1_000,
                              maximumChunks: Int = 10_000) throws -> [DocumentChunk] {
        let size = max(1, min(2_000, maximumCharacters))
        var chunks: [DocumentChunk] = []
        for page in document.pages {
            let characters = Array(page.text)
            var offset = 0
            while offset < characters.count {
                try Task.checkCancellation()
                guard chunks.count < maximumChunks else { throw MemoryStoreError.capacityExceeded }
                let upper = min(characters.count, offset + size)
                var end = upper
                if upper < characters.count, upper - offset > size / 2 {
                    let lower = offset + size / 2
                    if let split = (lower..<upper).last(where: { characters[$0].isWhitespace }) { end = split + 1 }
                }
                let text = String(characters[offset..<end])
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    chunks.append(.init(ordinal: chunks.count, pageNumber: page.number,
                                        startCharacter: offset, endCharacter: end, text: text))
                }
                offset = end
            }
        }
        return chunks
    }
}
