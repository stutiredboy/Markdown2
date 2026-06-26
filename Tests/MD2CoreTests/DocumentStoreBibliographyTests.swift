import Foundation
import Testing
@testable import MD2App
@testable import MD2Core

/// Verifies the document store assembles a render config from the document's
/// front matter and an associated `.bib`, resolving the bibliography against the
/// document directory (app-layer file IO) before handing parsed data to the
/// pure renderer.
@MainActor
struct DocumentStoreBibliographyTests {
    private func makeTempDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func loadsAutoDetectedReferencesBibForCitations() throws {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try "@book{smith, author={Jane Smith}, title={A Title}, year={2020}}"
            .write(to: directory.appendingPathComponent("references.bib"), atomically: true, encoding: .utf8)
        let documentURL = directory.appendingPathComponent("doc.md")
        try "As shown by [@smith], it holds.".write(to: documentURL, atomically: true, encoding: .utf8)

        let store = DocumentStore()
        store.open(documentURL)

        #expect(store.rendered.body.contains("(Smith, 2020)"))
        #expect(store.rendered.body.contains(#"<section class="bibliography">"#))
    }

    @Test func resolvesBibliographyFromFrontMatterField() throws {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try "@book{jones, author={John Jones}, title={Work}, year={2021}}"
            .write(to: directory.appendingPathComponent("my-refs.bib"), atomically: true, encoding: .utf8)
        let documentURL = directory.appendingPathComponent("doc.md")
        try """
        ---
        bibliography: my-refs.bib
        ---

        See [@jones].
        """.write(to: documentURL, atomically: true, encoding: .utf8)

        let store = DocumentStore()
        store.open(documentURL)

        #expect(store.rendered.body.contains("(Jones, 2021)"))
    }

    @Test func missingBibliographyDegradesToRawKey() throws {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let documentURL = directory.appendingPathComponent("doc.md")
        try "Citing [@nobody] here.".write(to: documentURL, atomically: true, encoding: .utf8)

        let store = DocumentStore()
        store.open(documentURL)

        #expect(store.rendered.body.contains("nobody"))
        #expect(!store.rendered.body.contains(#"<section class="bibliography">"#))
    }
}
