import Foundation
import Testing
@testable import MD2Core

/// End-to-end check that the bundled `Examples/Sample.md` exercises the
/// technical/academic features against its `Examples/references.bib`, the way the
/// app's document store assembles a render config from front matter and the
/// associated bibliography file.
struct SampleDocumentTests {
    private func examplesDirectory() -> URL {
        URL(fileURLWithPath: #filePath)        // …/Tests/MD2CoreTests/SampleDocumentTests.swift
            .deletingLastPathComponent()        // …/Tests/MD2CoreTests
            .deletingLastPathComponent()        // …/Tests
            .deletingLastPathComponent()        // repo root
            .appendingPathComponent("Examples")
    }

    @Test func sampleRendersCitationsCrossReferencesAndMacros() throws {
        let directory = examplesDirectory()
        let markdown = try String(contentsOf: directory.appendingPathComponent("Sample.md"), encoding: .utf8)
        let bibSource = try String(contentsOf: directory.appendingPathComponent("references.bib"), encoding: .utf8)

        let fields = FrontMatterReader.fields(in: markdown)
        #expect(fields["bibliography"] == "references.bib")

        let config = RenderConfig(
            bibliography: BibTeXParser.parse(bibSource),
            mathMacros: FrontMatterReader.parseMathMacros(fields["math-macros"])
        )
        let document = MarkdownRenderer().render(markdown, config: config)
        let body = document.body.withoutSourceLineMetadata

        // Citations render and a bibliography section is emitted.
        #expect(body.contains(#"<span class="citation">"#))
        #expect(body.contains(#"<section class="bibliography">"#))
        #expect(body.contains("Shannon"))

        // Cross-references resolve, and the labeled figure/table/equation render.
        #expect(body.contains(#"class="cross-ref""#))
        #expect(body.contains("Figure 1:"))
        #expect(body.contains("Table 1:"))
        #expect(body.contains("eq-number"))

        // Front matter stays visible, but it must not leak into the document outline
        // or generated TOC as a fake setext heading.
        #expect(!document.outline.contains { $0.title.contains("math-macros") })
        #expect(!body.contains(##"href="#math-macros"##))

        // The front-matter macro reaches the KaTeX configuration.
        #expect(config.mathMacros["\\RR"] == "\\mathbb{R}")
        #expect(!document.html.contains("window.__md2InitialMacros = {};"))
    }
}
