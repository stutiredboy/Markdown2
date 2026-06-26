import Foundation
import Testing
import XCTest
@testable import MD2App

/// Pure unit tests for the Pandoc reader-format selection (no binary required).
struct PandocReaderFormatTests {
    @Test func parsesMajorVersionFromVersionOutput() {
        #expect(PandocConverter.parseMajorVersion(fromVersionOutput: "pandoc 3.1.9\nCompiled with…") == 3)
        #expect(PandocConverter.parseMajorVersion(fromVersionOutput: "pandoc 2.0\n") == 2)
        #expect(PandocConverter.parseMajorVersion(fromVersionOutput: "pandoc 1.13.2\n") == 1)
    }

    @Test func returnsNilForUnparseableVersionOutput() {
        #expect(PandocConverter.parseMajorVersion(fromVersionOutput: "") == nil)
        #expect(PandocConverter.parseMajorVersion(fromVersionOutput: "garbage with no version") == nil)
        #expect(PandocConverter.parseMajorVersion(fromVersionOutput: "pandoc x.y") == nil)
    }

    @Test func mapsMajorVersionToReaderFormat() {
        // Pandoc 2.0+ uses the canonical `gfm`; older builds use the alias.
        #expect(PandocConverter.reader(forMajorVersion: 3) == "gfm")
        #expect(PandocConverter.reader(forMajorVersion: 2) == "gfm")
        #expect(PandocConverter.reader(forMajorVersion: 1) == "markdown_github")
        // Unknown version falls back to the compatible alias so it never breaks.
        #expect(PandocConverter.reader(forMajorVersion: nil) == "markdown_github")
    }
}

/// Exercises the real `PandocConverter` against an installed Pandoc binary. Each
/// test skips when Pandoc is not available, so CI without Pandoc stays green.
final class PandocConverterTests: XCTestCase {
    @MainActor
    func testRealConversionProducesValidDocx() throws {
        try XCTSkipUnless(PandocConverter.isAvailable(), "Pandoc not installed.")
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let destination = dir.appendingPathComponent("out.docx")

        let result = runConversion(
            markdown: "# Title\n\nHello **world** and a list:\n\n- a\n- b\n",
            format: .docx,
            resourceDirectory: dir,
            destination: destination
        )

        guard case .success = result else {
            XCTFail("conversion failed: \(result)")
            return
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        let data = try Data(contentsOf: destination)
        XCTAssertGreaterThan(data.count, 0)
        // DOCX is a Zip container: it begins with the "PK" local-file signature.
        XCTAssertEqual(Array(data.prefix(2)), [0x50, 0x4B], "DOCX is not a valid zip")
    }

    @MainActor
    func testRealConversionEmbedsRelativeImage() throws {
        try XCTSkipUnless(PandocConverter.isAvailable(), "Pandoc not installed.")
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writePNG(named: "pic.png", into: dir)
        let destination = dir.appendingPathComponent("img.docx")

        let result = runConversion(
            markdown: "# Doc\n\n![pic](pic.png)\n",
            format: .docx,
            resourceDirectory: dir,
            destination: destination
        )

        guard case .success = result else {
            XCTFail("conversion failed: \(result)")
            return
        }
        let entries = zipEntries(of: destination)
        XCTAssertTrue(
            entries.contains { $0.contains("media/") },
            "relative image was not embedded; entries: \(entries)"
        )
    }

    @MainActor
    func testRealConversionDeletesPartialOutputOnFailure() throws {
        try XCTSkipUnless(PandocConverter.isAvailable(), "Pandoc not installed.")
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // A destination inside a non-existent directory makes Pandoc fail to write.
        let destination = dir
            .appendingPathComponent("missing-subdir", isDirectory: true)
            .appendingPathComponent("out.docx")

        let result = runConversion(
            markdown: "# Doc\n",
            format: .docx,
            resourceDirectory: dir,
            destination: destination
        )

        guard case .failure = result else {
            XCTFail("expected a failure for an unwritable destination")
            return
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: destination.path),
            "a partial/failed output file must not survive"
        )
    }

    // MARK: - Helpers

    @MainActor
    private func runConversion(
        markdown: String,
        format: DocumentExportFormat,
        resourceDirectory: URL,
        destination: URL
    ) -> Result<Void, Error> {
        let converter = PandocConverter()
        let done = expectation(description: "conversion completes")
        var outcome: Result<Void, Error> = .failure(PandocConverter.ConversionError.preparationFailed)
        converter.convert(
            markdown: markdown,
            format: format,
            resourceDirectory: resourceDirectory,
            destination: destination
        ) { result in
            outcome = result
            done.fulfill()
        }
        // Longer than the converter's internal 60s watchdog so a timeout still
        // resolves the completion before the test wait elapses.
        wait(for: [done], timeout: 75)
        return outcome
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("md2-pandoc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writePNG(named name: String, into dir: URL) throws {
        let base64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
        try Data(base64Encoded: base64)!.write(to: dir.appendingPathComponent(name))
    }

    /// Lists the entry names in a Zip archive via the system `unzip` tool.
    private func zipEntries(of url: URL) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-Z1", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        return text.split(separator: "\n").map(String.init)
    }
}
