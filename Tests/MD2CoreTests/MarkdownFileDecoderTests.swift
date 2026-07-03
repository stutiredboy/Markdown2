import Foundation
import Testing
@testable import MD2App

struct MarkdownFileDecoderTests {
    @Test func plainUTF8DecodesWithoutFallback() {
        let data = Data("# 标题\n\nBody text.\n".utf8)
        let decoded = MarkdownFileDecoder.decode(data)
        #expect(decoded == MarkdownFileDecoder.DecodedFile(text: "# 标题\n\nBody text.\n", usedFallbackEncoding: false))
    }

    @Test func emptyFileDecodesAsEmptyUTF8() {
        let decoded = MarkdownFileDecoder.decode(Data())
        #expect(decoded == MarkdownFileDecoder.DecodedFile(text: "", usedFallbackEncoding: false))
    }

    @Test func utf8ByteOrderMarkIsStrippedAndMarkedFallback() {
        let data = Data([0xEF, 0xBB, 0xBF]) + Data("# Doc\n".utf8)
        let decoded = MarkdownFileDecoder.decode(data)
        #expect(decoded == MarkdownFileDecoder.DecodedFile(text: "# Doc\n", usedFallbackEncoding: true))
    }

    @Test func utf16LittleEndianWithBOMDecodes() throws {
        let body = try #require("你好 World\n".data(using: .utf16LittleEndian))
        let decoded = MarkdownFileDecoder.decode(Data([0xFF, 0xFE]) + body)
        #expect(decoded == MarkdownFileDecoder.DecodedFile(text: "你好 World\n", usedFallbackEncoding: true))
    }

    @Test func utf16BigEndianWithBOMDecodes() throws {
        let body = try #require("# Heading\n".data(using: .utf16BigEndian))
        let decoded = MarkdownFileDecoder.decode(Data([0xFE, 0xFF]) + body)
        #expect(decoded == MarkdownFileDecoder.DecodedFile(text: "# Heading\n", usedFallbackEncoding: true))
    }

    @Test func utf32LittleEndianBOMWinsOverUTF16Prefix() throws {
        // The UTF-32LE BOM begins with the UTF-16LE mark; order matters.
        let body = try #require("A\n".data(using: .utf32LittleEndian))
        let decoded = MarkdownFileDecoder.decode(Data([0xFF, 0xFE, 0x00, 0x00]) + body)
        #expect(decoded == MarkdownFileDecoder.DecodedFile(text: "A\n", usedFallbackEncoding: true))
    }

    @Test func gb18030ChineseTextDecodes() throws {
        let source = "# 月度报告\n\n中文正文，包含标点。\n"
        let data = try #require(source.data(using: MarkdownFileDecoder.gb18030))
        // Sanity: the fixture is not valid UTF-8, so it exercises the fallback.
        #expect(String(data: data, encoding: .utf8) == nil)
        let decoded = MarkdownFileDecoder.decode(data)
        #expect(decoded == MarkdownFileDecoder.DecodedFile(text: source, usedFallbackEncoding: true))
    }

    @Test func binaryDataIsRejected() {
        // PNG-style header: invalid UTF-8, and its control bytes fail the
        // GB18030 plausibility gate.
        let data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D])
        #expect(MarkdownFileDecoder.decode(data) == nil)
    }
}

@MainActor
struct DocumentAlertLocalizationTests {
    @Test func parameterizedAlertStringsFormatInBothLanguages() {
        let keys: [L10nKey] = [
            .alertCouldNotOpen, .alertUndecodableFile, .alertCouldNotSave,
            .alertCouldNotExport, .alertPandocRequired
        ]
        for key in keys {
            for language in [AppLanguage.english, .zhHans] {
                let formatted = String(format: L10n.text(key, language: language), "Note.md")
                #expect(formatted.contains("Note.md"), "\(key) in \(language) should embed the file name")
                #expect(!formatted.contains("%@"), "\(key) in \(language) should consume its placeholder")
            }
        }
    }

    @Test func undecodableFileAlertUsesInjectedProvider() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("md2-alert-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("binary.md")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01]).write(to: url)

        let store = DocumentStore(alertTextProvider: { key in "[\(key.rawValue)] %@" })
        store.open(url)
        #expect(store.alert?.message == "[alertUndecodableFile] binary.md")
    }

    @Test func pandocGuidanceUsesInjectedProvider() {
        let store = DocumentStore(
            pandocAvailabilityProvider: { false },
            alertTextProvider: { key in "<\(key.rawValue)>" }
        )
        store.exportDOCX()
        #expect(store.alert?.message == "<alertPandocRequired>")
        #expect(store.alert?.detail == "<alertPandocRequiredDetail>")
    }

    @Test func gb18030FileOpensAndSavesAsUTF8() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("md2-gb-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("legacy.md")
        let source = "# 旧笔记\n\n遗留编码内容。\n"
        try #require(source.data(using: MarkdownFileDecoder.gb18030)).write(to: url)

        let store = DocumentStore()
        store.open(url)
        #expect(store.alert == nil)
        #expect(store.text == source)

        // The next save normalizes the file to UTF-8 with the same text.
        #expect(store.save())
        let savedData = try Data(contentsOf: url)
        #expect(savedData == Data(source.utf8))
    }
}
