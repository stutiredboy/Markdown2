import Foundation

public struct MarkdownRenderer: Sendable {
    private let outlineBuilder = OutlineBuilder()

    public init() {}

    /// Renders Markdown to a full preview document. `config` carries the
    /// technical/academic inputs the pure renderer cannot discover on its own
    /// (syntax preferences, alert language, bibliography, citation style,
    /// equation numbering, and math macros); the default config reproduces the configuration-free
    /// behavior for the many call sites and tests that need none of it.
    public func render(
        _ markdown: String,
        config: RenderConfig = .init(),
        assetMode: RenderAssetMode = .inline
    ) -> RenderedDocument {
        let lines = markdown.normalizedMarkdownLines
        let outline = outlineBuilder.build(from: markdown)

        let footnotes = FootnoteContext()
        collectFootnoteDefinitions(lines, into: footnotes)
        var references: [String: LinkReference] = [:]
        collectLinkReferences(lines, into: &references)

        let citations = CitationContext(entries: config.bibliography, style: config.citationStyle)
        let crossReferences = CrossReferenceContext(numberAllEquations: config.numberAllEquations)
        // Pre-scan labels so a `\ref{}` before its target resolves (mirroring the
        // footnote pre-scan); the counters are then rewound so the render walk
        // re-assigns identical numbers as it emits each element.
        collectCrossReferenceLabels(lines, into: crossReferences, config: config)
        crossReferences.resetCounters()

        let context = InlineContext(
            footnotes: footnotes,
            citations: citations,
            crossReferences: crossReferences,
            references: references,
            config: config
        )

        var body = renderBody(markdown, outline: outline, context: context)
        if let section = footnoteSectionHTML(footnotes, inlineContext: context) {
            body += "\n" + section
        }
        if let bibliography = bibliographySectionHTML(citations) {
            body += "\n" + bibliography
        }
        let html = htmlDocument(body: body, config: config, assetMode: assetMode)

        return RenderedDocument(
            html: html,
            body: body,
            outline: outline,
            stats: DocumentStats(plainText: RenderedPlainText.extract(from: body),
                                 sourceLines: markdown.isEmpty ? 0 : lines.count)
        )
    }

    private func renderBody(
        _ markdown: String,
        outline: [Heading],
        context: InlineContext,
        lineOffset: Int = 0
    ) -> String {
        let lines = markdown.normalizedMarkdownLines
        let headingsByLine = Dictionary(uniqueKeysWithValues: outline.map { ($0.line, $0) })
        var blocks: [String] = []
        var index = 0

        // Every top-level block records the 1-based source-line span that
        // produced it (`data-md2-source-line` / `-end-line`), so the preview
        // can map its viewport back to editor lines on a mode switch.
        // `lineOffset` keeps spans absolute inside nested blockquote renders.
        func appendBlock(_ html: String, from startIndex: Int, to nextIndex: Int) {
            blocks.append(taggedWithSourceLines(
                html,
                startLine: lineOffset + startIndex + 1,
                endLine: lineOffset + nextIndex
            ))
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmedMarkdownLine

            if trimmed.isEmpty {
                index += 1
                continue
            }

            if index == 0, trimmed == "---" {
                if let frontMatter = frontMatterBlock(from: lines, startIndex: index) {
                    appendBlock(frontMatter.html, from: index, to: frontMatter.nextIndex)
                    index = frontMatter.nextIndex
                    continue
                }
            }

            if let fence = fencedCodeBlock(from: lines, startIndex: index) {
                appendBlock(fence.html, from: index, to: fence.nextIndex)
                index = fence.nextIndex
                continue
            }

            // Checked before indented code: a line that begins with `>` (after
            // its leading indentation) is a blockquote, not an indented code
            // block. This matters for quotes nested under a list item, which are
            // indented four spaces and would otherwise render as `<pre>` showing
            // the literal `>` with a horizontal scrollbar.
            if trimmed.hasPrefix(">") {
                let blockquote = blockquoteBlock(
                    from: lines,
                    startIndex: index,
                    context: context,
                    lineOffset: lineOffset
                )
                appendBlock(blockquote.html, from: index, to: blockquote.nextIndex)
                index = blockquote.nextIndex
                continue
            }

            if let indentedCode = indentedCodeBlock(from: lines, startIndex: index) {
                appendBlock(indentedCode.html, from: index, to: indentedCode.nextIndex)
                index = indentedCode.nextIndex
                continue
            }

            if let math = mathBlockContent(from: lines, startIndex: index) {
                appendBlock(
                    mathDisplayBlockHTML(tex: math.tex, context: context),
                    from: index,
                    to: math.nextIndex
                )
                index = math.nextIndex
                continue
            }

            if let definition = LinkReference.parse(lines, at: index) {
                index = definition.next
                continue
            }

            if trimmed == "[TOC]" {
                appendBlock(tableOfContents(outline), from: index, to: index + 1)
                index += 1
                continue
            }

            if let table = tableBlock(from: lines, startIndex: index, context: context) {
                // A Pandoc-style caption line (`: caption {#tbl:label}`) immediately
                // after the table numbers and labels it, and is consumed from body flow.
                if table.nextIndex < lines.count,
                   let caption = parseTableCaption(lines[table.nextIndex]) {
                    let number = context.crossReferences.assignTable(label: caption.label)
                    let captioned = tableWithCaption(
                        table.html,
                        number: number,
                        caption: caption.caption,
                        label: caption.label,
                        context: context
                    )
                    appendBlock(captioned, from: index, to: table.nextIndex + 1)
                    index = table.nextIndex + 1
                } else {
                    appendBlock(table.html, from: index, to: table.nextIndex)
                    index = table.nextIndex
                }
                continue
            }

            if let setextHeading = setextHeadingBlock(from: lines, startIndex: index, headingsByLine: headingsByLine, context: context) {
                appendBlock(setextHeading.html, from: index, to: setextHeading.nextIndex)
                index = setextHeading.nextIndex
                continue
            }

            if let heading = MarkdownLine.heading(in: line), let outlineHeading = headingsByLine[index + 1] {
                appendBlock(
                    "<h\(heading.level) id=\"\(escapeAttribute(outlineHeading.id))\">\(inlineHTML(heading.title, context: context))</h\(heading.level)>",
                    from: index,
                    to: index + 1
                )
                index += 1
                continue
            }

            if MarkdownLine.isHorizontalRule(line) {
                appendBlock("<hr>", from: index, to: index + 1)
                index += 1
                continue
            }

            // Footnote definitions are collected up front; here they are simply
            // consumed so they never render in the body flow.
            if let nextIndex = footnoteDefinitionBlock(from: lines, startIndex: index) {
                index = nextIndex
                continue
            }

            if let list = listBlock(from: lines, startIndex: index, context: context, lineOffset: lineOffset) {
                appendBlock(list.html, from: index, to: list.nextIndex)
                index = list.nextIndex
                continue
            }

            // A line that is solely a labeled figure image renders as a block-level
            // `<figure>` (with a numbered caption) rather than inside a paragraph.
            if let figure = figureBlock(from: lines, startIndex: index, context: context) {
                appendBlock(figure.html, from: index, to: figure.nextIndex)
                index = figure.nextIndex
                continue
            }

            let paragraph = paragraphBlock(from: lines, startIndex: index, context: context)
            appendBlock(paragraph.html, from: index, to: paragraph.nextIndex)
            index = paragraph.nextIndex
        }

        return blocks.joined(separator: "\n")
    }

    /// Inserts the source-line span attributes into a block's first opening
    /// tag. All block HTML starts with its element tag and every attribute
    /// value is HTML-escaped, so the first `>` always terminates that tag.
    /// The end-line attribute is emitted only for multi-line spans.
    private func taggedWithSourceLines(_ html: String, startLine: Int, endLine: Int) -> String {
        guard let tagEnd = html.firstIndex(of: ">") else { return html }

        var attributes = " data-md2-source-line=\"\(startLine)\""
        if endLine > startLine {
            attributes += " data-md2-source-end-line=\"\(endLine)\""
        }

        var tagged = html
        tagged.insert(contentsOf: attributes, at: tagEnd)
        return tagged
    }

    private func frontMatterBlock(from lines: [String], startIndex: Int) -> (html: String, nextIndex: Int)? {
        guard lines[startIndex].trimmedMarkdownLine == "---" else { return nil }

        var index = startIndex + 1
        var content: [String] = []

        while index < lines.count {
            if lines[index].trimmedMarkdownLine == "---" {
                return (
                    "<pre class=\"front-matter\"><code>\(escapeHTML(content.joined(separator: "\n")))</code></pre>",
                    index + 1
                )
            }

            content.append(lines[index])
            index += 1
        }

        return nil
    }

    private func fencedCodeBlock(from lines: [String], startIndex: Int) -> (html: String, nextIndex: Int)? {
        guard let marker = MarkdownLine.fenceMarker(in: lines[startIndex]) else { return nil }

        let opening = lines[startIndex].trimmedMarkdownLine
        let language = opening
            .dropFirst(marker.count)
            .trimmingCharacters(in: .whitespaces)
        var code: [String] = []
        var index = startIndex + 1

        while index < lines.count {
            if lines[index].trimmedMarkdownLine.hasPrefix(marker) {
                return (fencedBlockHTML(language: language, code: code), index + 1)
            }

            code.append(lines[index])
            index += 1
        }

        return (fencedBlockHTML(language: language, code: code), index)
    }

    /// Builds the HTML for a closed or unterminated fenced block. Diagram info
    /// strings (`mermaid`, `flow`, `sequence`) become diagram placeholders;
    /// everything else stays a syntax-highlighted/plain code block.
    private func fencedBlockHTML(language: String, code: [String]) -> String {
        let source = code.joined(separator: "\n")

        if let diagram = DiagramKind(infoString: language) {
            return diagramHTML(kind: diagram, source: source)
        }

        let languageClass = language.isEmpty ? "" : " class=\"language-\(escapeAttribute(language))\""
        return "<pre><code\(languageClass)>\(SyntaxHighlighter.highlightedHTML(for: source, language: language))</code></pre>"
    }

    /// Emits a diagram placeholder carrying the raw diagram source as
    /// HTML-escaped text content so the client-side engine can read it verbatim
    /// from the DOM, mirroring ``mathDisplayHTML``. The placeholder starts in a
    /// `diagram-pending` state: the source stays machine-readable but is hidden
    /// from the reader until the engine renders (or fails), avoiding a raw-source
    /// flash before the SVG arrives.
    private func diagramHTML(kind: DiagramKind, source: String) -> String {
        "<div class=\"\(PreviewClass.diagram) \(kind.cssClass) \(PreviewClass.diagramPending)\">\(escapeHTML(source.trimmingCharacters(in: .newlines)))</div>"
    }

    private func indentedCodeBlock(from lines: [String], startIndex: Int) -> (html: String, nextIndex: Int)? {
        guard MarkdownLine.isIndentedCode(lines[startIndex]) else { return nil }

        var code: [String] = []
        var index = startIndex

        while index < lines.count {
            let line = lines[index]
            if line.trimmedMarkdownLine.isEmpty {
                code.append("")
                index += 1
                continue
            }

            guard MarkdownLine.isIndentedCode(line) else {
                break
            }

            code.append(MarkdownLine.stripCodeIndent(line))
            index += 1
        }

        return ("<pre><code>\(escapeHTML(code.joined(separator: "\n")))</code></pre>", index)
    }

    /// Detects a display math block — delimited by `$$`, by `\[` / `\]`, or by a
    /// native LaTeX environment (`\begin{align}` … `\end{align}`) — and returns its
    /// raw TeX.
    ///
    /// Handles both single-line and multi-line forms. Returns `nil` when the
    /// matching closing delimiter is absent, so the text falls through to normal
    /// paragraph handling. The raw TeX is exposed (rather than finished HTML) so
    /// both the label pre-scan and the render walk can inspect it for
    /// `\label`/`\tag`.
    private func mathBlockContent(from lines: [String], startIndex: Int) -> (tex: String, nextIndex: Int)? {
        let trimmed = lines[startIndex].trimmedMarkdownLine
        let delimiters: (open: String, close: String)
        if trimmed.hasPrefix("$$") {
            delimiters = ("$$", "$$")
        } else if trimmed.hasPrefix(#"\["#) {
            delimiters = (#"\["#, #"\]"#)
        } else {
            return mathEnvironmentContent(from: lines, startIndex: startIndex)
        }

        let afterOpen = String(trimmed.dropFirst(delimiters.open.count))

        // Single-line block: `$$ ... $$` or `\[ ... \]`.
        if afterOpen.hasSuffix(delimiters.close), afterOpen.count >= delimiters.close.count {
            return (String(afterOpen.dropLast(delimiters.close.count)), startIndex + 1)
        }

        // Multi-line block: collect lines until one ends with the matching close.
        var content: [String] = []
        if !afterOpen.isEmpty {
            content.append(afterOpen)
        }

        var index = startIndex + 1
        while index < lines.count {
            let lineTrimmed = lines[index].trimmedMarkdownLine
            if lineTrimmed.hasSuffix(delimiters.close) {
                let beforeClose = String(lineTrimmed.dropLast(delimiters.close.count))
                if !beforeClose.isEmpty {
                    content.append(beforeClose)
                }
                return (content.joined(separator: "\n"), index + 1)
            }

            content.append(lines[index])
            index += 1
        }

        return nil
    }

    /// Environment names that open a display math block with no `$$` or `\[`
    /// wrapper.
    ///
    /// The first group is the display environments the bundled engine typesets and
    /// the second is the standalone inner environments it also accepts at top
    /// level. The third group is environments real LaTeX documents carry that the
    /// engine rejects: recognizing those routes them to the engine so the failure
    /// is reported in place, rather than their source being read as ordinary prose.
    private static let mathEnvironments: Set<String> = [
        "align", "align*", "alignat", "alignat*", "gather", "gather*", "equation", "equation*",
        "aligned", "alignedat", "split", "cases", "array",
        "matrix", "pmatrix", "bmatrix", "Bmatrix", "vmatrix", "Vmatrix", "smallmatrix",
        "multline", "multline*", "eqnarray", "eqnarray*", "displaymath", "subequations"
    ]

    /// Display environments the engine numbers **itself**, by rendering a
    /// `.eqn-num` slot that its stylesheet fills from a CSS counter:
    /// `.katex .eqn-num:before { content: "(" counter(katexEqnNo) ")" }`.
    ///
    /// The engine's rule is "a name with neither a `*` nor an `ed` suffix", which
    /// selects exactly these. The number is invisible to the generated HTML (the
    /// span is empty until CSS runs), so it only ever appears once the preview or
    /// an export paints the page.
    private static let engineNumberedEnvironments: Set<String> = ["align", "alignat", "gather", "equation"]

    /// Detects a display math block written as a native LaTeX environment, with no
    /// `$$` or `\[` wrapper.
    ///
    /// Unlike the `$$`/`\[` branches, the returned TeX **keeps** both environment
    /// commands: the engine needs them to parse the block, and the stripped form
    /// (`a&=b` on its own) is a parse error.
    ///
    /// The scan counts depth for the opening environment's own name, because
    /// same-name nesting (`\begin{matrix}` inside `\begin{matrix}`) is valid and
    /// must not close the block early; an inner environment whose name differs
    /// never matches the closer string, so it cannot terminate the block either. A
    /// fenced-code opener encountered by the scan bails out and returns `nil`: a
    /// real environment never contains a fence, and without the bail a prose line
    /// mentioning `\begin{align}` would swallow a later fenced sample that happens
    /// to contain `\end{align}`.
    private func mathEnvironmentContent(from lines: [String], startIndex: Int) -> (tex: String, nextIndex: Int)? {
        let opened = lines[startIndex].trimmedMarkdownLine
        guard let name = mathEnvironmentName(opening: opened) else { return nil }

        let open = "\\begin{\(name)}"
        let close = "\\end{\(name)}"

        // Single-line form: `\begin{equation}E = mc^2\end{equation}`.
        if opened.hasSuffix(close), opened.count >= open.count + close.count {
            return (suppressingEngineNumbering(in: opened, environment: name), startIndex + 1)
        }

        // Multi-line form: keep the opening line, then scan for the matching close.
        var content = [opened]
        var depth = 1
        var index = startIndex + 1

        while index < lines.count {
            if MarkdownLine.fenceMarker(in: lines[index]) != nil {
                return nil
            }

            let lineTrimmed = lines[index].trimmedMarkdownLine
            depth += occurrences(of: open, in: lineTrimmed)
            depth -= occurrences(of: close, in: lineTrimmed)
            content.append(lines[index])

            if depth <= 0, lineTrimmed.hasSuffix(close) {
                return (
                    suppressingEngineNumbering(in: content.joined(separator: "\n"), environment: name),
                    index + 1
                )
            }

            index += 1
        }

        return nil
    }

    /// Rewrites an engine-numbered display environment into its starred form.
    ///
    /// Left alone, the engine numbers every row of an `align`/`gather`/`equation`
    /// block through its own CSS counter — numbering Markdown2 neither controls nor
    /// ties to `\ref{}`, and which would render *alongside* the `(n)` Markdown2
    /// assigns to a labeled equation. Starring the environment suppresses the
    /// engine's counter while keeping an explicit `\tag{}` working, so display
    /// numbering has exactly one authority — Markdown2's — for `$$` blocks and
    /// environments alike: unnumbered unless labeled or `numberAllEquations`.
    ///
    /// Every occurrence of the name in the block is rewritten, so a same-name
    /// nested environment is covered too.
    private func suppressingEngineNumbering(in tex: String, environment name: String) -> String {
        guard Self.engineNumberedEnvironments.contains(name) else { return tex }

        return tex
            .replacingOccurrences(of: "\\begin{\(name)}", with: "\\begin{\(name)*}")
            .replacingOccurrences(of: "\\end{\(name)}", with: "\\end{\(name)*}")
    }

    /// The environment name when `line` opens a recognized display-math
    /// environment, or `nil` when it does not.
    private func mathEnvironmentName(opening line: String) -> String? {
        let prefix = #"\begin{"#
        guard line.hasPrefix(prefix) else { return nil }

        let afterOpen = line.dropFirst(prefix.count)
        guard let closingBrace = afterOpen.firstIndex(of: "}") else { return nil }

        let name = String(afterOpen[afterOpen.startIndex..<closingBrace])
        return Self.mathEnvironments.contains(name) ? name : nil
    }

    /// Counts non-overlapping occurrences of a literal substring.
    private func occurrences(of needle: String, in haystack: String) -> Int {
        var count = 0
        var searchStart = haystack.startIndex

        while let found = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
            count += 1
            searchStart = found.upperBound
        }

        return count
    }

