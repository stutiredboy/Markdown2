import Testing
@testable import MD2Core

/// Task 6.1 / 6.2 / `markdown-compatibility-matrix`: each interpreted construct's
/// declared boundary is testable — block constructs emit their declared top-level
/// element carrying source-line metadata, and inline constructs honour the
/// declared precedence. Probes are keyed by matrix construct id.
struct DeclaredBoundaryTests {
    private let renderer = MarkdownRenderer()

    // MARK: Block constructs

    private struct BlockProbe {
        let constructID: String
        let markdown: String
        let tagPrefix: String
        let multiLine: Bool
    }

    private let blockProbes: [BlockProbe] = [
        .init(constructID: "atx-headings", markdown: "# Heading", tagPrefix: "<h1", multiLine: false),
        .init(constructID: "setext-headings", markdown: "Title\n=====", tagPrefix: "<h1", multiLine: true),
        .init(constructID: "thematic-breaks", markdown: "---", tagPrefix: "<hr", multiLine: false),
        .init(constructID: "fenced-code-blocks", markdown: "```\ncode line\n```", tagPrefix: "<pre", multiLine: true),
        .init(constructID: "indented-code-blocks", markdown: "    indented", tagPrefix: "<pre", multiLine: false),
        .init(constructID: "block-quotes", markdown: "> quoted", tagPrefix: "<blockquote", multiLine: false),
        .init(constructID: "list-items", markdown: "- a\n- b", tagPrefix: "<ul", multiLine: true),
        .init(constructID: "lists", markdown: "1. a\n2. b", tagPrefix: "<ol", multiLine: true),
        .init(constructID: "gfm-tables", markdown: "| a | b |\n| --- | --- |\n| 1 | 2 |", tagPrefix: "<table", multiLine: true),
        .init(constructID: "gfm-task-lists", markdown: "- [ ] task\n- [x] done", tagPrefix: "<ul", multiLine: true),
        .init(constructID: "tex-math", markdown: "$$\na^2\n$$", tagPrefix: "<div class=\"math", multiLine: true),
        .init(constructID: "diagrams", markdown: "```mermaid\ngraph TD; A-->B;\n```", tagPrefix: "<div class=\"diagram", multiLine: true),
        .init(constructID: "footnotes", markdown: "Body[^a]\n\n[^a]: note", tagPrefix: "<li id=\"fn-", multiLine: false)
    ]

    @Test func blockConstructsEmitDeclaredElementWithSourceLineMetadata() throws {
        let matrix = try CompatibilityMatrix.load()
        let byID = Dictionary(uniqueKeysWithValues: matrix.entries.map { ($0.id, $0) })

        for probe in blockProbes {
            let entry = try #require(byID[probe.constructID], "no matrix entry \(probe.constructID)")
            #expect(entry.tier == "Supported", "\(probe.constructID) probed as a Supported block but tier is \(entry.tier)")

            let body = renderer.render(probe.markdown).body
            let tag = try #require(firstTag(prefix: probe.tagPrefix, in: body),
                                   "\(probe.constructID): expected a \(probe.tagPrefix)…> element, body=\(body)")
            #expect(tag.contains("data-md2-source-line="),
                    "\(probe.constructID): \(probe.tagPrefix) is missing data-md2-source-line; tag=\(tag)")
            if probe.multiLine {
                #expect(tag.contains("data-md2-source-end-line="),
                        "\(probe.constructID): multi-line \(probe.tagPrefix) is missing data-md2-source-end-line; tag=\(tag)")
            }
        }
    }

    // MARK: Inline constructs (precedence)

    private struct InlineProbe {
        let constructID: String
        let markdown: String
        let mustContain: String
        let mustNotContain: String?
    }

    private let inlineProbes: [InlineProbe] = [
        // Code spans win over emphasis.
        .init(constructID: "code-spans", markdown: "`*x*`", mustContain: "<code>*x*</code>", mustNotContain: "<em>"),
        // Backslash escapes win over emphasis.
        .init(constructID: "backslash-escapes", markdown: "\\*x\\*", mustContain: "*x*", mustNotContain: "<em>"),
        // Inline math protects its content from emphasis.
        .init(constructID: "tex-math", markdown: "$a*b*c$", mustContain: "math-inline", mustNotContain: "<em>"),
        // Emphasis is resolved inside link text.
        .init(constructID: "links", markdown: "[*x*](u)", mustContain: "<em>x</em>", mustNotContain: nil),
        // Images emit <img> with the source.
        .init(constructID: "images", markdown: "![a](i.png)", mustContain: "src=\"i.png\"", mustNotContain: nil),
        // Angle-bracket autolinks become anchors.
        .init(constructID: "autolinks", markdown: "<https://x.com>", mustContain: "<a href=\"https://x.com\">", mustNotContain: nil),
        // Strikethrough.
        .init(constructID: "gfm-strikethrough", markdown: "~~x~~", mustContain: "<del>x</del>", mustNotContain: nil),
        // Unsafe inline HTML is escaped, not passed through.
        .init(constructID: "raw-html-inline", markdown: "<script>x</script>", mustContain: "&lt;script&gt;", mustNotContain: "<script>")
    ]

    @Test func inlineConstructsHonourDeclaredPrecedence() throws {
        let matrix = try CompatibilityMatrix.load()
        let ids = Set(matrix.entries.map(\.id))

        for probe in inlineProbes {
            #expect(ids.contains(probe.constructID), "no matrix entry \(probe.constructID)")
            let body = renderer.render(probe.markdown).body
            #expect(body.contains(probe.mustContain),
                    "\(probe.constructID): expected \(probe.mustContain) in body=\(body)")
            if let forbidden = probe.mustNotContain {
                #expect(!body.contains(forbidden),
                        "\(probe.constructID): did not expect \(forbidden) in body=\(body)")
            }
        }
    }

    /// Returns the opening tag (`<prefix … >`) of the first element whose start
    /// matches `prefix`, or nil if absent.
    private func firstTag(prefix: String, in html: String) -> String? {
        guard let start = html.range(of: prefix) else { return nil }
        guard let end = html.range(of: ">", range: start.lowerBound..<html.endIndex) else { return nil }
        return String(html[start.lowerBound..<end.upperBound])
    }
}
