import Testing
@testable import MD2Core

/// Task 7.1 / `markdown-conformance-suite`: across the whole corpus, every
/// top-level content block carries `data-md2-source-line`, and every task-list
/// checkbox carries `data-md2-task-line`. This guards mode-switch scroll
/// anchoring and preview task toggling for any document a user might import.
struct MetadataInvariantTests {
    /// Structural wrappers whose source-line metadata lives on their children
    /// rather than the wrapper element itself (task 7.2 — a narrow, justified
    /// exception list). The footnotes section carries metadata on each `<li>`;
    /// the bibliography is a trailing generated section (entries come from a
    /// `.bib` file, not document lines) and is exempt like the footnotes section.
    private let wrapperExceptions = [
        #"<section class="footnotes""#,
        #"<section class="bibliography""#
    ]

    @Test func everyTopLevelBlockInTheCorpusCarriesSourceLine() throws {
        let renderer = MarkdownRenderer()
        var offenders: [String] = []

        for entry in try ConformanceCorpus.load() {
            let body = renderer.render(entry.example.markdown).body
            for tag in topLevelOpeningTags(in: body) {
                // The invariant covers content *blocks*; inline fragments the
                // renderer may emit at top level for unsupported raw-HTML input
                // (e.g. a stray `</div>` that unbalances nesting) are not blocks.
                guard isBlockLevel(tag) else { continue }
                if tag.contains("data-md2-source-line=") { continue }
                if wrapperExceptions.contains(where: { tag.hasPrefix($0) }) { continue }
                offenders.append("\(entry.id): \(tag.prefix(80))")
            }
        }

        let report = offenders.prefix(20).joined(separator: "\n")
        #expect(offenders.isEmpty, "top-level blocks missing data-md2-source-line:\n\(report)")
    }

    @Test func everyTaskCheckboxInTheCorpusCarriesTaskLine() throws {
        let renderer = MarkdownRenderer()
        var offenders: [String] = []

        for entry in try ConformanceCorpus.load() {
            let body = renderer.render(entry.example.markdown).body
            for tag in allOpeningTags(in: body) where tag.hasPrefix("<input") {
                if !tag.contains("data-md2-task-line=") {
                    offenders.append("\(entry.id): \(tag)")
                }
            }
        }

        let report = offenders.prefix(20).joined(separator: "\n")
        #expect(offenders.isEmpty, "task checkboxes missing data-md2-task-line:\n\(report)")
    }

    /// Task 14.9: figure and captioned-table blocks are emitted through the normal
    /// block walk, so they carry `data-md2-source-line` like any other content
    /// block; the trailing bibliography section is exempt (its entries come from a
    /// `.bib`, not document lines), mirroring the footnotes section.
    @Test func figureAndCaptionedTableBlocksCarrySourceLine() {
        let markdown = """
        ![A diagram](d.png){#fig:d}

        | A | B |
        | --- | --- |
        | 1 | 2 |
        : Caption {#tbl:t}
        """
        let body = MarkdownRenderer().render(markdown).body

        for tag in topLevelOpeningTags(in: body) where tag.hasPrefix("<figure") || tag.hasPrefix("<table") {
            #expect(tag.contains("data-md2-source-line="), "missing source line: \(tag)")
        }
        // Both block types are present in the output.
        #expect(body.contains("<figure"))
        #expect(body.contains("<table"))
    }

    @Test func bibliographySectionIsExemptLikeFootnotes() {
        let bib = BibTeXParser.parse("@book{k, author = {A Author}, title = {T}, year = {2020} }")
        let config = RenderConfig(bibliography: bib)
        let body = MarkdownRenderer().render("Cite [@k].", config: config).body

        // The bibliography is a trailing generated section with no source line.
        #expect(body.contains(#"<section class="bibliography">"#))
        for tag in topLevelOpeningTags(in: body) where tag.hasPrefix(#"<section class="bibliography""#) {
            #expect(!tag.contains("data-md2-source-line="))
        }
    }

    /// Opening tags of depth-0 (top-level) elements, in document order. Void
    /// elements do not open a nesting level; closing tags pop one.
    private func topLevelOpeningTags(in html: String) -> [String] {
        scanTags(in: html).filter { $0.depth == 0 && !$0.isClosing }.map(\.tag)
    }

    private func allOpeningTags(in html: String) -> [String] {
        scanTags(in: html).filter { !$0.isClosing }.map(\.tag)
    }

    private struct ScannedTag { let tag: String; let depth: Int; let isClosing: Bool }

    private static let voidElements: Set<String> = [
        "hr", "br", "img", "input", "wbr", "col", "area", "base", "link", "meta", "source"
    ]

    /// Block-level elements the renderer constructs as top-level content blocks.
    private static let blockLevelElements: Set<String> = [
        "p", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "blockquote",
        "pre", "hr", "table", "div", "section", "dl", "figure"
    ]

    private func isBlockLevel(_ tag: String) -> Bool {
        let name = tag.drop { $0 == "<" }.prefix { $0.isLetter || $0.isNumber }.lowercased()
        return Self.blockLevelElements.contains(String(name))
    }

    private func scanTags(in html: String) -> [ScannedTag] {
        var result: [ScannedTag] = []
        var depth = 0
        var index = html.startIndex

        while let open = html[index...].firstIndex(of: "<") {
            guard let close = html[open...].firstIndex(of: ">") else { break }
            let inner = html[html.index(after: open)..<close]
            index = html.index(after: close)

            // Skip comments / doctype / processing instructions.
            if inner.first == "!" || inner.first == "?" { continue }

            let isClosing = inner.first == "/"
            let namePart = isClosing ? inner.dropFirst() : inner
            let name = namePart.prefix { $0.isLetter || $0.isNumber }.lowercased()
            guard !name.isEmpty else { continue }

            let tagText = "<\(inner)>"
            if isClosing {
                depth = max(0, depth - 1)
                result.append(ScannedTag(tag: tagText, depth: depth, isClosing: true))
            } else {
                result.append(ScannedTag(tag: tagText, depth: depth, isClosing: false))
                let selfClosing = inner.hasSuffix("/") || Self.voidElements.contains(String(name))
                if !selfClosing { depth += 1 }
            }
        }
        return result
    }
}