    /// Thin wrapper kept for the paragraph-break and footnote-scan call sites that
    /// only need to know a display-math block exists here and where it ends.
    private func mathBlock(from lines: [String], startIndex: Int) -> (html: String, nextIndex: Int)? {
        guard let content = mathBlockContent(from: lines, startIndex: startIndex) else { return nil }
        return (mathDisplayHTML(content.tex), content.nextIndex)
    }

    /// Emits an unnumbered display-math wrapper carrying the raw TeX as
    /// HTML-escaped text content so the math engine can read it verbatim from the DOM.
    private func mathDisplayHTML(_ tex: String) -> String {
        "<div class=\"\(PreviewClass.math) \(PreviewClass.mathDisplay)\">\(escapeHTML(tex.trimmingCharacters(in: .whitespacesAndNewlines)))</div>"
    }

    /// Emits a display-math block, applying equation numbering. A `\label{}` is
    /// stripped from the TeX before it reaches KaTeX (0.16 has no `\label` and
    /// would typeset it as a visible error) and recorded for `\ref{}`. An
    /// auto-numbered equation is wrapped so a `(n)` sits to its right; a manual
    /// `\tag{}` is left in the TeX for KaTeX to typeset natively.
    private func mathDisplayBlockHTML(tex: String, context: InlineContext) -> String {
        let info = equationLabelTag(in: tex)
        let number = context.crossReferences.assignEquation(label: info.label, tag: info.tag)
        let idAttribute = info.label.map { " id=\"\(escapeAttribute($0))\"" } ?? ""
        let escaped = escapeHTML(info.stripped)

        // A manual `\tag` stays in the TeX (kept by `equationLabelTag`) and KaTeX
        // renders the number itself, so no separate `(n)` is added here.
        if info.tag != nil {
            return "<div class=\"\(PreviewClass.math) \(PreviewClass.mathDisplay)\"\(idAttribute)>\(escaped)</div>"
        }

        guard let number else {
            return "<div class=\"\(PreviewClass.math) \(PreviewClass.mathDisplay)\">\(escaped)</div>"
        }

        return "<div class=\"numbered-equation\"\(idAttribute)>"
            + "<div class=\"\(PreviewClass.math) \(PreviewClass.mathDisplay)\">\(escaped)</div>"
            + "<span class=\"eq-number\">(\(escapeHTML(number)))</span></div>"
    }

