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

    @Test func discoveryChecksStandardDirectoriesThenAbsolutePathOnEachCall() throws {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let standard = directory.appendingPathComponent("standard")
        let custom = directory.appendingPathComponent("custom")
        let standardPandoc = standard.appendingPathComponent("pandoc")
        let customPandoc = custom.appendingPathComponent("pandoc")
        try manager.createDirectory(at: standard, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: directory) }
        try manager.createDirectory(at: custom, withIntermediateDirectories: false)
        let searchPath = ":relative-directory:\(custom.path)"

        #expect(PandocConverter.pandocURL(standardDirectories: [standard.path], searchPath: searchPath) == nil)
        try manager.createDirectory(at: standardPandoc, withIntermediateDirectories: false)
        try manager.createSymbolicLink(atPath: customPandoc.path, withDestinationPath: "/usr/bin/true")
        #expect(PandocConverter.pandocURL(standardDirectories: [standard.path], searchPath: searchPath) == customPandoc)

        try manager.removeItem(at: standardPandoc)
        try manager.createSymbolicLink(atPath: standardPandoc.path, withDestinationPath: "/usr/bin/true")
        #expect(PandocConverter.pandocURL(standardDirectories: [standard.path], searchPath: searchPath) == standardPandoc)
    }
}

/// Pure unit tests for the `--citeproc` / `--bibliography` / `--csl` argument
/// assembly (no binary required); only the filesystem is touched.
struct PandocCitationArgumentsTests {
    private func makeTempDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func noArgumentsWhenNoBibliography() {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let arguments = PandocConverter.citationArguments(markdown: "# Doc\n\nNo citations.", resourceDirectory: directory)
        #expect(arguments.isEmpty)
    }

    @Test func autoDetectedReferencesBibAddsCiteprocAndBibliography() throws {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try "@book{k, title={T}}".write(to: directory.appendingPathComponent("references.bib"), atomically: true, encoding: .utf8)

        let arguments = PandocConverter.citationArguments(markdown: "# Doc", resourceDirectory: directory)
        #expect(arguments.contains("--citeproc"))
        #expect(arguments.contains("--bibliography=references.bib"))
    }

    @Test func frontMatterBibliographyAddsCiteprocOnly() throws {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try "@book{k, title={T}}".write(to: directory.appendingPathComponent("refs.bib"), atomically: true, encoding: .utf8)

        let markdown = "---\nbibliography: refs.bib\n---\n\n# Doc"
        let arguments = PandocConverter.citationArguments(markdown: markdown, resourceDirectory: directory)
        #expect(arguments.contains("--citeproc"))
        // Pandoc resolves the front-matter field itself, so no explicit --bibliography.
        #expect(!arguments.contains(where: { $0.hasPrefix("--bibliography") }))
    }

    @Test func cslFieldIsForwardedWhenBibliographyPresent() throws {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try "@book{k, title={T}}".write(to: directory.appendingPathComponent("references.bib"), atomically: true, encoding: .utf8)

        let markdown = "---\ncsl: ieee.csl\n---\n\n# Doc"
        let arguments = PandocConverter.citationArguments(markdown: markdown, resourceDirectory: directory)
        #expect(arguments.contains("--csl=ieee.csl"))
    }
}

