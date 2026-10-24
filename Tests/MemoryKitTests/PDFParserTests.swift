import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing
@testable import MemoryKit

struct PDFParserTests {
    private func pdf(pages: [String]) throws -> Data {
        let output = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: output))
        var bounds = CGRect(x: 0, y: 0, width: 300, height: 300)
        let context = try #require(CGContext(consumer: consumer, mediaBox: &bounds, nil))
        for text in pages {
            context.beginPDFPage(nil)
            context.textPosition = CGPoint(x: 20, y: 250)
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 12, nil),
            ]
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)), context)
            context.endPDFPage()
        }
        context.closePDF()
        return output as Data
    }

    @Test func textPDFKeepsPageLocatorsAndEnforcesPageLimit() async throws {
        let data = try pdf(pages: ["Cedar release", "Friday delivery"])
        let parsed = try await LocalDocumentParser().parse(data: data, name: "plan.pdf", extension: "pdf")
        #expect(parsed.pages.map(\.number) == [1, 2])
        #expect(parsed.pages[0].text.contains("Cedar release"))
        #expect(parsed.pages[1].text.contains("Friday delivery"))
        #expect(try DocumentChunker.chunks(parsed).map(\.pageNumber) == [1, 2])
        var limits = DocumentLimits(); limits.maximumPages = 1
        await #expect(throws: DocumentParseError.tooManyPages) {
            try await LocalDocumentParser(limits: limits).parse(data: data, name: "plan.pdf", extension: "pdf")
        }
    }

    @Test func imageOnlyOrEmptyPDFHasActionableNoTextError() async throws {
        let data = try pdf(pages: [""])
        await #expect(throws: DocumentParseError.noExtractableText) {
            try await LocalDocumentParser().parse(data: data, name: "scan.pdf", extension: "pdf")
        }
    }

    @Test func encryptedPDFIsRejectedEvenBeforeTextExtraction() async throws {
        let document = try #require(PDFDocument(data: pdf(pages: ["Confidential synthetic fixture"])))
        let encrypted = try #require(document.dataRepresentation(options: [
            PDFDocumentWriteOption.ownerPasswordOption: "synthetic-owner",
            PDFDocumentWriteOption.userPasswordOption: "synthetic-reader",
        ]))
        await #expect(throws: DocumentParseError.encryptedPDF) {
            try await LocalDocumentParser().parse(data: encrypted, name: "locked.pdf", extension: "pdf")
        }
    }
}