    /// Extracts an equation's `\label{}` and `\tag{}`, and returns the TeX with
    /// the `\label{}` removed (KaTeX cannot typeset it) while keeping `\tag{}` for
    /// KaTeX to render natively.
    private func equationLabelTag(in tex: String) -> (label: String?, tag: String?, stripped: String) {
        let label = firstCapture(in: tex, pattern: #"\\label\s*\{([^}]*)\}"#)
        let tag = firstCapture(in: tex, pattern: #"\\tag\*?\s*\{([^}]*)\}"#)
        let stripped = replaceMatches(in: tex, pattern: #"\\label\s*\{[^}]*\}"#) { _, _ in "" }
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (label, tag, stripped)
    }

    private func setextHeadingBlock(
        from lines: [String],
        startIndex: Int,
        headingsByLine: [Int: Heading],
        context: InlineContext
    ) -> (html: String, nextIndex: Int)? {
        guard startIndex + 1 < lines.count,
              let level = MarkdownLine.setextHeadingLevel(in: lines[startIndex + 1]) else {
            return nil
        }

        let title = lines[startIndex].trimmedMarkdownLine
        guard !title.isEmpty,
              MarkdownLine.heading(in: lines[startIndex]) == nil,
              MarkdownLine.fenceMarker(in: lines[startIndex]) == nil,
              !MarkdownLine.isHorizontalRule(lines[startIndex]),
              parseListItem(lines[startIndex]) == nil,
              !lines[startIndex].trimmedMarkdownLine.hasPrefix(">") else {
            return nil
        }

        var fallbackSlugs: [String: Int] = [:]
        let heading = headingsByLine[startIndex + 1]
        let id = heading?.id ?? Slugger.uniqueSlug(for: title, usedSlugs: &fallbackSlugs)
        return (
            "<h\(level) id=\"\(escapeAttribute(id))\">\(inlineHTML(title, context: context))</h\(level)>",
            startIndex + 2
        )
    }

    private func tableBlock(from lines: [String], startIndex: Int, context: InlineContext? = nil) -> (html: String, nextIndex: Int)? {
        guard startIndex + 1 < lines.count,
              lines[startIndex].contains("|"),
              let alignments = tableAlignments(in: lines[startIndex + 1]) else {
            return nil
        }

        let headers = splitTableLine(lines[startIndex])
        guard !headers.isEmpty else { return nil }

        var rows: [[String]] = []
        var index = startIndex + 2

        while index < lines.count, lines[index].contains("|"), !lines[index].trimmedMarkdownLine.isEmpty {
            rows.append(splitTableLine(lines[index]))
            index += 1
        }

        let headerHTML = headers.enumerated()
            .map { index, header in
                let style = alignments[safe: index]?.htmlAttribute ?? ""
                return "<th\(style)>\(inlineHTML(header.trimmingCharacters(in: .whitespaces), context: context))</th>"
            }
            .joined()
        let bodyHTML = rows
            .map { row in
                let cells = row.enumerated()
                    .map { index, cell in
                        let style = alignments[safe: index]?.htmlAttribute ?? ""
                        return "<td\(style)>\(inlineHTML(cell.trimmingCharacters(in: .whitespaces), context: context))</td>"
                    }
                    .joined()
                return "<tr>\(cells)</tr>"
            }
            .joined(separator: "\n")

        return (
            """
            <table>
            <thead><tr>\(headerHTML)</tr></thead>
            <tbody>
            \(bodyHTML)
            </tbody>
            </table>
            """,
            index
        )
    }

    private func blockquoteBlock(
        from lines: [String],
        startIndex: Int,
        context: InlineContext,
        lineOffset: Int = 0
    ) -> (html: String, nextIndex: Int) {
        var quoteLines: [String] = []
        var index = startIndex

        while index < lines.count {
            let trimmed = lines[index].trimmedMarkdownLine
            guard trimmed.hasPrefix(">") else { break }

            var content = trimmed.dropFirst()
            if content.first == " " || content.first == "\t" { content = content.dropFirst() }
            quoteLines.append(String(content))
            index += 1
        }

        // Quote content lines map 1:1 to the consumed source lines, so the
        // nested render keeps absolute source-line spans by offsetting to the
        // quote's first line.
        let alertKind = quoteLines.first.flatMap { line -> String? in
            let marker = line.trimmingCharacters(in: .whitespaces)
            return ["NOTE", "TIP", "IMPORTANT", "WARNING", "CAUTION"].first { marker == "[!\($0)]" }
        }
        if alertKind != nil { quoteLines.removeFirst() }
        let nestedMarkdown = quoteLines.joined(separator: "\n")
        let quote = renderBody(
            nestedMarkdown,
            outline: outlineBuilder.build(from: nestedMarkdown),
            context: context,
            lineOffset: lineOffset + startIndex + (alertKind == nil ? 0 : 1)
        )

        if let alertKind {
            let title = context.config.alertLanguage.title(for: alertKind)
            return ("<div class=\"markdown-alert markdown-alert-\(alertKind.lowercased())\">\n"
                + "<p class=\"markdown-alert-title\">\(title)</p>\n\(quote)\n</div>", index)
        }
        return ("<blockquote>\n\(quote)\n</blockquote>", index)
    }

    private func listBlock(from lines: [String], startIndex: Int, context: InlineContext, lineOffset: Int = 0) -> (html: String, nextIndex: Int)? {
        guard parseListItem(lines[startIndex]) != nil else { return nil }

        // Collect the run of list lines; indented continuation lines are included
        // so they can become nested child lists. A blank line does not terminate
        // the list as long as it is followed (after any run of blank lines) by
        // another list item — that keeps a loose, blank-line-separated list (e.g.
        // numbered points spaced apart) as one continuously numbered list rather
        // than restarting the count at each item. Each item records its absolute
        // source line (`lineOffset` keeps blockquote-nested lists absolute) and
        // its raw `lines` index (so `built.next` can map back to a source line).
        var items: [ListItem] = []
        var index = startIndex
        while index < lines.count {
            if var item = parseListItem(lines[index], sourceLine: lineOffset + index + 1, lineIndex: index) {
                index += 1
                let (continuation, next) = collectListItemContinuation(
                    from: lines,
                    startIndex: index,
                    contentIndent: item.contentIndent
                )
                item.continuation = continuation
                items.append(item)
                index = next
                continue
            }

            if lines[index].trimmedMarkdownLine.isEmpty {
                var lookahead = index + 1
                while lookahead < lines.count, lines[lookahead].trimmedMarkdownLine.isEmpty {
                    lookahead += 1
                }
                if lookahead < lines.count, parseListItem(lines[lookahead]) != nil {
                    index = lookahead
                    continue
                }
            }

            if !items.isEmpty, isStandaloneImageLine(lines[index]) {
                var continuation: [String] = []
                var lookahead = index
                while lookahead < lines.count {
                    let candidate = lines[lookahead]
                    if candidate.trimmedMarkdownLine.isEmpty {
                        continuation.append("")
                        lookahead += 1
                        continue
                    }
                    guard isStandaloneImageLine(candidate) else { break }
                    continuation.append(candidate)
                    lookahead += 1
                }

                if lookahead < lines.count,
                   let nextItem = parseListItem(lines[lookahead]),
                   nextItem.indent >= items[items.count - 1].indent {
                    items[items.count - 1].continuation.append(contentsOf: continuation)
                    index = lookahead
                    continue
                }
            }

            break
        }

        let levels = nestingLevels(for: items)

        let built = buildList(items: items, levels: levels, start: 0, level: levels[0], context: context, lineOffset: lineOffset)
        // `built.next` is an index into `items`; map it back to a raw line index
        // so the body walk resumes correctly even when blank lines were absorbed.
        // When every item was consumed, resume at the line that ended collection.
        let nextIndex = built.next < items.count ? items[built.next].lineIndex : index
        return (built.html, nextIndex)
    }

    /// Gathers the block-content lines belonging to a list item: consecutive
    /// lines indented past the item's marker that are not themselves list items
    /// (those open nested child lists, which `buildList` handles via the flat
    /// `items` array). A blank line is included only when a qualifying
    /// continuation line follows it, so a blank that merely separates the item
    /// from a sibling is left for the caller's loose-list handling. A fenced
    /// code block opened inside the continuation is consumed through its closing
    /// fence — including any internally dedented lines — so code is never cut
    /// short. Returns the raw lines (original indentation preserved) and the
    /// index of the first line that does not belong to the item.
    private func collectListItemContinuation(
        from lines: [String],
        startIndex: Int,
        contentIndent: Int
    ) -> (lines: [String], nextIndex: Int) {
        func belongs(_ line: String) -> Bool {
            parseListItem(line) == nil && leadingIndentWidth(line) >= contentIndent
        }

        var continuation: [String] = []
        var index = startIndex

        while index < lines.count {
            let line = lines[index]

            if line.trimmedMarkdownLine.isEmpty {
                var lookahead = index + 1
                while lookahead < lines.count, lines[lookahead].trimmedMarkdownLine.isEmpty {
                    lookahead += 1
                }
                guard lookahead < lines.count, belongs(lines[lookahead]) else { break }
                continuation.append("")
                index += 1
                continue
            }

            guard belongs(line) else { break }

            continuation.append(line)
            index += 1

            if let marker = MarkdownLine.fenceMarker(in: line) {
                while index < lines.count {
                    let fenceLine = lines[index]
                    continuation.append(fenceLine)
                    index += 1
                    if fenceLine.trimmedMarkdownLine.hasPrefix(marker) {
                        break
                    }
                }
            }
        }

        return (continuation, index)
    }

    /// Removes the smallest non-blank leading-indent width from every line so an
    /// item's captured body renders as top-level Markdown, while preserving
    /// relative indentation (a code block nested deeper inside the item keeps
    /// its shape). Blank lines stay blank.
    private func stripCommonIndent(_ lines: [String]) -> String {
        let minIndent = lines
            .filter { !$0.trimmedMarkdownLine.isEmpty }
            .map { leadingIndentWidth($0) }
            .min() ?? 0

        guard minIndent > 0 else { return lines.joined(separator: "\n") }

        return lines
            .map { dropIndentColumns($0, minIndent) }
            .joined(separator: "\n")
    }

    /// Drops up to `columns` of leading-whitespace width from a line (a tab
    /// counts as four columns). Stops at the first non-whitespace character.
    private func dropIndentColumns(_ line: String, _ columns: Int) -> String {
        var remaining = columns
        var rest = Substring(line)

        while remaining > 0, let first = rest.first {
            if first == " " {
                remaining -= 1
            } else if first == "\t" {
                remaining -= 4
            } else {
                break
            }
            rest = rest.dropFirst()
        }

        return String(rest)
    }

    /// Derives each item's nesting level from indentation. A child list starts
    /// when its marker reaches the previous open item's content column: two
    /// spaces under `- `, three under `1. `, four under `10. `, etc. Consecutive
    /// siblings at the child indent stay on that child level because the nearest
    /// ancestor whose content column they still reach remains on the stack.
    private func nestingLevels(for items: [ListItem]) -> [Int] {
        struct OpenLevel {
            var contentIndent: Int
        }

        var stack: [OpenLevel] = []
        var levels: [Int] = []

        for item in items {
            let level: Int
            if let parentIndex = stack.lastIndex(where: { item.indent >= $0.contentIndent }) {
                level = parentIndex + 1
            } else {
                level = 0
            }

            if level < stack.count {
                stack.removeSubrange(level..<stack.count)
            }

            let openLevel = OpenLevel(contentIndent: item.contentIndent)
            if level == stack.count {
                stack.append(openLevel)
            } else {
                stack[level] = openLevel
            }

            levels.append(level)
        }

        return levels
    }

    /// Recursively builds a (possibly nested) `<ul>`/`<ol>` starting at `start`.
    /// Items at `level` are siblings; deeper items become child lists nested in
    /// the preceding sibling's `<li>`. A kind change at the same level ends the
    /// current list so the remaining items form a separate sibling list.
    /// Returns the HTML and the index of the first item not consumed.
    private func buildList(
        items: [ListItem],
        levels: [Int],
        start: Int,
        level: Int,
        context: InlineContext,
        lineOffset: Int
    ) -> (html: String, next: Int) {
        let kind = items[start].kind
        let tag = kind == .ordered ? "ol" : "ul"
        var listItems: [String] = []
        var hasTask = false
        var index = start

        while index < items.count {
            if levels[index] < level { break }
            if levels[index] == level && items[index].kind != kind { break }
            if levels[index] > level { break } // defensive: handled below

            let item = items[index]
            let checkbox: String
            if let checked = item.checked {
                hasTask = true
                // Enabled so a preview click can toggle it; the attribute names
                // the source line the click maps back to.
                checkbox = "<input type=\"checkbox\" data-md2-task-line=\"\(item.line)\"\(checked ? " checked" : "")> "
            } else {
                checkbox = ""
            }

            let itemText = LinkReference.parse([item.text], at: 0) == nil ? inlineHTML(item.text, context: context) : ""
            var content = "\(checkbox)\(itemText)"
            index += 1

            // Render any block content captured under the marker (paragraphs,
            // code blocks, tables, …) as the item's body. The nested render
            // shares `context` so footnotes/citations accumulate, and offsets to
            // the continuation's first source line to keep spans absolute.
            if !item.continuation.isEmpty {
                let dedented = stripCommonIndent(item.continuation)
                let body = renderBody(
                    dedented,
                    outline: outlineBuilder.build(from: dedented),
                    context: context,
                    lineOffset: lineOffset + item.lineIndex + 1
                )
                if !body.isEmpty {
                    content += "\n\(body)"
                }
            }

            // Attach any deeper items as nested child lists of this item.
            while index < items.count, levels[index] > level {
                let child = buildList(
                    items: items,
                    levels: levels,
                    start: index,
                    level: levels[index],
                    context: context,
                    lineOffset: lineOffset
                )
                content += "\n\(child.html)"
                index = child.next
            }

            listItems.append("<li>\(content)</li>")
        }

        let className = hasTask ? " class=\"task-list\"" : ""
        return ("<\(tag)\(className)>\n\(listItems.joined(separator: "\n"))\n</\(tag)>", index)
    }

    private func paragraphBlock(from lines: [String], startIndex: Int, context: InlineContext, renderContent: Bool = true) -> (html: String, nextIndex: Int) {
        var paragraphLines: [String] = []
        var index = startIndex

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmedMarkdownLine

            if trimmed.isEmpty ||
                MarkdownLine.heading(in: line) != nil ||
                MarkdownLine.fenceMarker(in: line) != nil ||
                MarkdownLine.isHorizontalRule(line) ||
                (index + 1 < lines.count && MarkdownLine.setextHeadingLevel(in: lines[index + 1]) != nil) ||
                trimmed == "[TOC]" ||
                trimmed.hasPrefix(">") ||
                isFootnoteDefinitionLine(line) ||
                parseListItem(line) != nil ||
                mathBlock(from: lines, startIndex: index) != nil ||
                tableBlock(from: lines, startIndex: index) != nil {
                break
            }

            paragraphLines.append(line)
            index += 1
        }

        return (renderContent ? "<p>\(paragraphHTML(paragraphLines, context: context))</p>" : "", max(index, startIndex + 1))
    }

    private func paragraphHTML(_ lines: [String], context: InlineContext) -> String {
        let source = lines.enumerated().map { index, line in
            let hasHardBreak = line.hasSuffix("  ") || line.hasSuffix("\\")
            let content: String

            if line.hasSuffix("\\") {
                content = String(line.dropLast()).trimmingCharacters(in: .whitespaces)
            } else {
                content = line.trimmingCharacters(in: .whitespaces)
            }

            // A soft line break (a newline mid-paragraph) renders as a visible
            // <br>, matching the editor's WYSIWYG expectation; only the
            // paragraph's final line — when it carries no explicit hard break —
            // omits the trailing break. Soft and hard breaks thus converge here.
            if index == lines.count - 1 && !hasHardBreak {
                return content
            }
            return "\(content)\n"
        }.joined()
        return inlineHTML(source, context: context)
    }

    // MARK: Footnotes

    /// Walk the same containers as the block renderer. Definitions cannot
    /// interrupt paragraphs, and code/math/front matter never define links.
    private func collectLinkReferences(_ lines: [String], into definitions: inout [String: LinkReference]) {
        var index = 0
        let inertContext = InlineContext(footnotes: FootnoteContext(),
            citations: CitationContext(entries: [:], style: .authorYear),
            crossReferences: CrossReferenceContext(numberAllEquations: false))
        while index < lines.count {
            let trimmed = lines[index].trimmedMarkdownLine
            if trimmed.isEmpty { index += 1; continue }
            if index == 0, let block = frontMatterBlock(from: lines, startIndex: index) {
                index = block.nextIndex; continue
            }
            if let block = fencedCodeBlock(from: lines, startIndex: index) {
                index = block.nextIndex; continue
            }
            if trimmed.hasPrefix(">") {
                var nested: [String] = []
                while index < lines.count, lines[index].trimmedMarkdownLine.hasPrefix(">") {
                    var content = lines[index].trimmedMarkdownLine.dropFirst()
                    if content.first == " " || content.first == "\t" { content = content.dropFirst() }
                    nested.append(String(content)); index += 1
                }
                // An alert marker is a block header, not the first paragraph.
                if let first = nested.first, ["NOTE", "TIP", "IMPORTANT", "WARNING", "CAUTION"].contains(where: { first == "[!\($0)]" }) {
                    nested[0] = ""
                }
                collectLinkReferences(nested, into: &definitions)
                continue
            }
            if let block = indentedCodeBlock(from: lines, startIndex: index) {
                index = block.nextIndex; continue
            }
            if let block = mathBlock(from: lines, startIndex: index) {
                index = block.nextIndex; continue
            }
            if let definition = LinkReference.parse(lines, at: index) {
                let key = LinkReference.normalize(escapeHTML(definition.label))
                if definitions[key] == nil { definitions[key] = definition.reference }
                index = definition.next; continue
            }
            if let note = parseFootnoteDefinition(from: lines, startIndex: index) {
                index = note.nextIndex; continue
            }
            if let item = parseListItem(lines[index]) {
                collectLinkReferences([item.text], into: &definitions)
                let continuation = collectListItemContinuation(from: lines, startIndex: index + 1, contentIndent: item.contentIndent)
                collectLinkReferences(stripCommonIndent(continuation.lines).normalizedMarkdownLines, into: &definitions)
                index = continuation.nextIndex; continue
            }
            if let table = tableBlock(from: lines, startIndex: index) {
                index = table.nextIndex; continue
            }
            if MarkdownLine.heading(in: lines[index]) != nil || MarkdownLine.isHorizontalRule(lines[index]) || trimmed == "[TOC]" {
                index += 1; continue
            }
            if index + 1 < lines.count, MarkdownLine.setextHeadingLevel(in: lines[index + 1]) != nil {
                index += 2; continue
            }
            index = paragraphBlock(from: lines, startIndex: index, context: inertContext, renderContent: false).nextIndex
        }
    }

    /// Whole-document pre-scan that records footnote definitions (`[^id]: text`)
    /// and their indented continuation lines, while skipping fenced/indented code
    /// and display-math blocks so footnote-like text inside them is never treated
    /// as a definition. Running this before rendering lets references that appear
    /// before their definition still resolve and be numbered correctly.
    private func collectFootnoteDefinitions(_ lines: [String], into context: FootnoteContext) {
        var index = 0
        while index < lines.count {
            if let fence = fencedCodeBlock(from: lines, startIndex: index) {
                index = fence.nextIndex
                continue
            }
            if let code = indentedCodeBlock(from: lines, startIndex: index) {
                index = code.nextIndex
                continue
            }
            if let math = mathBlock(from: lines, startIndex: index) {
                index = math.nextIndex
                continue
            }
            if let definition = parseFootnoteDefinition(from: lines, startIndex: index) {
                context.define(label: definition.label, content: definition.content, line: index + 1)
                index = definition.nextIndex
                continue
            }
            index += 1
        }
    }

    /// Consumes a footnote definition (and its continuation lines) during the body
    /// walk so it produces no in-place output; the content was already captured by
    /// ``collectFootnoteDefinitions``.
    private func footnoteDefinitionBlock(from lines: [String], startIndex: Int) -> Int? {
        guard let definition = parseFootnoteDefinition(from: lines, startIndex: startIndex) else {
            return nil
        }
        return definition.nextIndex
    }

    /// Parses a `[^id]: text` definition starting at `startIndex`, gathering any
    /// following indented continuation lines (blank lines are kept only when an
    /// indented line follows them). Up to three leading spaces are allowed so a
    /// 4-space-indented line is left to indented-code handling instead.
    private func parseFootnoteDefinition(
        from lines: [String],
        startIndex: Int
    ) -> (label: String, content: [String], nextIndex: Int)? {
        let line = lines[startIndex]
        guard let match = firstMatch(in: line, pattern: #"^ {0,3}\[\^([^\]\s]+)\]:[ \t]?(.*)$"#),
              let labelRange = Range(match.range(at: 1), in: line),
              let textRange = Range(match.range(at: 2), in: line) else {
            return nil
        }

        let label = String(line[labelRange])
        var content = [String(line[textRange])]
        var index = startIndex + 1

        while index < lines.count {
            let candidate = lines[index]
            if candidate.trimmedMarkdownLine.isEmpty {
                // A blank line continues the definition only if an indented line
                // follows; otherwise it ends the definition.
                var lookahead = index
                while lookahead < lines.count, lines[lookahead].trimmedMarkdownLine.isEmpty {
                    lookahead += 1
                }
                guard lookahead < lines.count, isIndentedContinuation(lines[lookahead]) else {
                    break
                }
                content.append("")
                index += 1
                continue
            }

            guard isIndentedContinuation(candidate) else { break }
            content.append(candidate.trimmedMarkdownLine)
            index += 1
        }

        return (label, content, index)
    }

    private func isFootnoteDefinitionLine(_ line: String) -> Bool {
        firstMatch(in: line, pattern: #"^ {0,3}\[\^([^\]\s]+)\]:"#) != nil
    }

    private func isIndentedContinuation(_ line: String) -> Bool {
        let prefix = line.prefix { $0 == " " || $0 == "\t" }
        return prefix.contains("\t") || prefix.filter { $0 == " " }.count >= 2
    }

    /// Builds the trailing footnotes section from the referenced definitions, in
    /// first-reference order, each with a back-reference link per reference site.
    /// Returns `nil` when no footnote was referenced.
    private func footnoteSectionHTML(_ context: FootnoteContext, inlineContext: InlineContext) -> String? {
        guard context.hasReferences else { return nil }

        let items = context.referencedLabels.map { label -> String in
            let base = context.anchorBase(for: label)
            let raw = (context.content(for: label) ?? [])
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            // Keep syntax settings and link definitions inside footnotes without
            // registering recursive footnote/citation references during iteration.
            let rendered = inlineHTML(raw, context: InlineContext(
                footnotes: FootnoteContext(), citations: CitationContext(entries: [:], style: .authorYear),
                crossReferences: inlineContext.crossReferences,
                references: inlineContext.references, config: inlineContext.config))

            let count = context.referenceCount(for: label)
            let backrefs = (1...max(count, 1)).map { occurrence -> String in
                let anchor = occurrence == 1 ? "fnref-\(base)" : "fnref-\(base)-\(occurrence)"
                return "<a class=\"footnote-backref\" href=\"#\(anchor)\" aria-label=\"Back to reference\">↩</a>"
            }.joined(separator: " ")

            // Footnote items map back to the definition's source line so the
            // footnotes section can anchor a mode switch like any other block.
            let sourceLine = context.definitionLine(for: label)
                .map { " data-md2-source-line=\"\($0)\"" } ?? ""
            return "<li id=\"fn-\(base)\"\(sourceLine)>\(rendered) \(backrefs)</li>"
        }.joined(separator: "\n")

        return """
        <section class="footnotes">
        <ol>
        \(items)
        </ol>
        </section>
        """
    }

    private func tableOfContents(_ outline: [Heading]) -> String {
        guard !outline.isEmpty else { return "<nav class=\"toc\"></nav>" }

        let items = outline.map { heading in
            """
            <a class="toc-level-\(heading.level)" href="#\(escapeAttribute(heading.id))">\(escapeHTML(heading.title))</a>
            """
        }.joined(separator: "\n")

        return "<nav class=\"toc\">\n\(items)\n</nav>"
    }

    /// Parses one source line as a list item. `sourceLine` is the absolute
    /// 1-based line number recorded on the item; `lineIndex` is its raw index
    /// in the `lines` array. Callers that only test whether a line is a list
    /// item can omit both.
    private func parseListItem(_ line: String, sourceLine: Int = 0, lineIndex: Int = 0) -> ListItem? {
        let trimmed = line.trimmedMarkdownLine
        let indent = leadingIndentWidth(line)

        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
            var text = String(trimmed.dropFirst(2))
            var checked: Bool?

            if text.lowercased().hasPrefix("[x] ") {
                checked = true
                text = String(text.dropFirst(4))
            } else if text.hasPrefix("[ ] ") {
                checked = false
                text = String(text.dropFirst(4))
            }

            return ListItem(
                kind: .unordered,
                checked: checked,
                text: text,
                indent: indent,
                contentIndent: listContentIndent(after: line, markerIndent: indent, delimiterWidth: 1),
                line: sourceLine,
                lineIndex: lineIndex
            )
        }

        guard let match = firstMatch(in: trimmed, pattern: #"^(\d+[\.)])\s+(.+)$"#),
              let markerRange = Range(match.range(at: 1), in: trimmed),
              let textRange = Range(match.range(at: 2), in: trimmed) else {
            return nil
        }

        return ListItem(
            kind: .ordered,
            checked: nil,
            text: String(trimmed[textRange]),
            indent: indent,
            contentIndent: listContentIndent(after: line, markerIndent: indent, delimiterWidth: trimmed[markerRange].count),
            line: sourceLine,
            lineIndex: lineIndex
        )
    }

    private func isStandaloneImageLine(_ line: String) -> Bool {
        let trimmed = line.trimmedMarkdownLine
        return firstMatch(in: trimmed, pattern: #"^!\[[^\]]*\]\([^)]*\)(?:\{[^}]*\})?$"#) != nil
    }

    /// Column at which a list item's content begins: the marker indent, plus the
    /// marker delimiter width, plus the gap of spaces before the content. The gap
    /// is clamped to 1…4 — five or more spaces start an indented code block inside
    /// the item rather than widening the content column (CommonMark §5.2).
    private func listContentIndent(after line: String, markerIndent: Int, delimiterWidth: Int) -> Int {
        let rest = Substring(line.trimmingCharacters(in: .whitespaces)).dropFirst(delimiterWidth)
        return MarkdownIndentation.contentColumn(markerIndent: markerIndent, delimiterWidth: delimiterWidth, gap: String(rest))
    }

    /// Counts the leading whitespace of a line in columns, treating a tab as 4
    /// columns. Used to determine list-item nesting depth.
    private func leadingIndentWidth(_ line: String) -> Int {
        MarkdownIndentation.width(line)
    }

    private func tableAlignments(in line: String) -> [TableAlignment]? {
        let cells = splitTableLine(line)
        guard !cells.isEmpty else { return nil }

        var alignments: [TableAlignment] = []

        for cell in cells {
            let trimmed = cell.trimmingCharacters(in: .whitespaces)
            guard trimmed.range(of: #"^:?-+:?$"#, options: .regularExpression) != nil else {
                return nil
            }

            if trimmed.hasPrefix(":"), trimmed.hasSuffix(":") {
                alignments.append(.center)
            } else if trimmed.hasSuffix(":") {
                alignments.append(.right)
            } else {
                alignments.append(.left)
            }
        }

        return alignments
    }

    private func splitTableLine(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)

        if trimmed.first == "|" {
            trimmed.removeFirst()
        }

        if trimmed.last == "|" {
            trimmed.removeLast()
        }

        var cells: [String] = []
        var current = ""
        var isEscaped = false
        var activeBacktickCount = 0

        for character in trimmed {
            if isEscaped {
                current.append(character)
                isEscaped = false
                continue
            }

            if character == "\\" {
                current.append(character)
                isEscaped = true
                continue
            }

            if character == "`" {
                activeBacktickCount = activeBacktickCount == 0 ? 1 : 0
                current.append(character)
                continue
            }

            if character == "|", activeBacktickCount == 0 {
                cells.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }

        cells.append(current)
        return cells
    }

    /// Renders inline Markdown by running an explicit, ordered pipeline of passes.
    /// The order is load-bearing: fragments that must survive HTML-escaping and the
    /// later passes (code, math, entities, autolinks, raw HTML, footnote anchors,
    /// images, and links) are swapped for placeholder tokens up front; the text is
    /// escaped once; emphasis then runs only over remaining Markdown text; finally
    /// the protected fragments are restored. Each pass is a named method below, so
    /// adding a new inline construct means inserting one entry at the right point
    /// in this list.
    ///
    /// Both math passes sit ahead of ``protectBackslashEscapes`` on purpose: their
    /// delimiters (`$`, `\(`, `\)`) are built from backslash-escapable punctuation,
    /// so the escape pass would otherwise dismantle them before math ever saw them.
    private func inlineHTML(_ markdown: String, context: InlineContext? = nil) -> String {
        let protector = InlineProtector()

        let pipeline: [(String) -> String] = [
            { protectCodeSpans($0, protector: protector) },
            { protectInlineMath($0, protector: protector) },
            { protectInlineParenMath($0, protector: protector) },
            { protectBackslashEscapes($0, protector: protector) },
            { protectHTMLEntities($0, protector: protector) },
            { protectAutolinks($0, protector: protector) },
            { protectRawHTML($0, protector: protector) },
            { applyFootnoteReferences($0, protector: protector, footnotes: context?.footnotes) },
            { applyCitations($0, protector: protector, citations: context?.citations) },
            { applyCrossReferences($0, protector: protector, crossReferences: context?.crossReferences) },
            { escapeHTML($0) },
            { renderImages($0, context: context, protector: protector) },
            { renderLinks($0, protector: protector, features: context?.config.inlineFeatures ?? .init()) },
            { renderReferenceLinks($0, context: context, protector: protector) },
            { protectBareAutolinks($0, protector: protector) },
            { renderOptionalInline($0, features: context?.config.inlineFeatures ?? .init()) },
            { renderEmphasis($0) },
            { $0.replacingOccurrences(of: "\n", with: "<br>") }
        ]

        let transformed = pipeline.reduce(markdown) { text, pass in pass(text) }
        return protector.restore(in: transformed)
    }

    /// Inline code spans `` `...` ``. The inner text is escaped and the whole span
    /// is protected so later passes never reinterpret code content.
    private func protectCodeSpans(_ text: String, protector: InlineProtector) -> String {
        replaceMatches(in: text, pattern: #"(?<!`)(`+)(?!`)([\s\S]*?)(?<!`)\1(?!`)"#) { match, source in
            guard let codeRange = Range(match.range(at: 2), in: source) else {
                return matchText(match, in: source)
            }
            var code = String(source[codeRange]).replacingOccurrences(of: "\n", with: " ")
            if code.hasPrefix(" "), code.hasSuffix(" "), code.contains(where: { $0 != " " }) {
                code = String(code.dropFirst().dropLast())
            }
            return protector.protect("<code>\(escapeHTML(code))</code>", source: escapeHTML(matchText(match, in: source)))
        }
    }

    /// Backslash-escaped punctuation (`\*`, `\_`, …); the escaped character is
    /// protected so it survives as a literal.
    private func protectBackslashEscapes(_ text: String, protector: InlineProtector) -> String {
        replaceMatches(in: text, pattern: ##"\\([!"#$%&'()*+,\-./:;<=>?@\[\]\\^_`{|}~])"##) { match, source in
            guard let escapedRange = Range(match.range(at: 1), in: source) else {
                return matchText(match, in: source)
            }

            return protector.protect(escapeHTML(String(source[escapedRange])), source: escapeHTML(matchText(match, in: source)), literal: true)
        }
    }

    /// Inline math `$...$`. Runs after code protection (so `$` inside code is never
    /// a delimiter) but before backslash-escape protection, so TeX commands made of
    /// backslash + punctuation (`\,`, `\%`, `\{`, …) reach the math engine verbatim.
    /// The pattern itself guards against escapes: an escaped `\$` never opens math,
    /// and inside the span every backslash is consumed together with its following
    /// character, so an interior `\$` cannot close the span. The opening `$` must
    /// not be followed by whitespace, the closing `$` must not be preceded by
    /// whitespace, and `$$` (display math) is excluded.
    private func protectInlineMath(_ text: String, protector: InlineProtector) -> String {
        replaceMatches(in: text, pattern: #"(?<![$\\])\$(?![\s$])((?:\\.|[^\\$])+?)(?<!\s)\$(?!\$)"#) { match, source in
            guard let range = Range(match.range(at: 1), in: source) else {
                return matchText(match, in: source)
            }

            return protector.protect("<span class=\"\(PreviewClass.math) \(PreviewClass.mathInline)\">\(escapeHTML(String(source[range])))</span>")
        }
    }

    /// Inline math `\(...\)`, the LaTeX spelling of `$...$`. It shares
    /// ``protectInlineMath``'s pipeline slot for the same reason: `(` and `)` are
    /// both backslash-escapable punctuation, so if the escape pass ran first it
    /// would consume the delimiters and the span would degrade to a literal
    /// parenthesized expression — the exact defect this pass exists to fix.
    ///
    /// The pattern opens on `\(` only when that backslash is not itself escaped
    /// (`\\(`), so an authored literal backslash does not start a span. Inside the
    /// span a backslash is consumed together with the following character, so
    /// `\(a\\ b\)` keeps the row separator verbatim while an interior `\)` cannot
    /// close the span early. Spaces are permitted at both ends (LaTeX allows
    /// `\( x \)`), and an empty span is left literal.
    ///
    /// Link and image destinations are excluded: inside `](…)` a `\(` is a
    /// CommonMark escape for a literal paren, not a math delimiter. Claiming it
    /// here would break `[link](\(foo\))`, whose destination must stay `(foo)` —
    /// the escape pass is what feeds those parens through to the `href`.
    private func protectInlineParenMath(_ text: String, protector: InlineProtector) -> String {
        let destinations = LinkDestinationIndex(scanning: text)
        return replaceMatches(in: text, pattern: #"(?<!\\)\\\(((?:\\.|[^\\])+?)\\\)"#) { match, source in
            guard let range = Range(match.range(at: 1), in: source),
                  let matchRange = Range(match.range, in: source),
                  !destinations.contains(matchRange.lowerBound) else {
                return matchText(match, in: source)
            }

            return protector.protect("<span class=\"\(PreviewClass.math) \(PreviewClass.mathInline)\">\(escapeHTML(String(source[range])))</span>")
        }
    }

    /// Pre-existing HTML entities (`&amp;`, `&#960;`, …), protected so the later
    /// `escapeHTML` pass does not double-escape the ampersand.
    private func protectHTMLEntities(_ text: String, protector: InlineProtector) -> String {
        replaceMatches(in: text, pattern: #"&(?:#\d+|#x[0-9A-Fa-f]+|[A-Za-z][A-Za-z0-9]+);"#) { match, source in
            protector.protect(matchText(match, in: source), source: escapeHTML(matchText(match, in: source)), literal: true)
        }
    }

    /// Angle-bracket autolinks `<https://…>` / `<mailto:…>`, rendered to an anchor
    /// and protected. The destination index is built once per pass, so each
    /// autolink's "inside a link destination" check is a lookup instead of a
    /// backward scan over the preceding prefix.
    private func protectAutolinks(_ text: String, protector: InlineProtector) -> String {
        let destinations = LinkDestinationIndex(scanning: text)
        return replaceMatches(in: text, pattern: #"<((?:https?|mailto):[^>\s]+)>"#) { match, source in
            guard let urlRange = Range(match.range(at: 1), in: source),
                  let wholeRange = Range(match.range, in: source),
                  !destinations.contains(wholeRange.lowerBound) else {
                return matchText(match, in: source)
            }

            let url = String(source[urlRange])
            return protector.protect("<a href=\"\(escapeAttribute(url))\">\(escapeHTML(url))</a>")
        }
    }

    /// Formatting HTML is rebuilt with inert attributes before it is protected.
    /// Everything outside this tag allowlist is escaped as visible source.
    private func protectRawHTML(_ text: String, protector: InlineProtector) -> String {
        replaceMatches(in: text, pattern: #"</?(?:abbr|b|br|cite|code|del|details|div|em|i|img|kbd|mark|small|span|strong|sub|summary|sup|u)(?:\s+[^<>]*)?/?>"#) { match, source in
            protector.protect(HTMLSafety.sanitizeTag(protector.restore(in: matchText(match, in: source))))
        }
    }

    /// Footnote references `[^id]`. Runs after code/HTML protection so footnote
    /// syntax inside inline code is never matched, and only ids that have a
    /// collected definition become links — others fall through as literal text.
    /// Rebuilds left-to-right so duplicate reference anchors follow reading order;
    /// each produced anchor is protected so HTML-escaping leaves it intact.
    private func applyFootnoteReferences(_ text: String, protector: InlineProtector, footnotes: FootnoteContext?) -> String {
        guard let footnotes, footnotes.hasDefinitions,
              let regex = try? NSRegularExpression(pattern: #"\[\^([^\]\s]+)\]"#) else {
            return text
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: range)
        var rebuilt = ""
        var cursor = text.startIndex

        for match in matches {
            guard let matchRange = Range(match.range, in: text) else { continue }
            rebuilt += text[cursor..<matchRange.lowerBound]

            if let labelRange = Range(match.range(at: 1), in: text),
               let reference = footnotes.registerReference(String(text[labelRange])) {
                rebuilt += protector.protect(
                    "<sup class=\"footnote-ref\"><a id=\"\(reference.refAnchor)\" href=\"#\(reference.defAnchor)\">\(reference.number)</a></sup>"
                )
            } else {
                rebuilt += text[matchRange]
            }

            cursor = matchRange.upperBound
        }

        rebuilt += text[cursor...]
        return rebuilt
    }

    // MARK: Citations

    /// Citation pass (after footnotes, before HTML-escaping). Renders Pandoc-style
    /// `[@key]` parenthetical, `@key` in-text, `[-@key]` author-suppressed,
    /// `[@a; @b]` multiple, and `[@key, p. 42]` locator forms via `CitationContext`,
    /// protecting the produced HTML. Bare `@key` is recognized only when its key
    /// has a bibliography entry and the `@` does not follow a word character (so an
    /// email local part is never a citation).
    private func applyCitations(_ text: String, protector: InlineProtector, citations: CitationContext?) -> String {
        // Both forms (bracketed `[@…]` and bare `@key`) are matched in one pass and
        // rebuilt left-to-right — like `applyFootnoteReferences` and unlike the
        // reversed `replaceMatches` — so keys register in true first-citation order
        // (which numeric numbering and bibliography ordering depend on). Bare `@key`
        // is recognized only at a non-word boundary (not after a word char, `@`, or
        // `/`), so an email local part is never a citation.
        guard let citations,
              let regex = try? NSRegularExpression(
                pattern: #"(\[[^\[\]]*@[^\[\]]+\])|(?<![\w@/])@[A-Za-z0-9_][A-Za-z0-9_:\-]*"#
              ) else {
            return text
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: range)
        guard !matches.isEmpty else { return text }

        var rebuilt = ""
        var cursor = text.startIndex
        for match in matches {
            guard let matchRange = Range(match.range, in: text) else { continue }
            rebuilt += text[cursor..<matchRange.lowerBound]
            let whole = String(text[matchRange])

            if match.range(at: 1).location != NSNotFound {
                // Bracketed citation; the interior is `whole` without `[` and `]`.
                let inner = String(whole.dropFirst().dropLast())
                rebuilt += renderBracketedCitation(inner, citations: citations, protector: protector) ?? whole
            } else {
                // Bare in-text citation `@key`; render only when the key is known.
                let key = String(whole.dropFirst())
                if citations.register(key) {
                    let item = CitationItem(key: key, suppressAuthor: false, locator: nil)
                    rebuilt += protector.protect("<span class=\"citation\">\(escapeHTML(citations.renderInText(item)))</span>")
                } else {
                    rebuilt += whole
                }
            }
            cursor = matchRange.upperBound
        }
        rebuilt += text[cursor...]
        return rebuilt
    }

    /// Renders the interior of a bracketed citation. Returns nil when the interior
    /// does not parse as citation items (so the `[…]` is left literal); raw key
    /// text when no item matches a bibliography entry (graceful fallback); or a
    /// protected, formatted citation span otherwise.
    private func renderBracketedCitation(_ inner: String, citations: CitationContext, protector: InlineProtector) -> String? {
        let items = parseCitationItems(inner)
        guard !items.isEmpty else { return nil }

        let known = items.contains { citations.entries[$0.key] != nil }
        guard known else {
            // No matching entry (unknown key or no bibliography loaded): show the
            // raw key(s) as plain text, dropping the `[@ ]` syntax.
            return items.map { $0.key }.joined(separator: "; ")
        }

        for item in items where citations.entries[item.key] != nil {
            citations.register(item.key)
        }
        let display = citations.renderParenthetical(items)
        return protector.protect("<span class=\"citation\">\(escapeHTML(display))</span>")
    }

    /// Parses the interior of `[ … ]` into citation items, splitting multiple
    /// citations on `;` and reading each item's author-suppression `-`, key, and
    /// optional locator. Returns an empty array when nothing parses.
    private func parseCitationItems(_ inner: String) -> [CitationItem] {
        inner.split(separator: ";").map(String.init).compactMap { part -> CitationItem? in
            let segment = part.trimmingCharacters(in: .whitespaces)
            guard let match = firstMatch(in: segment, pattern: #"^(-)?@([A-Za-z0-9_][A-Za-z0-9_:.\-]*)(?:,\s*(.+))?$"#),
                  let key = capture(match, 2, in: segment) else {
                return nil
            }
            let suppress = match.range(at: 1).location != NSNotFound
            let locator = capture(match, 3, in: segment)
            return CitationItem(key: key, suppressAuthor: suppress, locator: locator)
        }
    }

    /// The bibliography section, emitted when at least one citation was rendered
    /// against a loaded bibliography. Entries are ordered by `CitationContext`
    /// (alphabetical for author-year, citation order for numeric); a numbered
    /// style uses an `<ol>` so the list markers match the `[n]` citations.
    private func bibliographySectionHTML(_ citations: CitationContext) -> String? {
        guard citations.hasCitations, citations.hasBibliography else { return nil }
        let entries = citations.bibliographyEntries()
        guard !entries.isEmpty else { return nil }

        let listTag = citations.style == .numeric ? "ol" : "ul"
        let items = entries.map { entry in
            "<li id=\"bib-\(escapeAttribute(entry.key))\">\(formatBibliographyEntry(entry, citations: citations))</li>"
        }.joined(separator: "\n")

        return """
        <section class="bibliography">
        <\(listTag) class="bibliography-list">
        \(items)
        </\(listTag)>
        </section>
        """
    }

    /// Formats one bibliography entry: authors, year, italic title, then the
    /// container (journal/booktitle) and publisher when present. All fields are
    /// HTML-escaped; an entry with no usable fields falls back to its key.
    private func formatBibliographyEntry(_ entry: BibEntry, citations: CitationContext) -> String {
        var parts: [String] = []
        let authors = citations.fullAuthorList(entry)
        if !authors.isEmpty { parts.append(escapeHTML(authors)) }
        if let year = entry.year { parts.append("(\(escapeHTML(year)))") }
        if let title = entry.title { parts.append("<em>\(escapeHTML(title))</em>") }
        if let journal = entry.journal {
            parts.append(escapeHTML(journal))
        } else if let booktitle = entry.booktitle {
            parts.append("In \(escapeHTML(booktitle))")
        }
        if let publisher = entry.publisher { parts.append(escapeHTML(publisher)) }
        return parts.isEmpty ? escapeHTML(entry.key) : parts.joined(separator: ". ") + "."
    }

    // MARK: Cross-references

    /// Cross-reference pass (after citations, before HTML-escaping). Resolves
    /// `\ref{label}` to the referenced element's number via `CrossReferenceContext`,
    /// emitting a protected anchor; an undefined label is left literal.
    private func applyCrossReferences(_ text: String, protector: InlineProtector, crossReferences: CrossReferenceContext?) -> String {
        guard let crossReferences, crossReferences.hasLabels else { return text }
        return replaceMatches(in: text, pattern: #"\\ref\{([^}]+)\}"#) { match, source in
            guard let label = capture(match, 1, in: source),
                  let number = crossReferences.number(for: label) else {
                return matchText(match, in: source)
            }
            return protector.protect("<a class=\"cross-ref\" href=\"#\(escapeAttribute(label))\">\(escapeHTML(number))</a>")
        }
    }

    /// Whole-document pre-scan that assigns figure/table/equation numbers and
    /// registers labels, so a `\ref{}` that appears before its target resolves.
    /// Walks the same block structure as the render walk (skipping code and
    /// consuming math/table blocks), then `resetCounters()` rewinds so the render
    /// walk re-derives identical numbers as it emits each element.
    private func collectCrossReferenceLabels(_ lines: [String], into context: CrossReferenceContext, config: RenderConfig) {
        var index = 0
        while index < lines.count {
            if index == 0, lines[index].trimmedMarkdownLine == "---",
               let frontMatter = frontMatterBlock(from: lines, startIndex: index) {
                index = frontMatter.nextIndex
                continue
            }
            if let fence = fencedCodeBlock(from: lines, startIndex: index) {
                index = fence.nextIndex
                continue
            }
            if let code = indentedCodeBlock(from: lines, startIndex: index) {
                index = code.nextIndex
                continue
            }
            if let math = mathBlockContent(from: lines, startIndex: index) {
                let info = equationLabelTag(in: math.tex)
                context.assignEquation(label: info.label, tag: info.tag)
                index = math.nextIndex
                continue
            }
            if let table = tableBlock(from: lines, startIndex: index) {
                for line in lines[index..<min(table.nextIndex, lines.count)] {
                    for label in figureLabels(in: line) { context.assignFigure(label: label) }
                }
                var next = table.nextIndex
                if next < lines.count, let caption = parseTableCaption(lines[next]) {
                    context.assignTable(label: caption.label)
                    next += 1
                }
                index = next
                continue
            }
            for label in figureLabels(in: lines[index]) {
                context.assignFigure(label: label)
            }
            index += 1
        }
    }

    /// A line that is solely a labeled figure image renders as a block-level
    /// `<figure>` (rather than wrapped in a `<p>`); the inline pass produces the
    /// figure markup with its numbered caption.
    private func figureBlock(from lines: [String], startIndex: Int, context: InlineContext) -> (html: String, nextIndex: Int)? {
        let trimmed = lines[startIndex].trimmedMarkdownLine
        guard firstMatch(in: trimmed, pattern: #"^!\[[^\]]*\]\(\S+?(?:\s+&quot;.+?&quot;)?\)\{[^}]*#fig:[^}]*\}$"#) != nil
            || firstMatch(in: trimmed, pattern: #"^!\[[^\]]*\]\([^)]*\)\{[^}]*#fig:[^}]*\}$"#) != nil else {
            return nil
        }
        return (inlineHTML(trimmed, context: context), startIndex + 1)
    }

    /// Extracts every `#fig:label` id from the images on a line, in order, for the
    /// label pre-scan.
    private func figureLabels(in line: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"!\[[^\]]*\]\([^)]*\)\{([^}]*)\}"#) else {
            return []
        }
        return MarkdownLinkSyntax.candidateRanges(in: line, includeImageMarker: true).compactMap { regex.firstMatch(in: line, options: .anchored, range: $0) }.compactMap { match in
            guard let attributes = capture(match, 1, in: line) else { return nil }
            return figureLabel(in: attributes)
        }
    }

    /// The `fig:…` id inside an image attribute block, e.g. `#fig:flow` → `fig:flow`.
    private func figureLabel(in attributes: String) -> String? {
        firstCapture(in: attributes, pattern: #"#(fig:[A-Za-z0-9_.\-]+)"#)
    }

    /// Parses a Pandoc-style table caption line `: caption {#tbl:label}`,
    /// returning the caption text and label.
    private func parseTableCaption(_ line: String) -> (caption: String, label: String)? {
        guard let match = firstMatch(in: line, pattern: #"^\s*:\s+(.+?)\s*\{#(tbl:[A-Za-z0-9_.\-]+)\}\s*$"#),
              let caption = capture(match, 1, in: line),
              let label = capture(match, 2, in: line) else {
            return nil
        }
        return (caption, label)
    }

    /// Injects an id and a numbered `<caption>` into a rendered table so it is
    /// labeled and cross-referenceable.
    private func tableWithCaption(_ tableHTML: String, number: String, caption: String, label: String, context: InlineContext) -> String {
        let renderedCaption = inlineHTML(caption, context: context)
        let captionTag = "<caption class=\"tbl-caption\">Table \(number): \(renderedCaption)</caption>"
        let opening = "<table>"
        guard tableHTML.hasPrefix(opening) else { return tableHTML }
        return "<table id=\"\(escapeAttribute(label))\">\n\(captionTag)" + tableHTML.dropFirst(opening.count)
    }

    /// Bold/italic/strikethrough in precedence order (triple before double before
    /// single, for both `*` and `_`, plus `~~`). Runs on already-escaped text.
    private func renderEmphasis(_ text: String) -> String {
        var text = text

        text = replaceMatches(in: text, pattern: #"\*\*\*(.+?)\*\*\*"#) { match, source in
            guard let range = Range(match.range(at: 1), in: source) else { return matchText(match, in: source) }
            return "<strong><em>\(source[range])</em></strong>"
        }

        text = replaceMatches(in: text, pattern: #"___(.+?)___"#) { match, source in
            guard let range = Range(match.range(at: 1), in: source) else { return matchText(match, in: source) }
            return "<strong><em>\(source[range])</em></strong>"
        }

        text = replaceMatches(in: text, pattern: #"~~(.+?)~~"#) { match, source in
            guard let range = Range(match.range(at: 1), in: source) else { return matchText(match, in: source) }
            return "<del>\(source[range])</del>"
        }

        text = replaceMatches(in: text, pattern: #"\*\*(.+?)\*\*"#) { match, source in
            guard let range = Range(match.range(at: 1), in: source) else { return matchText(match, in: source) }
            return "<strong>\(source[range])</strong>"
        }

        text = replaceMatches(in: text, pattern: #"__(.+?)__"#) { match, source in
            guard let range = Range(match.range(at: 1), in: source) else { return matchText(match, in: source) }
            return "<strong>\(source[range])</strong>"
        }

        text = replaceMatches(in: text, pattern: #"(?<!\*)\*(?!\s)(.+?)(?<!\s)\*(?!\*)"#) { match, source in
            guard let range = Range(match.range(at: 1), in: source) else { return matchText(match, in: source) }
            return "<em>\(source[range])</em>"
        }

        text = replaceMatches(in: text, pattern: #"(?<!_)_(?!\s)(.+?)(?<!\s)_(?!_)"#) { match, source in
            guard let range = Range(match.range(at: 1), in: source) else { return matchText(match, in: source) }
            return "<em>\(source[range])</em>"
        }

        return text
    }

    /// Inline images `![alt](src "title")`, optionally followed by a Pandoc-style
    /// attribute block `{width=480}` / `{width=320 height=180}` / `{#fig:label}`.
    /// Explicit sizes win over dimensions inferred from the URL; both-dimension
    /// sizes reserve layout space through `.image-frame`. An image carrying a
    /// `#fig:label` id becomes a numbered, captioned `<figure>`.
    private func renderImages(_ text: String, context: InlineContext? = nil, protector: InlineProtector) -> String {
        var figureNumbers: [Int: String] = [:]
        return replaceMatches(
            in: text,
            pattern: #"!\[([^\]]*)\]\((\S+?)(?:\s+&quot;(.+?)&quot;)?\)(?:\{([^}]*)\})?"#,
            linkCandidates: true,
            prepare: { match, source in
                guard let context,
                      match.range(at: 4).location != NSNotFound,
                      let attrRange = Range(match.range(at: 4), in: source),
                      let label = self.figureLabel(in: String(source[attrRange])) else { return }
                figureNumbers[match.range.location] = context.crossReferences.assignFigure(label: label)
            }
        ) { match, source in
            guard let altRange = Range(match.range(at: 1), in: source),
                  let srcRange = Range(match.range(at: 2), in: source) else {
                return matchText(match, in: source)
            }

            let alt = String(source[altRange])
            let src = String(source[srcRange])
            guard HTMLSafety.isSafeURL(protector.restore(in: src)) else { return alt }

            let title: String
            if match.range(at: 3).location != NSNotFound, let titleRange = Range(match.range(at: 3), in: source) {
                title = " title=\"\(source[titleRange])\""
            } else {
                title = ""
            }

            // An optional `{…}` block immediately after the image. A block that
            // names width/height or a `#fig:` id is consumed; any other `{…}` is
            // preserved as literal text so unrelated braces after an image survive.
            var explicit: (width: Int?, height: Int?) = (nil, nil)
            var figLabel: String?
            var trailing = ""
            if match.range(at: 4).location != NSNotFound, let attrRange = Range(match.range(at: 4), in: source) {
                let attrText = String(source[attrRange])
                figLabel = self.figureLabel(in: attrText)
                if self.looksLikeSizeAttributes(attrText) {
                    explicit = self.parseSizeAttributes(attrText)
                }
                if figLabel == nil, !self.looksLikeSizeAttributes(attrText) {
                    trailing = "{\(attrText)}"
                }
            }

            func img(_ extra: String) -> String {
                "<img src=\"\(src)\" alt=\"\(alt)\"\(title)\(extra)>"
            }

            // The image element, sized from explicit attributes or the URL.
            let imageHTML: String
            if let width = explicit.width, let height = explicit.height {
                imageHTML = self.imageFrame(width: width, height: height, image: img(" width=\"\(width)\" height=\"\(height)\""))
            } else if let width = explicit.width {
                // Width only: the base `img` CSS keeps `height: auto`, so the
                // intrinsic aspect ratio is preserved and the image is not stretched.
                imageHTML = img(" width=\"\(width)\"")
            } else if let height = explicit.height {
                // Height only is rare and the base `height: auto` would override a
                // bare attribute, so pin it through an inline style instead.
                imageHTML = img(" style=\"height:\(height)px;\"")
            } else if let dimensions = self.imageDimensions(from: src) {
                imageHTML = self.imageFrame(
                    width: dimensions.width,
                    height: dimensions.height,
                    image: img(" width=\"\(dimensions.width)\" height=\"\(dimensions.height)\"")
                )
            } else {
                imageHTML = img("")
            }

            // A `#fig:label` (with an active context to number it) becomes a
            // captioned, numbered figure; the caption renders simple inline markup
            // while the image attributes stay inert plain text.
            if let figLabel, let context {
                let number = figureNumbers[match.range.location]
                    ?? context.crossReferences.assignFigure(label: figLabel)
                let caption = self.renderEscapedInlineContent(alt, protector: protector)
                return protector.protect("<figure class=\"figure\" id=\"\(self.escapeAttribute(figLabel))\">"
                    + imageHTML
                    + "<figcaption class=\"fig-caption\">Figure \(number): \(caption)</figcaption></figure>")
            }

            return protector.protect(imageHTML) + trailing
        }
    }

    /// Wraps a sized image in the layout-reserving frame: the span fixes the
    /// width and aspect ratio so the browser holds space before the image loads.
    private func imageFrame(width: Int, height: Int, image: String) -> String {
        "<span class=\"image-frame\" style=\"width: \(width)px; aspect-ratio: \(width) / \(height);\">\(image)</span>"
    }

    /// Whether a trailing `{…}` block names an image size attribute (`width=` or
    /// `height=`). Only such blocks are consumed as size specs.
    private func looksLikeSizeAttributes(_ attributes: String) -> Bool {
        firstMatch(in: attributes, pattern: #"(?i)(?:^|[\s,;])(?:width|height)\s*="#) != nil
    }

    /// Parses numeric `width`/`height` pixel values from a size block. Non-numeric
    /// or out-of-range values yield `nil` for that dimension, so an invalid
    /// attribute is ignored while the base image still renders.
    private func parseSizeAttributes(_ attributes: String) -> (width: Int?, height: Int?) {
        (width: sizeValue(named: "width", in: attributes),
         height: sizeValue(named: "height", in: attributes))
    }

    private func sizeValue(named name: String, in attributes: String) -> Int? {
        guard let match = firstMatch(in: attributes, pattern: "(?i)\\b\(name)\\s*=\\s*(\\d{1,5})\\b"),
              let range = Range(match.range(at: 1), in: attributes),
              let value = Int(attributes[range]),
              (1...10000).contains(value) else {
            return nil
        }
        return value
    }

    /// Inline links `[label](href "title")`. Angle-bracket destinations may
    /// contain spaces (`[label](<local path>)`); the brackets delimit the
    /// destination and are not part of the resulting href. Links whose scheme
    /// could execute script are dropped, keeping the label as inert text.
    private func renderLinks(_ text: String, protector: InlineProtector, features: InlineFeatures = .init()) -> String {
        replaceMatches(
            in: text,
            pattern: #"\[([^\]]+)\]\((?:&lt;(.+?)&gt;|(\S+?))(?:\s+&quot;(.+?)&quot;)?\)"#,
            linkCandidates: true
        ) { match, source in
            guard let labelRange = Range(match.range(at: 1), in: source) else {
                return matchText(match, in: source)
            }

            // Drop links whose scheme could execute script (javascript:, etc.),
            // keeping the visible label as inert text so the content survives.
            let hrefRange = match.range(at: 2).location != NSNotFound
                ? match.range(at: 2)
                : match.range(at: 3)
            guard let hrefRange = Range(hrefRange, in: source) else {
                return matchText(match, in: source)
            }
            let href = String(source[hrefRange])
            guard HTMLSafety.isSafeURL(protector.restore(in: href)) else {
                return String(source[labelRange])
            }

            let title: String
            if match.range(at: 4).location != NSNotFound, let titleRange = Range(match.range(at: 4), in: source) {
                title = " title=\"\(source[titleRange])\""
            } else {
                title = ""
            }

            let label = self.renderEscapedInlineContent(renderOptionalInline(String(source[labelRange]), features: features), protector: protector)
            return protector.protect("<a href=\"\(href)\"\(title)>\(label)</a>")
        }
    }

    /// Renders the small inline subset used inside link labels and figure captions.
    /// Input has already passed through `escapeHTML`, so generated links can be
    /// protected before emphasis runs and their `href` attributes stay untouched.
    private func renderEscapedInlineContent(_ text: String, protector: InlineProtector) -> String {
        renderEmphasis(renderLinks(text, protector: protector))
    }

    /// Reference links `[label][key]` / `[label][]` / `[label]`. This pass rebuilds
    /// manually rather than through ``replaceMatches``: it pairs brackets once and
    /// walks left-to-right so definition lookup, image handling, and the
    /// not-a-link fallback can share one cursor.
    private func renderReferenceLinks(_ text: String, context: InlineContext?, protector: InlineProtector) -> String {
        guard let context, !context.references.isEmpty else { return text }
        // Pair brackets once, including nested link text, instead of repeatedly
        // rescanning an unfinished run of opening brackets.
        var stack: [String.Index] = []
        var closes: [String.Index: String.Index] = [:]
        for index in text.indices {
            if text[index] == "[" { stack.append(index) }
            if text[index] == "]", let start = stack.popLast() { closes[start] = index }
        }
        var result = ""
        var cursor = text.startIndex
        while cursor < text.endIndex {
            let image = text[cursor] == "!" && text.index(after: cursor) < text.endIndex && text[text.index(after: cursor)] == "["
            let opening = image ? text.index(after: cursor) : cursor
            guard text[opening] == "[", let close = closes[opening] else {
                result.append(text[cursor]); cursor = text.index(after: cursor); continue
            }
            let label = String(text[text.index(after: opening)..<close])
            var key = label
            var end = text.index(after: close)
            if end < text.endIndex, text[end] == "[", let keyEnd = closes[end] {
                let explicit = String(text[text.index(after: end)..<keyEnd])
                key = explicit.isEmpty ? label : explicit
                end = text.index(after: keyEnd)
            }
            let originalKey = protector.source(in: key)
            let originalLabel = protector.source(in: label)
            guard !LinkReference.isReserved(originalLabel), !LinkReference.isReserved(originalKey),
                  HTMLSafety.decodeEntities(originalKey).unicodeScalars.count <= 999,
                  let reference = context.references[LinkReference.normalize(originalKey)],
                  !protector.restore(in: label).contains("<a ") else {
                result.append(text[cursor]); cursor = text.index(after: cursor); continue
            }
            let title = reference.title.map { " title=\"\(escapeAttribute($0))\"" } ?? ""
            let content = renderEmphasis(renderOptionalInline(label, features: context.config.inlineFeatures))
            // Restore the definition destination before the safety check: an
            // authored token in the definition must not reach href/src as
            // renderer markup.
            let destination = protector.restore(in: reference.destination)
            if !HTMLSafety.isSafeURL(destination) {
                result += protector.protect(image ? escapeHTML(HTMLSafety.decodeEntities(originalLabel)) : content)
            } else if image {
                let alt = HTMLSafety.decodeEntities(protector.restore(in: label))
                    .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                result += protector.protect("<img src=\"\(escapeAttribute(destination))\" alt=\"\(escapeAttribute(alt))\"\(title)>")
            } else {
                result += protector.protect("<a href=\"\(escapeAttribute(destination))\"\(title)>\(content)</a>")
            }
            cursor = end
        }
        return result
    }

    private func renderOptionalInline(_ source: String, features: InlineFeatures) -> String {
        var text = source
        let patterns: [(Bool, String, String)] = [
            (features.highlight, #"(?<!=)==(?![=\s])(.+?)(?<![=\s])==(?!=)"#, "mark"),
            (features.superscript, #"(?<!\^)\^(?![\^\s])((?:\\ |[^\s^])+?)\^(?!\^)"#, "sup"),
            (features.subscriptEnabled, #"(?<!~)~(?![~\s])((?:\\ |[^\s~])+?)~(?!~)"#, "sub")
        ]
        for (enabled, pattern, tag) in patterns where enabled {
            text = replaceMatches(in: text, pattern: pattern) { match, source in
                guard let range = Range(match.range(at: 1), in: source) else { return matchText(match, in: source) }
                let content = String(source[range]).replacingOccurrences(of: "\\ ", with: " ")
                return "<\(tag)>\(content)</\(tag)>"
            }
        }
        return text
    }

    /// Characters that are valid left boundaries for a bare URL; most also
    /// terminate its body (see `bareURLBodyTerminators`). CJK/typographic
    /// punctuation (including full-width forms) and the zero-width space U+200B,
    /// which ICU does not treat as `\s`. The set contains no ASCII characters,
    /// so it is safe inside a regex class. Module-internal so
    /// `boundaryConstantMatchesSampleTable` can compare it; not public API.
    static let bareURLBoundaryCharacters: String = {
        let characters =
            "·–—‘’‚‛“”…、。〃〈〉《》「」『』【】〔〕〖〗〘〙〚〛〜〝〞〟〰〽・"
            + "！＂＃＄％＆＇（）＊＋，－．／：；＜＝＞？＠［＼］＾＿｀｛｜｝～｟｠｡｢｣､･"
            + "\u{200B}"
        precondition(
            characters.unicodeScalars.allSatisfy { !$0.isASCII },
            "bare URL boundary characters must be non-ASCII and regex-class safe"
        )
        return characters
    }()

    /// Full-width structural lookalikes are valid left boundaries but must not
    /// terminate the URL body: ending `https://evil.com．trusted.com` at `．`
    /// would link `evil.com` while the text reads like a longer host. `－` and
    /// `＿` fold to host-valid `-`/`_`, so they stay body content too.
    static let bareURLStructuralLookalikes = "．／＃＠？－＿"

    /// The URL-body terminators: the full boundary set minus the structural
    /// lookalikes above. The left-boundary lookbehind still uses the full set.
    static let bareURLBodyTerminators: String = {
        let lookalikes = Set(bareURLStructuralLookalikes)
        return String(bareURLBoundaryCharacters.filter { !lookalikes.contains($0) })
    }()

    /// IDNA dot equivalents browsers fold into `.` when resolving a host.
    static let idnaDots: Set<Character> = ["。", "．", "｡"]

    /// Full-width ASCII folds to its ASCII counterpart by this offset.
    private static let fullwidthASCIIDelta: UInt32 = 0xFEE0
    private static let fullwidthASCIIRange: ClosedRange<UInt32> = 0xFF01...0xFF5E
    private static let percentEncodedDot = "2e"

    /// Blank-rendering code points that are not format characters or marks.
    private static let blankRenderingFillers: Set<UInt32> = [
        0x115F, // HANGUL CHOSEONG FILLER
        0x1160, // HANGUL JUNGSEONG FILLER
        0x3164, // HANGUL FILLER
        0xFFA0, // HALFWIDTH HANGUL FILLER
        0x2800  // BRAILLE PATTERN BLANK
    ]

    /// Invisible in the rendered text: Unicode format/control (and stray
    /// combining) scalars, default-ignorable scalars, plus the blank-rendering
    /// fillers above.
    private static func isInvisibleContinuationScalar(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.properties.isDefaultIgnorableCodePoint { return true }
        switch scalar.properties.generalCategory {
        case .format, .control, .nonspacingMark, .enclosingMark: return true
        default: break
        }
        return blankRenderingFillers.contains(scalar.value)
    }

    private static func normalizeContinuation(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        if idnaDots.contains(Character(scalar)) { return "." }
        if fullwidthASCIIRange.contains(scalar.value),
           let normalized = Unicode.Scalar(scalar.value - fullwidthASCIIDelta) {
            return normalized
        }
        return scalar
    }

    /// True when `text` contains a dot followed by a host-label character.
    private static func hasDotBeforeHostLabel(_ text: Substring) -> Bool {
        var previous: Character?
        for character in text {
            if previous == ".", character.isLetter || character.isNumber || character == "-" || character == "_" {
                return true
            }
            previous = character
        }
        return false
    }

    /// Appends the browser-visible form of `text` to `result`; returns false
    /// when a delimiter ends the authority. Markdown emphasis/strikethrough/
    /// highlight/sup/sub delimiters are markup, not visible authority text;
    /// fullwidth delimiters fold before the check.
    private static func appendVisibleContinuation(_ text: String, to result: inout [Unicode.Scalar]) -> Bool {
        for scalar in text.unicodeScalars {
            if scalar.properties.isWhitespace || scalar == "/" || scalar == "?" || scalar == "#" { return false }
            if isInvisibleContinuationScalar(scalar) { continue }
            let normalized = normalizeContinuation(scalar)
            if "*_~=^".unicodeScalars.contains(normalized) { continue }
            result.append(normalized)
        }
        return true
    }

    /// The visible continuation text a single authority check needs (a host is
    /// at most 253 characters; the window covers a few sentences of prose) and
    /// a hard source-iteration cap for hostile padding. Reaching either cap
    /// before a delimiter fails closed.
    private static let continuationVisibleBudget = 1_024
    private static let continuationSourceBudget = 2_048

    private struct VisibleContinuation {
        var scalars: [Unicode.Scalar]
        var exhausted: Bool
        var text: String { String(String.UnicodeScalarView(scalars)) }
    }

    private static let imageAltRegex = try! NSRegularExpression(pattern: #"<img\b[^>]*\balt="([^"]*)"[^>]*>"#)
    /// Quote-aware tag tokenizer: a tag with quoted attributes is one token.
    private static let tagRegex = try! NSRegularExpression(
        pattern: #"<!--[\s\S]*?-->|<[^>"']*(?:"[^"]*"[^>"']*|'[^']*'[^>"']*)*>"#
    )
    private static let tagNameRegex = try! NSRegularExpression(pattern: #"^</?([A-Za-z][A-Za-z0-9]*)"#)
    private static let blockTagNames: Set<String> = [
        "br", "hr", "p", "div", "li", "ul", "ol", "blockquote", "pre", "table", "tr",
        "section", "figure", "figcaption", "h1", "h2", "h3", "h4", "h5", "h6"
    ]
    private static let namedEntitySpelling = try! NSRegularExpression(pattern: #"&[A-Za-z][A-Za-z0-9]+;"#)
    private static let mathSpanRegex = try! NSRegularExpression(
        pattern: #"<span class="math math-(?:inline|display)">([\s\S]*?)</span>"#
    )

    /// Walks the text after the URL, restoring protected tokens, stripping
    /// inline HTML, decoding entities/escapes, and skipping invisible
    /// characters, so the guard sees what a browser sees. Tags are stripped
    /// before entities are decoded: an entity-encoded `>` inside an attribute
    /// must not become a tag boundary. Both budgets fail closed.
    private func visibleContinuation(after start: String.Index, in text: String, protector: InlineProtector) -> VisibleContinuation {
        var result: [Unicode.Scalar] = []
        var index = start
        var sourceBudget = Self.continuationSourceBudget
        while index < text.endIndex {
            let character = text[index]
            let scalarCount = character.unicodeScalars.count
            if scalarCount > sourceBudget {
                return VisibleContinuation(scalars: result, exhausted: true)
            }
            sourceBudget -= scalarCount
            // A sentinel joined into a larger grapheme (a prepend character
            // before the opening sentinel) cannot be scanned as a token; fail
            // closed rather than read the placeholder as visible text.
            if character != InlineProtector.sentinelCharacter,
               character.unicodeScalars.contains(InlineProtector.sentinelScalar) {
                return VisibleContinuation(scalars: result, exhausted: true)
            }
            if character == InlineProtector.sentinelCharacter,
               let token = InlineProtector.tokenRegex.firstMatch(in: text, options: .anchored, range: NSRange(index..<text.endIndex, in: text)) {
                // A token range that is not Character-aligned cannot be
                // inspected; leave the candidate literal rather than link
                // unchecked.
                guard let tokenRange = Range(token.range, in: text) else {
                    return VisibleContinuation(scalars: result, exhausted: true)
                }
                // Restored fragments are HTML (code spans, links, entity
                // spellings). Substitute image alt text in place (a broken
                // image shows it), strip remaining tags, then decode entities
                // once in document order.
                let raw = protector.restore(in: String(text[tokenRange]))
                // A protected fragment's expanded text can be much larger than
                // its placeholder; charge it to the source budget before any
                // regex or decode work.
                let fragmentLength = raw.unicodeScalars.count
                if fragmentLength > sourceBudget {
                    return VisibleContinuation(scalars: result, exhausted: true)
                }
                sourceBudget -= fragmentLength
                // Inline math is typeset by KaTeX; its source text is not a
                // faithful visible model (control sequences, grouping braces
                // and ignored whitespace can all change the rendered text).
                // Fail closed for any math span in the continuation.
                if Self.mathSpanRegex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)) != nil {
                    return VisibleContinuation(scalars: result, exhausted: true)
                }
                // A block-level or void HTML boundary starts a new visible
                // line. Process the visible prefix before it; text after it
                // is not part of the authority.
                var fragment = Self.imageAltRegex.stringByReplacingMatches(
                    in: raw,
                    range: NSRange(raw.startIndex..., in: raw),
                    withTemplate: "$1"
                )
                var hitBlockBoundary = false
                for tag in Self.tagRegex.matches(in: fragment, range: NSRange(fragment.startIndex..., in: fragment)) {
                    guard let tagRange = Range(tag.range, in: fragment) else {
                        return VisibleContinuation(scalars: result, exhausted: true)
                    }
                    let tagText = String(fragment[tagRange])
                    guard let nameMatch = Self.tagNameRegex.firstMatch(
                        in: tagText,
                        range: NSRange(tagText.startIndex..., in: tagText)
                    ), let nameRange = Range(nameMatch.range(at: 1), in: tagText) else { continue }
                    if Self.blockTagNames.contains(tagText[nameRange].lowercased()) {
                        fragment = String(fragment[..<tagRange.lowerBound])
                        hitBlockBoundary = true
                        break
                    }
                }
                let stripped = Self.tagRegex.stringByReplacingMatches(
                    in: fragment,
                    range: NSRange(fragment.startIndex..., in: fragment),
                    withTemplate: ""
                )
                // A missing entity table would silently leave named spellings
                // opaque: fail closed instead.
                if !HTMLSafety.hasNamedEntityTable,
                   Self.namedEntitySpelling.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)) != nil {
                    return VisibleContinuation(scalars: result, exhausted: true)
                }
                let visibleText = HTMLSafety.decodeAllEntities(stripped)
                guard Self.appendVisibleContinuation(visibleText, to: &result) else {
                    return VisibleContinuation(scalars: result, exhausted: false)
                }
                if result.count > Self.continuationVisibleBudget {
                    return VisibleContinuation(scalars: result, exhausted: true)
                }
                if hitBlockBoundary {
                    return VisibleContinuation(scalars: result, exhausted: false)
                }
                index = tokenRange.upperBound
                continue
            }
            index = text.index(after: index)
            guard Self.appendVisibleContinuation(String(character), to: &result) else {
                return VisibleContinuation(scalars: result, exhausted: false)
            }
            if result.count > Self.continuationVisibleBudget {
                return VisibleContinuation(scalars: result, exhausted: true)
            }
        }
        return VisibleContinuation(scalars: result, exhausted: false)
    }

    /// Runs after explicit links/images and protected code/math. Tokens for
    /// escaped punctuation/entities can be part of a URL; structural tokens
    /// terminate it so links never consume neighbouring code or another link.
    private func protectBareAutolinks(_ text: String, protector: InlineProtector) -> String {
        let pattern = #"(?<![^\s*_~(\p{sc=Han}\#(Self.bareURLBoundaryCharacters)])(?:https?://|www\.)[^\s<>\#(Self.bareURLBodyTerminators)]+|(?<![\w.+\-])[-A-Za-z0-9_+.]+@[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)+"#
        return replaceMatches(in: text, pattern: pattern) { match, source in
            let candidate = matchText(match, in: source)
            var prefix = candidate
            var suffix = ""
            var firstNonLiteralToken: Range<String.Index>?
            for token in InlineProtector.tokenRegex.matches(in: candidate, range: NSRange(candidate.startIndex..., in: candidate)) {
                guard let numberRange = Range(token.range(at: 1), in: candidate),
                      let number = Int(candidate[numberRange]), !protector.isLiteral(number),
                      let range = Range(token.range, in: candidate) else { continue }
                prefix = String(candidate[..<range.lowerBound])
                suffix = String(candidate[range.lowerBound...])
                firstNonLiteralToken = range
                break
            }
            // source() retains authored entity spellings for the trailing-entity
            // rule; decodeEntities removes the renderer's outer escaping only.
            var url = HTMLSafety.decodeEntities(protector.source(in: prefix))
            var trailing = ""
            let isURL = url.hasPrefix("http://") || url.hasPrefix("https://") || url.hasPrefix("www.")
            if isURL {
                if let angle = url.firstIndex(of: "<") {
                    trailing = String(url[angle...])
                    url = String(url[..<angle])
                }
                var excessClosers = url.filter { $0 == ")" }.count - url.filter { $0 == "(" }.count
                while let last = url.last {
                    if "?!.,:*_~".contains(last) || (last == ")" && excessClosers > 0) {
                        if last == ")" { excessClosers -= 1 }
                        trailing.insert(url.removeLast(), at: trailing.startIndex)
                    } else if last == ";", let range = url.range(of: #"&[A-Za-z0-9]+;$"#, options: .regularExpression) {
                        trailing = String(url[range]) + trailing
                        url.removeSubrange(range)
                    } else { break }
                }
                let domainStart = url.range(of: "://")?.upperBound ?? url.startIndex
                let domain = url[domainStart...].prefix { $0 != "/" && $0 != "?" && $0 != "#" && $0 != ":" }
                let parts = domain.split(separator: ".", omittingEmptySubsequences: false)
                guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" } }),
                      parts.suffix(2).allSatisfy({ !$0.contains("_") }) else { return candidate }
                // Only guard when the authority ends the URL. A path, query or
                // fragment keeps the host fixed; a port is part of the authority.
                let authorityAtEnd = !url[domainStart...].contains { $0 == "/" || $0 == "?" || $0 == "#" }
                if authorityAtEnd {
                    // A non-Character-aligned match range cannot be inspected;
                    // leave the candidate literal rather than link unchecked.
                    guard let matchRange = Range(match.range, in: source) else { return candidate }
                    // A non-literal token (code span, math, link/image) was cut
                    // from the URL. Its rendered text is visible, so read the
                    // continuation from the token's source start; starting
                    // after it hides a fused authority.
                    let start = firstNonLiteralToken.map { tokenRange in
                        source.index(
                            matchRange.lowerBound,
                            offsetBy: candidate.distance(from: candidate.startIndex, to: tokenRange.lowerBound)
                        )
                    } ?? matchRange.upperBound
                    let tail = visibleContinuation(after: start, in: source, protector: protector)
                    // A scan that hit its budget before a delimiter is unknown;
                    // fail closed rather than link the shorter host.
                    if tail.exhausted { return candidate }
                    var visible: [Unicode.Scalar] = []
                    // Punctuation stripped from the URL tail is still visible
                    // before the token (`https://evil.com.`x``).
                    if Self.appendVisibleContinuation(trailing, to: &visible) {
                        visible.append(contentsOf: tail.scalars)
                    }
                    let visibleText = String(String.UnicodeScalarView(visible))
                    // The walk already stops at ASCII `/`, `?`, `#` and
                    // whitespace, so the whole visible string is the authority
                    // continuation. Fullwidth delimiters stay in it: a browser
                    // does not end the authority at them.
                    if visibleText.contains("@") { return candidate }
                    // A continuation that starts with a host-label character
                    // extends the final label: `evil.co` + invisible + `m`
                    // reads as `evil.com` while the anchor is `evil.co`.
                    if let first = visibleText.first,
                       first.isLetter || first.isNumber || first == "-" || first == "_" {
                        return candidate
                    }
                    // Check the encoded-dot prefix before folding replaces it.
                    if visibleText.first == "%",
                       visibleText.dropFirst().prefix(2).lowercased() == Self.percentEncodedDot {
                        return candidate
                    }
                    let folded = visibleText.replacingOccurrences(
                        of: "%2e",
                        with: ".",
                        options: .caseInsensitive
                    )
                    // Punctuation the guard stripped from the URL tail is still
                    // visible before the token; skip it so the dot/label rules
                    // see the host-shaped part.
                    let hostVisible = folded.drop {
                        !($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".")
                    }
                    // One or more IDNA dots followed by a host label fuses
                    // the visible continuation into a different authority.
                    let afterDots = hostVisible.drop { $0 == "." }
                    if afterDots.count < hostVisible.count {
                        // A further dot after the label is a longer authority
                        // even when the label is non-ASCII (IDNA folds it).
                        let label = afterDots.prefix { $0 != "." }
                        if label.count < afterDots.count { return candidate }
                        if let next = afterDots.first,
                           next.isASCII,
                           next.isLetter || next.isNumber || next == "-" || next == "_" {
                            return candidate
                        }
                    }
                    // Text that starts like a host label and contains a dot
                    // followed by a label also extends the authority past the
                    // anchor (`x。trusted.com` reads as `evil.comx.trusted.com`).
                    // A bare word with no such dot (`<em>end</em>`, or prose
                    // ending in a sentence-final dot) stays ordinary.
                    if let next = hostVisible.first,
                       next.isLetter || next.isNumber,
                       Self.hasDotBeforeHostLabel(hostVisible) {
                        return candidate
                    }
                }
            } else {
                guard let last = url.last, last.isLetter || last.isNumber else { return candidate }
            }
            let destination = isURL ? (url.hasPrefix("www.") ? "http://" + url : url) : "mailto:" + url
            return protector.protect("<a href=\"\(escapeAttribute(HTMLSafety.decodeEntities(destination)))\">\(escapeHTML(HTMLSafety.decodeEntities(url)))</a>")
                + escapeHTML(trailing) + suffix
        }
    }

    /// Infers image dimensions from common placeholder/CDN URL segments such as
    /// `200x100` or `image-1200x800.png`, allowing the browser to reserve space
    /// before a remote image succeeds or fails.
    private func imageDimensions(from escapedURL: String) -> (width: Int, height: Int)? {
        guard let match = firstMatch(
            in: escapedURL,
            pattern: #"(?i)(?:^|[\/._-])(\d{2,5})x(\d{2,5})(?:[\/._?#&-]|$)"#
        ),
              let widthRange = Range(match.range(at: 1), in: escapedURL),
              let heightRange = Range(match.range(at: 2), in: escapedURL),
              let width = Int(escapedURL[widthRange]),
              let height = Int(escapedURL[heightRange]),
              (1...10000).contains(width),
              (1...10000).contains(height) else {
            return nil
        }

        return (width, height)
    }

    /// Serializes math macros to a JSON object literal for KaTeX's `macros`
    /// option. JSON's `\\`-escaping yields the single backslashes KaTeX expects;
    /// `<`/`>` are unicode-escaped so a macro value can never break out of the
    /// surrounding `<script>`. An empty or unencodable map yields `{}`.
    private func serializeMathMacros(_ macros: [String: String]) -> String {
        guard !macros.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: macros, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
            .replacingOccurrences(of: "<", with: "\\u003c")
            .replacingOccurrences(of: ">", with: "\\u003e")
    }

    private func htmlDocument(body: String, config: RenderConfig, assetMode: RenderAssetMode) -> String {
        """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        \(assetMode.mathStylesheet)
        <style>
        :root {
            color-scheme: light dark;
            --text: light-dark(#1f2328, #f3f4f6);
            --muted: light-dark(#6b7280, #a1a1aa);
            --border: light-dark(#d8dee4, #3f3f46);
            --code-bg: light-dark(#f6f8fa, #27272a);
            --quote-bg: light-dark(#fbfbfc, #202024);
            --accent: light-dark(#2563eb, #60a5fa);
            --page: light-dark(#ffffff, #18181b);
        }

        html {
            background: var(--page);
        }

        body {
            margin: 0;
            color: var(--text);
            background: var(--page);
            font: 16px/1.68 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif;
        }

        main {
            box-sizing: border-box;
            width: 100%;
            max-width: 1280px;
            margin: 0 auto;
            padding: 52px clamp(28px, 4vw, 64px) 80px;
        }

        h1, h2, h3, h4, h5, h6 {
            line-height: 1.25;
            margin: 1.35em 0 0.55em;
            letter-spacing: 0;
        }

        h1 {
            font-size: 2.15rem;
            border-bottom: 1px solid var(--border);
            padding-bottom: 0.28em;
        }

        h2 {
            font-size: 1.58rem;
            border-bottom: 1px solid var(--border);
            padding-bottom: 0.22em;
        }

        h3 { font-size: 1.24rem; }
        h4 { font-size: 1.08rem; }
        h5, h6 { font-size: 1rem; color: var(--muted); }

        p, ul, ol, blockquote, pre, table {
            margin: 0.85em 0;
        }

        a {
            color: var(--accent);
            text-decoration: none;
        }

        a:hover {
            text-decoration: underline;
        }

        code {
            background: var(--code-bg);
            border-radius: 5px;
            font-family: "SF Mono", Menlo, Consolas, monospace;
            font-size: 0.9em;
            padding: 0.12em 0.34em;
        }

        pre {
            background: var(--code-bg);
            border-radius: 8px;
            overflow-x: auto;
            padding: 16px 18px;
        }

        pre code {
            display: block;
            background: transparent;
            border-radius: 0;
            padding: 0;
            white-space: pre;
        }

        .tok-keyword { color: light-dark(#9d174d, #f472b6); font-weight: 650; }
        .tok-type { color: light-dark(#0f766e, #5eead4); font-weight: 600; }
        .tok-string { color: light-dark(#166534, #86efac); }
        .tok-number { color: light-dark(#7c3aed, #c4b5fd); }
        .tok-comment { color: var(--muted); font-style: italic; }
        .tok-function { color: light-dark(#1d4ed8, #93c5fd); }

        blockquote {
            color: var(--muted);
            background: var(--quote-bg);
            border-left: 4px solid var(--border);
            padding: 0.45em 1em;
            /* Quotes soft-wrap to the pane width instead of running off as one
               long line with a horizontal scrollbar. `overflow-wrap: anywhere`
               also breaks long unbreakable tokens (paths/URLs). Fenced code
               blocks are unaffected: `pre code` is `white-space: pre`, which
               ignores these properties and keeps its own horizontal scroll. */
            overflow-wrap: anywhere;
            word-break: break-word;
        }

        /* Long inline code in a quote (e.g. `openspec/specs/plugin-load-safety`)
           wraps rather than forcing the quote to scroll horizontally. */
        blockquote code {
            overflow-wrap: anywhere;
            word-break: break-word;
        }

        .markdown-alert {
            margin: 0 0 1em;
            padding: 0.6em 1em;
            border-left: 4px solid var(--alert-color);
            background: var(--quote-bg);
            color: var(--text);
            overflow-wrap: anywhere;
        }
        .markdown-alert-note { --alert-color: light-dark(#0969da, #58a6ff); }
        .markdown-alert-tip { --alert-color: light-dark(#1a7f37, #3fb950); }
        .markdown-alert-important { --alert-color: light-dark(#8250df, #ab7df8); }
        .markdown-alert-warning { --alert-color: light-dark(#9a6700, #d29922); }
        .markdown-alert-caution { --alert-color: light-dark(#cf222e, #f85149); }
        .markdown-alert > .markdown-alert-title {
            color: var(--alert-color);
            font-weight: 650;
            margin: 0 0 0.4em;
            break-after: avoid;
        }
        .markdown-alert > :last-child { margin-bottom: 0; }
        mark {
            color: inherit;
            background: light-dark(#fff1a8, #665215);
            padding: 0.05em 0.12em;
            border-radius: 2px;
        }
        @media print {
            .markdown-alert { background: #fff; color: #1f2328; }
            .markdown-alert-note { --alert-color: #0969da; }
            .markdown-alert-tip { --alert-color: #1a7f37; }
            .markdown-alert-important { --alert-color: #8250df; }
            .markdown-alert-warning { --alert-color: #9a6700; }
            .markdown-alert-caution { --alert-color: #cf222e; }
            mark { color: #1f2328; background: #fff1a8; print-color-adjust: exact; -webkit-print-color-adjust: exact; }
        }

        table {
            width: 100%;
            border-collapse: collapse;
            display: block;
            overflow-x: auto;
        }

        th, td {
            border: 1px solid var(--border);
            padding: 8px 10px;
            text-align: left;
        }

        th {
            background: var(--code-bg);
            font-weight: 650;
        }

        img {
            display: block;
            max-width: 100%;
            height: auto;
            margin: 1.1em auto;
        }

        .image-frame {
            display: block;
            max-width: 100%;
            margin: 1.1em auto;
        }

        .image-frame img {
            width: 100%;
            height: 100%;
            object-fit: contain;
            margin: 0;
        }

        hr {
            border: 0;
            border-top: 1px solid var(--border);
            margin: 2em 0;
        }

        .front-matter {
            color: var(--muted);
        }

        .toc {
            border: 1px solid var(--border);
            border-radius: 8px;
            padding: 14px 16px;
            margin: 1em 0 1.4em;
        }

        .toc a {
            display: block;
            line-height: 1.8;
        }

        .toc-level-2 { padding-left: 16px; }
        .toc-level-3 { padding-left: 32px; }
        .toc-level-4 { padding-left: 48px; }
        .toc-level-5 { padding-left: 64px; }
        .toc-level-6 { padding-left: 80px; }

        .task-list {
            list-style: none;
            padding-left: 0;
        }

        li > .task-list {
            padding-left: 1.6em;
        }

        .task-list input {
            margin-right: 0.45em;
            cursor: pointer;
        }

        /* Typeset math inherits the preview foreground color for light/dark legibility. */
        .katex { color: var(--text); }
        .math-display {
            overflow-x: auto;
            overflow-y: hidden;
            margin: 1em 0;
            text-align: center;
        }
        .math-error {
            color: light-dark(#b91c1c, #f87171);
            font-family: "SF Mono", Menlo, Consolas, monospace;
            font-size: 0.9em;
        }

        /* Rendered diagrams are centered SVG, with horizontal scroll for wide ones. */
        .diagram {
            margin: 1.1em 0;
            text-align: center;
            overflow-x: auto;
            opacity: 1;
            transition: opacity 120ms ease-in;
        }
        .diagram svg {
            max-width: 100%;
            height: auto;
        }
        /* Keep diagram text/connectors legible against the preview background.
           Scoped away from Mermaid: it ships its own light/dark theme and colors
           some geometry (e.g. xychart-beta plot lines/bars) via SVG presentation
           attributes — forcing var(--text) here and reverting it back would
           resolve those strokes to the SVG initial `none`, blanking the series. */
        .diagram:not(.diagram-mermaid) text {
            fill: var(--text);
        }
        .diagram:not(.diagram-mermaid) path,
        .diagram:not(.diagram-mermaid) line,
        .diagram:not(.diagram-mermaid) rect,
        .diagram:not(.diagram-mermaid) ellipse,
        .diagram:not(.diagram-mermaid) polygon {
            stroke: var(--text);
        }
        /* While its engine has not rendered yet, a diagram hides its raw source
           (collapsed + transparent) so it never flashes as visible code, and
           reserves a little height to dampen the jump to the final SVG. */
        .diagram-pending {
            opacity: 0;
            font-size: 0;
            min-height: 2.5rem;
            overflow: hidden;
        }
        /* Once rendered (or failed), the diagram fades gently into view. */
        .diagram-ready {
            opacity: 1;
        }
        /* On parse failure the raw source is shown instead of a blank diagram. */
        .diagram-error {
            display: block;
            text-align: left;
            white-space: pre-wrap;
            color: light-dark(#b91c1c, #f87171);
            font-family: "SF Mono", Menlo, Consolas, monospace;
            font-size: 0.9em;
        }

        /* Footnote references render as a small superscript link; the footnotes
           section sits below the body, separated by a quiet rule, inheriting the
           preview foreground/link colors for light & dark legibility. */
        sup.footnote-ref {
            font-size: 0.75em;
            line-height: 0;
            white-space: nowrap;
        }
        sup.footnote-ref a {
            text-decoration: none;
        }
        section.footnotes {
            margin-top: 2.4em;
            padding-top: 1em;
            border-top: 1px solid var(--border);
            color: var(--muted);
            font-size: 0.9em;
        }
        section.footnotes ol {
            padding-left: 1.4em;
        }
        section.footnotes li {
            margin: 0.4em 0;
        }
        .footnote-backref {
            margin-left: 0.35em;
            text-decoration: none;
            font-size: 0.92em;
        }

        /* Inline citations inherit the body color; the bibliography sits below the
           document like the footnotes section, separated by a quiet rule. */
        .citation {
            white-space: nowrap;
        }
        .cross-ref {
            color: var(--accent);
            text-decoration: none;
        }
        section.bibliography {
            margin-top: 2.4em;
            padding-top: 1em;
            border-top: 1px solid var(--border);
            font-size: 0.92em;
        }
        .bibliography-list {
            padding-left: 1.6em;
        }
        ul.bibliography-list {
            list-style: none;
            padding-left: 0;
        }
        .bibliography-list li {
            margin: 0.5em 0;
            /* Hanging indent for author-year entries reads like a reference list. */
            padding-left: 1.6em;
            text-indent: -1.6em;
        }
        ol.bibliography-list li {
            padding-left: 0;
            text-indent: 0;
        }

        /* An auto-numbered display equation: the equation stays centered while its
           `(n)` is pushed to the right edge via flexbox. */
        .numbered-equation {
            display: flex;
            align-items: center;
            gap: 0.5em;
            margin: 1em 0;
        }
        .numbered-equation .math-display {
            flex: 1 1 auto;
            margin: 0;
        }
        .numbered-equation .eq-number {
            flex: 0 0 auto;
            color: var(--muted);
            font-variant-numeric: tabular-nums;
        }

        /* Numbered figures and table captions inherit the muted caption color. */
        figure.figure {
            margin: 1.1em 0;
            text-align: center;
        }
        figure.figure img,
        figure.figure .image-frame {
            margin: 0 auto;
        }
        .fig-caption,
        .tbl-caption {
            margin-top: 0.5em;
            color: var(--muted);
            font-size: 0.92em;
            text-align: center;
            caption-side: bottom;
        }

        @media (max-width: 720px) {
            main {
                padding: 32px 24px 60px;
            }
        }
        </style>
        </head>
        <body>
        <main>
        \(body)
        </main>
        \(assetMode.script(.katex))
        \(assetMode.script(.mhchem))
        <script>
        // Predefined macros from the math-macros front-matter field. The active
        // macro object is shared across render calls so that, with globalGroup
        // enabled, newcommand/def declared in one block persist into later blocks.
        window.__md2InitialMacros = \(serializeMathMacros(config.mathMacros));
        window.__md2MathMacros = JSON.parse(JSON.stringify(window.__md2InitialMacros));
        // Exposed as a re-runnable function (scoped to a root element) so the
        // live-preview content swap can re-render math over freshly injected
        // content without reloading the page. Called once over the whole
        // document at load.
        window.__md2RenderMath = function (root) {
            if (typeof katex === "undefined") { return; }
            root = root || document;
            // Re-seed from the front-matter macros so each whole-document render
            // (initial load or live content swap) starts fresh — globalGroup state
            // accumulated from a prior edit's blocks must not linger.
            window.__md2MathMacros = JSON.parse(JSON.stringify(window.__md2InitialMacros));
            var nodes = root.querySelectorAll(".\(PreviewClass.mathInline), .\(PreviewClass.mathDisplay)");
            for (var i = 0; i < nodes.length; i++) {
                var el = nodes[i];
                var tex = el.textContent;
                var display = el.classList.contains("\(PreviewClass.mathDisplay)");
                try {
                    katex.render(tex, el, {
                        displayMode: display,
                        throwOnError: false,
                        globalGroup: true,
                        macros: window.__md2MathMacros
                    });
                } catch (err) {
                    el.classList.add("\(PreviewClass.mathError)");
                    el.textContent = tex;
                }
            }
        };
        window.__md2RenderMath(document);
        </script>
        \(diagramScripts(for: body, assetMode: assetMode))
        </body>
        </html>
        """
    }

    /// Builds the diagram engine `<script>` tags and render bootstrap, but only
    /// for the diagram types the document actually uses. Documents without any
    /// diagrams pay nothing — notably the large Mermaid bundle is never loaded
    /// unless a `mermaid` block is present. Shared dependencies are emitted once,
    /// in dependency order, before the engines that consume them.
    private func diagramScripts(for body: String, assetMode: RenderAssetMode) -> String {
        let hasMermaid = body.contains(PreviewClass.diagramMermaid)
        let hasFlow = body.contains(PreviewClass.diagramFlow)
        let hasSequence = body.contains(PreviewClass.diagramSequence)

        guard hasMermaid || hasFlow || hasSequence else { return "" }

        var scripts: [String] = []
        func include(_ asset: BundledWebAsset) {
            scripts.append(assetMode.script(asset))
        }

        // Underscore + Raphael are shared dependencies; emit each once, first.
        if hasSequence {
            include(.underscore)
        }
        if hasFlow || hasSequence {
            include(.raphael)
        }
        if hasFlow {
            include(.flowchart)
        }
        if hasSequence {
            include(.sequence)
        }
        if hasMermaid {
            include(.mermaid)
        }

        scripts.append("<script>\n\(diagramBootstrap)\n</script>")
        return scripts.joined(separator: "\n")
    }

    /// Client-side bootstrap that renders each diagram placeholder via its
    /// engine. Each render is isolated in `try/catch` so one malformed diagram
    /// cannot blank the rest of the document; on failure the raw source is shown.
    /// Kept independent from the math bootstrap. Engine guards (`typeof …`) make
    /// it safe to run even when an engine script was not loaded.
    private let diagramBootstrap = """
    // Exposed as a re-runnable function (scoped to a root element) so the
    // live-preview content swap can re-render diagrams over freshly injected
    // content without reloading the page. Called once over the whole document
    // at load. Engine guards (`typeof …`) keep it safe when an engine script
    // was not loaded (e.g. a diagram type added after the initial load).
    // Mermaid sizes each node to its label's full un-wrapped width. Long plain
    // labels — especially CJK, which has no spaces to break on and which
    // Mermaid's `flowchart.wrappingWidth` never wraps — balloon a diagram's
    // natural width, so a PDF export scales it down until the text is
    // unreadable. Wrap long plain-text labels before render (Mermaid renders
    // `<br/>` as a line break) so the diagram lays out at a bounded width.
    function wrapLongLabels(source) {
        var LABEL_MIN = 15;   // wrap only when the label exceeds this many code points
        var LABEL_LINE = 15;  // break each display line at roughly this many code points
        // Characters that mark a label as not plain text: HTML/markup, edge
        // labels, markdown emphasis, or a fancier node shape (brackets inside
        // the label). A label containing any of these is left untouched.
        var FORBIDDEN = '<>|&"`*_(){}[]';
        function isPlain(label) {
            if (label.charAt(0) === "/") { return false; }  // parallelogram [/.../]
            for (var i = 0; i < label.length; i++) {
                if (FORBIDDEN.indexOf(label.charAt(i)) !== -1) { return false; }
            }
            return true;
        }
        function wrapText(label) {
            var chars = Array.from(label);
            var out = "";
            var i = 0;
            while (i < chars.length) {
                var end = i + LABEL_LINE;
                var cut = end;
                if (end < chars.length) {
                    // Latin: break at the last space before the limit. CJK has
                    // no spaces, so fall through and break between characters.
                    for (var j = end - 1; j > i; j--) {
                        if (chars[j] === " ") { cut = j + 1; break; }
                    }
                }
                out += chars.slice(i, cut).join("");
                i = cut;
                while (i < chars.length && chars[i] === " ") { i++; }
                if (i < chars.length) { out += "<br/>"; }
            }
            return out;
        }
        function wrap(match, id, label, open, close) {
            if (!isPlain(label) || Array.from(label).length <= LABEL_MIN) { return match; }
            return id + open + wrapText(label) + close;
        }
        var s = source;
        s = s.replace(/([A-Za-z0-9_][A-Za-z0-9_-]*)[[]([^\\]]+)]/g, function (m, id, label) { return wrap(m, id, label, "[", "]"); });
        s = s.replace(/([A-Za-z0-9_][A-Za-z0-9_-]*)[(]([^)]+)[)]/g, function (m, id, label) { return wrap(m, id, label, "(", ")"); });
        s = s.replace(/([A-Za-z0-9_][A-Za-z0-9_-]*)[{]([^}]+)[}]/g, function (m, id, label) { return wrap(m, id, label, "{", "}"); });
        return s;
    }

    window.__md2RenderDiagrams = function (root) {
        root = root || document;
        window.__md2MermaidSeq = window.__md2MermaidSeq || 0;
        // Offscreen PDF export/print snapshots this page and must wait for
        // asynchronous diagram rendering (Mermaid) to finish first; otherwise the
        // capture races ahead and the diagram comes out blank. Track the number of
        // outstanding async renders and expose a settled flag the exporter polls.
        // Synchronous engines (flow/sequence) and KaTeX math are already done by
        // the load event, so only Mermaid contributes to the pending count.
        if (typeof window.__md2DiagramPending !== "number") { window.__md2DiagramPending = 0; }
        window.__md2DiagramsSettled = false;
        function settleOne() {
            window.__md2DiagramPending = Math.max(0, window.__md2DiagramPending - 1);
            if (window.__md2DiagramPending === 0) { window.__md2DiagramsSettled = true; }
        }
        var dark = window.matchMedia
            && window.matchMedia("(prefers-color-scheme: dark)").matches;

        // Drop the source-hiding pending state and fade the diagram in. Called
        // once an engine has populated the element, on the error/fallback path,
        // and when an engine is unavailable — so a block is never left blank.
        function reveal(el) {
            el.classList.remove("\(PreviewClass.diagramPending)");
            el.classList.add("\(PreviewClass.diagramReady)");
        }

        function fail(el, source) {
            el.classList.add("\(PreviewClass.diagramError)");
            el.textContent = source;
            reveal(el);
        }

        // flowchart.js — depends on the global `flowchart` (+ Raphael).
        var flows = root.querySelectorAll(".\(PreviewClass.diagramFlow)");
        for (var i = 0; i < flows.length; i++) {
            var el = flows[i];
            var source = el.textContent;
            if (typeof flowchart === "undefined") { reveal(el); continue; }
            try {
                el.textContent = "";
                flowchart.parse(source).drawSVG(el);
                reveal(el);
            } catch (err) {
                fail(el, source);
            }
        }

        // js-sequence-diagrams — depends on the global `Diagram` (+ Underscore, Raphael).
        var seqs = root.querySelectorAll(".\(PreviewClass.diagramSequence)");
        for (var j = 0; j < seqs.length; j++) {
            var sel = seqs[j];
            var ssource = sel.textContent;
            if (typeof Diagram === "undefined") { reveal(sel); continue; }
            try {
                sel.textContent = "";
                Diagram.parse(ssource).drawSVG(sel, { theme: "simple" });
                reveal(sel);
            } catch (err) {
                fail(sel, ssource);
            }
        }

        // Mermaid — self-contained; render explicitly (startOnLoad disabled).
        var mers = root.querySelectorAll(".\(PreviewClass.diagramMermaid)");
        if (typeof mermaid === "undefined") {
            for (var u = 0; u < mers.length; u++) { reveal(mers[u]); }
        } else if (mers.length) {
            try {
                mermaid.initialize({
                    startOnLoad: false,
                    theme: dark ? "dark" : "default",
                    securityLevel: "loose"
                });
            } catch (err) {}
            for (var k = 0; k < mers.length; k++) {
                (function (el, idx) {
                    var source = wrapLongLabels(el.textContent);
                    window.__md2DiagramPending++;
                    try {
                        mermaid.render("md2-mermaid-" + idx, source).then(function (result) {
                            el.innerHTML = result.svg;
                            reveal(el);
                        }).catch(function () {
                            fail(el, source);
                        }).then(settleOne, settleOne);
                    } catch (err) {
                        fail(el, source);
                        settleOne();
                    }
                })(mers[k], window.__md2MermaidSeq++);
            }
        }

        // Every synchronous engine has run and each asynchronous Mermaid render has
        // been scheduled (bumping the pending count). If nothing is outstanding the
        // pass is settled now; otherwise settleOne() flips the flag once the last
        // render resolves or fails.
        if (window.__md2DiagramPending === 0) { window.__md2DiagramsSettled = true; }
    };
    window.__md2RenderDiagrams(document);
    """

    /// Applies `transform` to every match and returns the rebuilt string.
    ///
    /// Transforms are evaluated in descending match order, preserving the call
    /// order of stateful transforms, and the transformed strings are then
    /// assembled forward in one pass. A `prepare` closure runs once over all
    /// matches in ascending document order before the transforms; use it for
    /// state that must follow source order (figure numbering).
    /// Transforms MUST read only their own match and capture groups; they must
    /// not depend on replacements produced for other matches. `protectAutolinks`
    /// consults the preceding text only through the destination index built from
    /// this original source, and `renderImages` pre-assigns figures in
    /// `prepare` and reads them by label.
    private func replaceMatches(
        in source: String,
        pattern: String,
        linkCandidates: Bool = false,
        prepare: ((NSTextCheckingResult, String) -> Void)? = nil,
        transform: (NSTextCheckingResult, String) -> String
    ) -> String {
        guard let regex = MarkdownRegex.expression(pattern) else {
            return source
        }

        let nsRange = NSRange(source.startIndex..<source.endIndex, in: source)
        let matches = linkCandidates
            ? MarkdownLinkSyntax.candidateRanges(in: source, includeImageMarker: pattern.hasPrefix("!")).compactMap {
                regex.firstMatch(in: source, options: .anchored, range: $0)
            }
            : regex.matches(in: source, range: nsRange)
        guard !matches.isEmpty else { return source }

        if let prepare {
            for match in matches {
                prepare(match, source)
            }
        }

        var replacements = [String](repeating: "", count: matches.count)
        for (offset, match) in matches.enumerated().reversed() {
            replacements[offset] = transform(match, source)
        }

        var result = ""
        result.reserveCapacity(source.utf8.count)
        var cursor = source.startIndex

        for (offset, match) in matches.enumerated() {
            guard let range = Range(match.range, in: source),
                  range.lowerBound >= cursor else { continue }
            result.append(contentsOf: source[cursor..<range.lowerBound])
            result.append(replacements[offset])
            cursor = range.upperBound
        }
        result.append(contentsOf: source[cursor...])

        return result
    }

    private func firstMatch(in source: String, pattern: String) -> NSTextCheckingResult? {
        guard let regex = MarkdownRegex.expression(pattern) else {
            return nil
        }

        return regex.firstMatch(
            in: source,
            range: NSRange(source.startIndex..<source.endIndex, in: source)
        )
    }

    private func matchText(_ match: NSTextCheckingResult, in source: String) -> String {
        guard let range = Range(match.range, in: source) else { return "" }
        return String(source[range])
    }

    /// The string for a capture group, or nil when the group did not participate.
    private func capture(_ match: NSTextCheckingResult, _ index: Int, in source: String) -> String? {
        let nsRange = match.range(at: index)
        guard nsRange.location != NSNotFound, let range = Range(nsRange, in: source) else { return nil }
        return String(source[range])
    }

    /// The first capture group of the first match of `pattern` in `source`, if any.
    private func firstCapture(in source: String, pattern: String) -> String? {
        guard let match = firstMatch(in: source, pattern: pattern) else { return nil }
        return capture(match, 1, in: source)
    }

    private func escapeHTML(_ source: String) -> String {
        HTMLEscaping.escape(source)
    }

    private func escapeAttribute(_ source: String) -> String {
        HTMLEscaping.escapeAttribute(source)
    }
}

/// Bundles the document-wide inline state threaded through block rendering into
/// the inline pipeline: footnotes, citations, and cross-references. Carrying one
/// value keeps the block-builder signatures stable as inline features are added.
private struct InlineContext {
    let footnotes: FootnoteContext
    let citations: CitationContext
    let crossReferences: CrossReferenceContext
    var references: [String: LinkReference] = [:]
    var config: RenderConfig = .init()
}

/// A fenced code-block info string that should render as a diagram rather than
/// as code. The raw case value is the lower-cased Markdown info string.
private enum DiagramKind: String {
    case mermaid
    case flow
    case sequence

    init?(infoString: String) {
        let normalized = infoString.trimmingCharacters(in: .whitespaces).lowercased()
        self.init(rawValue: normalized)
    }

    var cssClass: String {
        switch self {
        case .mermaid:
            return PreviewClass.diagramMermaid
        case .flow:
            return PreviewClass.diagramFlow
        case .sequence:
            return PreviewClass.diagramSequence
        }
    }
}

/// A precomputed view of inline link and image destinations (`](…`) for one
/// inline pass (autolinks or paren math). Each opener records the position just
/// after its `(` and the first unescaped, depth-zero `)` after it (or `nil`
/// when unterminated). A lookup binary-searches the opener at or before a
/// position and reports whether that position lies before the matching close,
/// which is exactly the old nearest-opener, forward-depth scan without its
/// per-match prefix walk.
///
/// The index is built in one left-to-right pass: paren balance is tracked
/// globally (escaped characters skipped), and every unescaped `)` is recorded
/// under the balance level it leaves behind. An opener whose balance just after
/// its `(` is `B` closes at the first later `)` recorded at level `B - 1`.
/// An opener is recorded for a raw `](` even when the `]` is backslash-escaped,
/// matching the previous backward search; the escaped character is still
/// skipped for close bookkeeping.
private struct LinkDestinationIndex {
    private struct Span {
        let start: String.Index
        let close: String.Index?
    }

    private let spans: [Span]

    init(scanning text: String) {
        // Most inline passes contain no link syntax at all; skip the character
        // walk (and its allocations) in that common case.
        guard text.contains("](") else {
            spans = []
            return
        }

        var openers: [(start: String.Index, base: Int)] = []
        var closesByBalance: [Int: [String.Index]] = [:]
        var balance = 0
        var previous: Character?
        var cursor = text.startIndex

        while cursor < text.endIndex {
            let character = text[cursor]

            if character == "\\" {
                guard let next = text.index(cursor, offsetBy: 2, limitedBy: text.endIndex) else { break }
                let escaped = text[text.index(after: cursor)]
                cursor = next
                // A raw `](` opens a destination even when its `]` is escaped;
                // the old backward search matched that spelling. Close
                // bookkeeping still skips the escaped character.
                previous = escaped == "]" ? "]" : nil
                continue
            }

            if character == "(" {
                balance += 1
                if previous == "]" {
                    openers.append((text.index(after: cursor), balance))
                }
            } else if character == ")" {
                balance -= 1
                closesByBalance[balance, default: []].append(cursor)
            }

            previous = character
            cursor = text.index(after: cursor)
        }

        spans = openers.map { opener in
            Span(
                start: opener.start,
                close: Self.firstClose(after: opener.start, at: opener.base - 1, in: closesByBalance)
            )
        }
    }

    func contains(_ index: String.Index) -> Bool {
        guard !spans.isEmpty else { return false }

        var low = 0
        var high = spans.count
        while low < high {
            let middle = (low + high) / 2
            if spans[middle].start <= index {
                low = middle + 1
            } else {
                high = middle
            }
        }
        guard low > 0 else { return false }

        let span = spans[low - 1]
        guard let close = span.close else { return true }
        return index < close
    }

    private static func firstClose(
        after start: String.Index,
        at level: Int,
        in closesByBalance: [Int: [String.Index]]
    ) -> String.Index? {
        guard let positions = closesByBalance[level] else { return nil }

        var low = 0
        var high = positions.count
        while low < high {
            let middle = (low + high) / 2
            // The old forward scan starts at `start` and checks that character,
            // so a close exactly at `start` is the matching close.
            if positions[middle] < start {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low < positions.count ? positions[low] : nil
    }
}

/// Holds the three parallel facts inline rendering swaps out for placeholder
/// tokens so they survive HTML-escaping and the later regex passes untouched:
/// the rendered `fragments`, the authored `sources` (recovered by bare-URL and
/// reference-link matching), and the indexes marked `literals` (which only
/// terminate bare-URL matching). A reference type so the ordered pipeline
/// passes share one accumulator.
///
/// `restore(in:)` and `source(in:)` share one linear resolver. Tokens have the
/// form `\u{E000}MD2-<n>\u{E000}`, and `protect` is append-only: an entry at
/// index N can only contain tokens with index < N. The resolver expands each
/// entry once against already-expanded lower indexes (the `expandedCount`
/// watermark), then scans the requested text once and replaces each token by
/// direct index lookup. Author text that merely resembles a token, malformed
/// tokens, leading-zero indexes, and out-of-range or forward references stay
/// literal.
///
/// D4 boundary: a token formed only after an escaped character is restored is
/// not re-read, and when two spellings share a sentinel the leftmost
/// well-formed token wins. The old descending per-index replacements expanded
/// the former and gave the higher index priority; the one-pass resolver keeps
/// the narrower behavior pinned by `InlineRenderingPerformanceTests`.
private final class InlineProtector {
    private var fragments: [String] = []
    private var sources: [String] = []
    private var literals: Set<Int> = []
    private var expanded: [Bool] = []

    static let sentinelScalar: Unicode.Scalar = "\u{E000}"
    /// The sentinel as a Character, for the guard's fast-path check.
    static let sentinelCharacter = Character(String(sentinelScalar))

    /// The placeholder token grammar, shared by the pass that cuts non-literal
    /// tokens and the guard that restores them. Built from the one sentinel
    /// definition so the grammar cannot drift from `protect()`.
    static let tokenPattern = "\(sentinelCharacter)MD2-(\\d+)\(sentinelCharacter)"
    static let tokenRegex = try! NSRegularExpression(pattern: tokenPattern)

    /// Stores `fragment` and returns the private-use-area token standing in for it.
    func protect(_ fragment: String, source: String? = nil, literal: Bool = false) -> String {
        let token = "\(Self.sentinelCharacter)MD2-\(fragments.count)\(Self.sentinelCharacter)"
        if literal { literals.insert(fragments.count) }
        sources.append(source ?? fragment)
        fragments.append(fragment)
        expanded.append(false)
        return token
    }

    /// Returns `text` with every source token replaced by the authored spelling.
    func source(in text: String) -> String {
        resolve(text, emitting: .source)
    }

    func isLiteral(_ index: Int) -> Bool { literals.contains(index) }

    /// Returns `text` with every fragment token replaced by its rendered HTML.
    func restore(in text: String) -> String {
        resolve(text, emitting: .fragment)
    }

    private enum Emission {
        case fragment
        case source
    }

    private func resolve(_ text: String, emitting: Emission) -> String {
        guard text.unicodeScalars.contains(Self.sentinelScalar) else { return text }
        return resolveTokens(in: text, limit: fragments.count, emitting: emitting)
    }

    /// Expands `target` and every lower entry it reaches, iteratively. Entries
    /// that no reachable text references stay unexpanded, so a discarded
    /// fragment cannot amplify memory: a crafted token DAG hidden in a
    /// discarded attribute is never materialized.
    private func ensureExpanded(_ target: Int) {
        if expanded[target] { return }
        var stack: [Int] = [target]
        while let index = stack.last {
            if expanded[index] {
                stack.removeLast()
                continue
            }
            let pending = tokenIndices(in: fragments[index], limit: index)
                + tokenIndices(in: sources[index], limit: index)
            let unexpanded = pending.filter { !expanded[$0] }
            if unexpanded.isEmpty {
                fragments[index] = resolveTokens(in: fragments[index], limit: index, emitting: .fragment)
                sources[index] = resolveTokens(in: sources[index], limit: index, emitting: .source)
                expanded[index] = true
                stack.removeLast()
            } else {
                stack.append(contentsOf: unexpanded)
            }
        }
    }

    /// One forward scan. Tokens with an index below `limit` are expanded on
    /// demand; everything else is copied literally, including malformed tokens
    /// and indexes at or above the limit. The scan uses Unicode scalars so a
    /// combining mark after the sentinel cannot hide a well-formed token.
    private func resolveTokens(in text: String, limit: Int, emitting: Emission) -> String {
        guard text.unicodeScalars.contains(Self.sentinelScalar) else { return text }

        let scalars = text.unicodeScalars
        var result = ""
        result.reserveCapacity(text.utf8.count)
        var cursor = scalars.startIndex

        while cursor < scalars.endIndex {
            guard let start = scalars[cursor...].firstIndex(of: Self.sentinelScalar) else {
                result.unicodeScalars.append(contentsOf: scalars[cursor...])
                break
            }
            result.unicodeScalars.append(contentsOf: scalars[cursor..<start])

            if let token = token(in: text, from: start), token.index < limit {
                ensureExpanded(token.index)
                result.append(entry(token.index, emitting: emitting))
                cursor = token.end
            } else {
                result.unicodeScalars.append(Self.sentinelScalar)
                cursor = scalars.index(after: start)
            }
        }
        return result
    }

    private func tokenIndices(in text: String, limit: Int) -> [Int] {
        guard text.unicodeScalars.contains(Self.sentinelScalar) else { return [] }
        let scalars = text.unicodeScalars
        var indices: [Int] = []
        var cursor = scalars.startIndex
        while cursor < scalars.endIndex {
            guard let start = scalars[cursor...].firstIndex(of: Self.sentinelScalar) else { break }
            if let token = token(in: text, from: start), token.index < limit {
                indices.append(token.index)
                cursor = token.end
            } else {
                cursor = scalars.index(after: start)
            }
        }
        return indices
    }

    private func entry(_ index: Int, emitting: Emission) -> String {
        switch emitting {
        case .fragment: return fragments[index]
        case .source: return sources[index]
        }
    }

    /// Parses `\u{E000}MD2-<canonical decimal>\u{E000}` starting at `start`.
    /// Leading zeros, overflow, and a missing closing sentinel are malformed and
    /// leave the text literal, matching the old exact-spelling replacements.
    /// Scalar-based so a following combining mark does not change the token.
    private func token(in text: String, from start: String.Index) -> (index: Int, end: String.Index)? {
        let scalars = text.unicodeScalars
        var cursor = scalars.index(after: start)
        for expected in "MD2-".unicodeScalars {
            guard cursor < scalars.endIndex, scalars[cursor] == expected else { return nil }
            cursor = scalars.index(after: cursor)
        }

        var value = 0
        var digits = 0
        var leadingZero = false
        while cursor < scalars.endIndex {
            let scalar = scalars[cursor]
            guard scalar.value >= 0x30, scalar.value <= 0x39 else { break }
            let digit = Int(scalar.value - 0x30)
            if digits == 0 { leadingZero = digit == 0 }
            if value > (Int.max - digit) / 10 { return nil }
            value = value * 10 + digit
            digits += 1
            cursor = scalars.index(after: cursor)
        }

        guard digits > 0, !(leadingZero && digits > 1),
              cursor < scalars.endIndex, scalars[cursor] == Self.sentinelScalar else { return nil }
        return (value, scalars.index(after: cursor))
    }
}

private struct ListItem {
    let kind: ListKind
    let checked: Bool?
    let text: String
    /// Raw leading-indentation width in columns (a tab counts as 4). Used to
    /// derive nesting depth when building nested lists.
    let indent: Int
    /// Column where the item's content begins (marker indent + marker width).
    /// A continuation line must reach this column to belong to the item, so a
    /// line indented past the marker but short of the content column (CommonMark
    /// example 255: `- one` then ` two`) stays a sibling paragraph.
    let contentIndent: Int
    /// Absolute 1-based source line of the item, so a task checkbox can carry
    /// the line a preview click must toggle (`data-md2-task-line`).
    let line: Int
    /// Raw index into the `lines` array the item was collected from. Lets
    /// `listBlock` map an `items` index back to a source line after blank lines
    /// between items have been absorbed into a single (loose) list.
    let lineIndex: Int
    /// Raw block-content lines indented under the item's marker (paragraphs,
    /// code blocks, tables, …), in source order and with original indentation.
    /// `buildList` dedents and renders these as the item's body so nested block
    /// content stays inside the `<li>` instead of leaking to the top-level walk.
    var continuation: [String] = []
}

private enum ListKind: Equatable {
    case unordered
    case ordered
}

private enum TableAlignment {
    case left
    case center
    case right

    var htmlAttribute: String {
        switch self {
        case .left:
            return #" style="text-align:left""#
        case .center:
            return #" style="text-align:center""#
        case .right:
            return #" style="text-align:right""#
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// Document-wide footnote state. Footnotes need shared, order-dependent
/// bookkeeping that the stateless per-block inline rendering cannot provide:
/// definitions are collected up front, references are numbered by first
/// appearance, and each reference site gets a unique anchor so the trailing
/// footnotes section can link back to every occurrence.
private final class FootnoteContext {
    /// label -> raw content lines, populated by the definition pre-scan.
    private var definitions: [String: [String]] = [:]
    /// label -> 1-based source line of the definition, for preview anchoring.
    private var definitionLines: [String: Int] = [:]
    /// Referenced labels in first-reference order; the index + 1 is the number.
    private var order: [String] = []
    /// label -> number of references seen so far (drives back-reference anchors).
    private var counts: [String: Int] = [:]
    /// label -> sanitized, document-unique anchor base, computed once.
    private var anchorBases: [String: String] = [:]
    private var usedAnchorBases: Set<String> = []

    var hasDefinitions: Bool { !definitions.isEmpty }
    var hasReferences: Bool { !order.isEmpty }
    var referencedLabels: [String] { order }

    func define(label: String, content: [String], line: Int? = nil) {
        // First definition wins, mirroring common Markdown footnote behavior.
        if definitions[label] == nil {
            definitions[label] = content
            definitionLines[label] = line
        }
    }

    func content(for label: String) -> [String]? {
        definitions[label]
    }

    func definitionLine(for label: String) -> Int? {
        definitionLines[label]
    }

    func referenceCount(for label: String) -> Int {
        counts[label, default: 0]
    }

    /// Records a reference to `label`. Returns the display number and the
    /// reference/definition anchors, or `nil` when the label has no definition
    /// (so the caller leaves the `[^id]` text literal).
    func registerReference(_ label: String) -> (number: Int, refAnchor: String, defAnchor: String)? {
        guard definitions[label] != nil else { return nil }

        let number: Int
        if let existing = order.firstIndex(of: label) {
            number = existing + 1
        } else {
            order.append(label)
            number = order.count
        }

        let occurrence = counts[label, default: 0] + 1
        counts[label] = occurrence

        let base = anchorBase(for: label)
        let refAnchor = occurrence == 1 ? "fnref-\(base)" : "fnref-\(base)-\(occurrence)"
        return (number, refAnchor, "fn-\(base)")
    }

    /// A slugified, document-unique anchor base for a label, stable across calls.
    func anchorBase(for label: String) -> String {
        if let existing = anchorBases[label] { return existing }

        var slug = ""
        var lastWasDash = false
        for scalar in label.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                slug.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash {
                slug.append("-")
                lastWasDash = true
            }
        }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let stem = slug.isEmpty ? "fn" : slug

        var candidate = stem
        var suffix = 2
        while usedAnchorBases.contains(candidate) {
            candidate = "\(stem)-\(suffix)"
            suffix += 1
        }

        usedAnchorBases.insert(candidate)
        anchorBases[label] = candidate
        return candidate
    }
}