/// Exercises the real `PandocConverter` against an installed Pandoc binary. Each
/// test skips when Pandoc is not available, so CI without Pandoc stays green.
final class PandocConverterTests: XCTestCase {
    @MainActor
    func testRealConversionProducesValidDocxAndEpub() throws {
        let pandoc = try installedPandoc()
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        for format in [DocumentExportFormat.docx, .epub] {
            let destination = dir.appendingPathComponent("out.\(format.fileExtension)")
            try Data("replace me".utf8).write(to: destination)

            try runConversion(
                markdown: """
                    # Title

                    Hello **world** and a list:

                    - a
                    - b

                    | A | B | C |
                    |---|---|---|
                    | 1 | 2 | 3 |
                    | 4 | 5 | 6 |
                    """,
                format: format,
                resourceDirectory: nil,
                destination: destination,
                pandoc: pandoc
            ).get()
            let entries = zipEntries(of: destination)
            switch format {
            case .docx:
                let document = try zipXML("word/document.xml", at: destination)
                let rows = try document.nodes(forXPath: "//*[local-name()='tbl']/*[local-name()='tr']")
                XCTAssertEqual(rows.count, 3)
                for row in rows {
                    XCTAssertEqual(try row.nodes(forXPath: "./*[local-name()='tc']").count, 3)
                }
                try assertGridBorders(in: document, tableCount: 1)
            case .epub: XCTAssertTrue(entries.contains("mimetype") && entries.contains("META-INF/container.xml"))
            }
        }
    }

    @MainActor
    func testDocxGridPreservesTablePropertiesAndReplacesExistingBorders() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let padding = String(repeating: "x", count: 70_000)
        let fixture = """
            <s:document xmlns:s="\(wordNamespace)"><s:body>
              <!-- \(padding) -->
              <s:tbl>
                <s:tblPr>
                  <s:tblStyle s:val="TableNormal"/>
                  <s:tblInd s:w="0" s:type="dxa"/>
                  <s:tblBorders><s:bottom s:val="single"/></s:tblBorders>
                  <s:tblCellMar><s:left s:w="108" s:type="dxa"/></s:tblCellMar>
                </s:tblPr>
                <s:tblGrid/>
                <s:tr><s:tc>
                  <s:tcPr><s:tcBorders><s:bottom s:val="single"/></s:tcBorders></s:tcPr>
                  <s:tbl><s:tblGrid/><s:tr><s:tc><s:p/></s:tc></s:tr></s:tbl>
                  <s:p/>
                </s:tc></s:tr>
              </s:tbl>
            </s:body></s:document>
            """
        let footnotes = """
            <footnotes xmlns="\(wordNamespace)">
              <footnote><tbl><tblPr/><tblGrid/><tr><tc><p/></tc></tr></tbl></footnote>
            </footnotes>
            """
        try writeDocxFixture(in: dir, documentXML: fixture, footnotesXML: footnotes)
        let pandoc = try writePandocFixture(in: dir, conversion: zipFixtureOutput)
        let destination = dir.appendingPathComponent("out.docx")
        try runConversion(markdown: "# Doc", format: .docx, resourceDirectory: nil,
                          destination: destination, pandoc: pandoc).get()

        let document = try zipXML("word/document.xml", at: destination)
        try assertGridBorders(in: document, tableCount: 2)
        let properties = try document.nodes(forXPath: """
            //*[local-name()='body']/*[local-name()='tbl']/*[local-name()='tblPr']/*
            """)
        XCTAssertEqual(properties.compactMap(\.localName), ["tblStyle", "tblInd", "tblBorders", "tblCellMar"])
        let nestedChildren = try document.nodes(forXPath: "//*[local-name()='tc']/*[local-name()='tbl']/*")
        XCTAssertEqual(nestedChildren.compactMap(\.localName), ["tblPr", "tblGrid", "tr"])
        XCTAssertEqual(try document.nodes(forXPath: "//*[local-name()='tcBorders']/*[local-name()='bottom']").count, 1)
        try assertGridBorders(in: zipXML("word/footnotes.xml", at: destination), tableCount: 1)
    }

    @MainActor
    func testInvalidDocxDocumentPartPreservesExistingDestination() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeDocxFixture(in: dir, documentXML: "<not-a-document/>")
        let pandoc = try writePandocFixture(in: dir, conversion: zipFixtureOutput)
        let destination = dir.appendingPathComponent("out.docx")
        let sentinel = Data("existing-output-sentinel".utf8)
        try sentinel.write(to: destination)

        XCTAssertThrowsError(try runConversion(markdown: "# Doc", format: .docx, resourceDirectory: nil,
            destination: destination, pandoc: pandoc).get())
        XCTAssertEqual(try Data(contentsOf: destination), sentinel)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: dir.path).contains {
            $0.hasPrefix(".md2-converted-")
        })
    }

    @MainActor
    func testRealConversionEmbedsRelativeImage() throws {
        let pandoc = try installedPandoc()
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sourceDirectory = dir.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: false)
        try writePNG(named: "pic.png", into: sourceDirectory)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: sourceDirectory.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sourceDirectory.path)
        }

        let destination = dir.appendingPathComponent("img.docx")
        let result = runConversion(
            markdown: "# Doc\n\n![pic](pic.png)\n",
            format: .docx,
            resourceDirectory: sourceDirectory,
            destination: destination,
            pandoc: pandoc
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
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: sourceDirectory.path), ["pic.png"])
        try assertRealPandocRemoteBoundary(in: dir, pandoc: pandoc)
    }

    @MainActor
    func testRealConversionDeletesPartialOutputOnFailure() throws {
        let pandoc = try installedPandoc()
        // Root bypasses permission checks, so the read-only barrier below cannot
        // make the destination unwritable; skip rather than fail confusingly.
        try XCTSkipIf(geteuid() == 0, "Permission-based failure requires a non-root runner.")
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // A destination inside a read-only directory makes Pandoc fail to write.
        // A missing parent directory no longer works as the failure mechanism:
        // pandoc 3.11 creates missing parent directories for `--output`, so only
        // a permission barrier holds on every pandoc version.
        let locked = dir.appendingPathComponent("locked-subdir", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        // Restore permissions before the outer cleanup (defers run LIFO) so the
        // temp directory can always be removed.
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        }
        let destination = locked.appendingPathComponent("out.docx")

        let result = runConversion(
            markdown: "# Doc\n",
            format: .docx,
            resourceDirectory: dir,
            destination: destination,
            pandoc: pandoc
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

    func testVersionProbeTracksNewVersionAtSamePath() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pandoc = try writePandocFixture(in: dir, version: "1.13", conversion: "exit 100")
        XCTAssertEqual(try PandocConverter.readerFormat(for: pandoc).get(), "markdown_github")
        _ = try writePandocFixture(in: dir, version: "3.14", conversion: "exit 100")
        XCTAssertEqual(try PandocConverter.readerFormat(for: pandoc).get(), "gfm")
    }

    @MainActor
    func testVersionProbeFailurePreventsConversion() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pandoc = try writePandocFixture(in: dir, versionFailure: true, conversion: "/usr/bin/touch ran")
        let destination = dir.appendingPathComponent("out.docx")
        XCTAssertThrowsError(try runConversion(markdown: "# Doc", format: .docx, resourceDirectory: dir,
            destination: destination, pandoc: pandoc).get())
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("ran").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    @MainActor
    func testPartialOrInvalidOutputPreservesExistingDestination() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let existing = dir.appendingPathComponent("existing.docx")
        let sentinel = Data("existing-output-sentinel".utf8)
        try sentinel.write(to: existing)
        for status in [1, 0] {
            let pandoc = try writePandocFixture(in: dir, conversion: """
                printf '\\120\\113\\003\\004truncated' > "$5"
                exit \(status)
                """)
            XCTAssertThrowsError(try runConversion(markdown: "# Doc", format: .docx, resourceDirectory: dir,
                destination: existing, pandoc: pandoc).get())
            XCTAssertEqual(try Data(contentsOf: existing), sentinel)
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: dir.path).contains {
                $0.hasPrefix(".md2-converted-")
            })
        }
    }

    @MainActor
    func testCancellationPreservesExistingDestination() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let existing = dir.appendingPathComponent("existing.docx")
        let sentinel = Data("existing-output-sentinel".utf8)
        try sentinel.write(to: existing)
        let started = dir.appendingPathComponent("started")
        try writeDocxFixture(in: dir)
        let pandoc = try writePandocFixture(in: dir, conversion: """
            \(zipFixtureOutput) || exit
            /usr/bin/touch started
            exec /bin/sleep 10
            """)
        let converter = PandocConverter(locatePandoc: { pandoc })
        var completions = 0
        converter.convert(markdown: "# Canceled", format: .docx, resourceDirectory: dir, destination: existing) { outcome in
            completions += 1
            guard case .failure(PandocConverter.ConversionError.canceled) = outcome else {
                return XCTFail("unexpected result: \(outcome)")
            }
        }
        defer { converter.cancel() }
        try await waitUntil { FileManager.default.fileExists(atPath: started.path) }
        converter.cancel()
        converter.cancel()
        XCTAssertEqual(completions, 1)
        try await waitUntil {
            try !FileManager.default.contentsOfDirectory(atPath: dir.path).contains {
                $0.hasPrefix(".md2-converted-")
            }
        }
        XCTAssertEqual(try Data(contentsOf: existing), sentinel)
    }

    @MainActor
    func testConcurrentDestinationCreationOrUpdateIsPreserved() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeDocxFixture(in: dir)
        let pandoc = try writePandocFixture(in: dir, conversion: zipFixtureOutput)
        let changed = Data("changed after export started".utf8)
        for previouslyExisted in [true, false] {
            let destination = dir.appendingPathComponent("existing-\(previouslyExisted).docx")
            if previouslyExisted { try Data("original".utf8).write(to: destination) }
            let converter = PandocConverter(locatePandoc: { pandoc })
            let done = expectation(description: "conversion finalizes")
            converter.convert(markdown: "# Doc", format: .docx, resourceDirectory: nil, destination: destination) { result in
                defer { done.fulfill() }
                guard case .failure(PandocConverter.ConversionError.destinationChanged) = result else {
                    return XCTFail("unexpected result: \(result)")
                }
            }
            // The worker stages off the main actor, and final publication is
            // checked on the main actor after this competing write.
            try changed.write(to: destination)
            wait(for: [done], timeout: 10)
            XCTAssertEqual(try Data(contentsOf: destination), changed)
        }
    }

    // MARK: - Helpers

    @MainActor
    private func assertRealPandocRemoteBoundary(in directory: URL, pandoc: URL) throws {
        let server = try ExportNetworkTestServer()
        defer { server.stop() }
        let reader = try PandocConverter.readerFormat(for: pandoc).get()
        for format in [DocumentExportFormat.docx, .epub] {
            let token = UUID().uuidString
            let source = directory.appendingPathComponent("remote-\(token).md")
            let markdown = "# Remote boundary\n\n![pixel](\(server.baseURL)/\(token).png)\n"
            try markdown.write(to: source, atomically: true, encoding: .utf8)
            let direct = Process()
            direct.executableURL = pandoc
            direct.currentDirectoryURL = directory
            direct.arguments = [source.lastPathComponent, "--from", reader,
                "-o", directory.appendingPathComponent("control-\(token).\(format.fileExtension)").path]
            direct.standardOutput = FileHandle.nullDevice
            direct.standardError = FileHandle.nullDevice
            try direct.run(); direct.waitUntilExit()
            XCTAssertEqual(direct.terminationStatus, 0)
            XCTAssertGreaterThan(server.requests.filter { $0.path.contains(token) }.count, 0,
                                 "the real \(format) positive control did not fetch its image")
            let blockedToken = UUID().uuidString
            let blocked = markdown.replacingOccurrences(of: token, with: blockedToken)
            _ = runConversion(markdown: blocked, format: format, resourceDirectory: directory,
                destination: directory.appendingPathComponent("blocked-\(blockedToken).\(format.fileExtension)"),
                pandoc: pandoc)
            XCTAssertFalse(server.requests.contains { $0.path.contains(blockedToken) },
                           "the real converter fetched a remote image")
        }
    }

    @MainActor
    private func runConversion(
        markdown: String,
        format: DocumentExportFormat,
        resourceDirectory: URL?,
        destination: URL,
        pandoc: URL
    ) -> Result<Void, Error> {
        let converter = PandocConverter(locatePandoc: { pandoc })
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

    private func installedPandoc() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["MD2_TEST_PANDOC_PATH"] {
            let url = URL(fileURLWithPath: override)
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: url.path), "test Pandoc should be executable")
            return url
        }
        let url = PandocConverter.pandocURL()
        try XCTSkipIf(url == nil, "Pandoc not installed.")
        return try XCTUnwrap(url)
    }

    private var zipFixtureOutput: String {
        #"/bin/cp "$(/usr/bin/dirname "$0")/fixture.docx" "$5""#
    }

    private var wordNamespace: String {
        "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
    }

    private func writeDocxFixture(in directory: URL, documentXML: String? = nil, footnotesXML: String? = nil) throws {
        let wordDirectory = directory.appendingPathComponent("word")
        try FileManager.default.createDirectory(at: wordDirectory, withIntermediateDirectories: false)
        let xml = documentXML ?? #"<w:document xmlns:w="\#(wordNamespace)"><w:body/></w:document>"#
        try xml.write(to: wordDirectory.appendingPathComponent("document.xml"), atomically: true, encoding: .utf8)
        var entries = ["word/document.xml"]
        if let footnotesXML {
            try footnotesXML.write(to: wordDirectory.appendingPathComponent("footnotes.xml"),
                                   atomically: true, encoding: .utf8)
            entries.append("word/footnotes.xml")
        }
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.arguments = ["-q", "fixture.docx"] + entries
        zip.currentDirectoryURL = directory
        try zip.run()
        zip.waitUntilExit()
        XCTAssertEqual(zip.terminationStatus, 0)
    }

    private func zipXML(_ path: String, at url: URL) throws -> XMLDocument {
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-p", url.path, path]
        let output = Pipe()
        unzip.standardOutput = output
        try unzip.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        unzip.waitUntilExit()
        XCTAssertEqual(unzip.terminationStatus, 0)
        return try XMLDocument(data: data)
    }

    private func assertGridBorders(in document: XMLDocument, tableCount: Int) throws {
        let tables = try document.nodes(forXPath: "//*[local-name()='tbl']")
        XCTAssertEqual(tables.count, tableCount)
        for table in tables {
            let grids = try table.nodes(forXPath: "./*[local-name()='tblPr']/*[local-name()='tblBorders']")
            XCTAssertEqual(grids.count, 1)
            let grid = try XCTUnwrap(grids.first)
            let edges = try XCTUnwrap(grid.children as? [XMLElement])
            XCTAssertEqual(edges.compactMap(\.localName), ["top", "left", "bottom", "right", "insideH", "insideV"])
            for edge in edges {
                XCTAssertEqual(edge.uri, wordNamespace)
                XCTAssertEqual(edge.attribute(forLocalName: "val", uri: wordNamespace)?.stringValue, "single")
                XCTAssertEqual(edge.attribute(forLocalName: "sz", uri: wordNamespace)?.stringValue, "4")
                XCTAssertEqual(edge.attribute(forLocalName: "space", uri: wordNamespace)?.stringValue, "0")
                XCTAssertEqual(edge.attribute(forLocalName: "color", uri: wordNamespace)?.stringValue, "auto")
            }
        }
    }

    @MainActor
    private func waitUntil(_ condition: () throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while try !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(try condition(), "Timed out waiting for the fake converter.")
    }

    private func writePandocFixture(
        in dir: URL, version: String = "3.14", versionFailure: Bool = false, conversion: String
    ) throws -> URL {
        let url = dir.appendingPathComponent("fixture-pandoc")
        let probe = versionFailure ? "exit 23" : "printf 'pandoc \(version)\\n'; exit"
        try """
            #!/bin/sh
            if [ "$1" = "--version" ]; then
                \(probe)
            fi
            \(conversion)
            """.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
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
