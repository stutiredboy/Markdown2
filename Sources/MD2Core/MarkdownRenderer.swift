import Foundation

public struct MarkdownRenderer: Sendable {
    private let outlineBuilder = OutlineBuilder()

    public init() {}

    public func render(_ markdown: String) -> RenderedDocument {
        let outline = outlineBuilder.build(from: markdown)
        let footnotes = FootnoteContext()
        collectFootnoteDefinitions(markdown.normalizedMarkdownLines, into: footnotes)
        var body = renderBody(markdown, outline: outline, footnotes: footnotes)
        if let section = footnoteSectionHTML(footnotes) {
            body += "\n" + section
        }
        let html = htmlDocument(body: body)

        return RenderedDocument(
            html: html,
            body: body,
            outline: outline,
            stats: DocumentStats(markdown: markdown)
        )
    }

    private func renderBody(
        _ markdown: String,
        outline: [Heading],
        footnotes: FootnoteContext,
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
                    footnotes: footnotes,
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

            if let math = mathBlock(from: lines, startIndex: index) {
                appendBlock(math.html, from: index, to: math.nextIndex)
                index = math.nextIndex
                continue
            }

            if trimmed == "[TOC]" {
                appendBlock(tableOfContents(outline), from: index, to: index + 1)
                index += 1
                continue
            }

            if let table = tableBlock(from: lines, startIndex: index, footnotes: footnotes) {
                appendBlock(table.html, from: index, to: table.nextIndex)
                index = table.nextIndex
                continue
            }

            if let setextHeading = setextHeadingBlock(from: lines, startIndex: index, headingsByLine: headingsByLine) {
                appendBlock(setextHeading.html, from: index, to: setextHeading.nextIndex)
                index = setextHeading.nextIndex
                continue
            }

            if let heading = MarkdownLine.heading(in: line), let outlineHeading = headingsByLine[index + 1] {
                appendBlock(
                    "<h\(heading.level) id=\"\(escapeAttribute(outlineHeading.id))\">\(inlineHTML(heading.title))</h\(heading.level)>",
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

            if let list = listBlock(from: lines, startIndex: index, footnotes: footnotes, lineOffset: lineOffset) {
                appendBlock(list.html, from: index, to: list.nextIndex)
                index = list.nextIndex
                continue
            }

            let paragraph = paragraphBlock(from: lines, startIndex: index, footnotes: footnotes)
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

    /// Detects a display math block delimited by `$$`.
    ///
    /// Handles both a single line such as `$$a^2 + b^2 = c^2$$` and a multi-line
    /// block whose opening line starts with `$$` and whose content runs until a
    /// line ending in `$$`. Returns `nil` when there is no closing `$$`, so the
    /// text falls through to normal paragraph handling.
    private func mathBlock(from lines: [String], startIndex: Int) -> (html: String, nextIndex: Int)? {
        let trimmed = lines[startIndex].trimmedMarkdownLine
        guard trimmed.hasPrefix("$$") else { return nil }

        let afterOpen = String(trimmed.dropFirst(2))

        // Single-line block: `$$ ... $$`
        if afterOpen.hasSuffix("$$"), afterOpen.count >= 2 {
            let inner = String(afterOpen.dropLast(2))
            return (mathDisplayHTML(inner), startIndex + 1)
        }

        // Multi-line block: collect lines until one ends with `$$`.
        var content: [String] = []
        if !afterOpen.isEmpty {
            content.append(afterOpen)
        }

        var index = startIndex + 1
        while index < lines.count {
            let lineTrimmed = lines[index].trimmedMarkdownLine
            if lineTrimmed.hasSuffix("$$") {
                let beforeClose = String(lineTrimmed.dropLast(2))
                if !beforeClose.isEmpty {
                    content.append(beforeClose)
                }
                return (mathDisplayHTML(content.joined(separator: "\n")), index + 1)
            }

            content.append(lines[index])
            index += 1
        }

        return nil
    }

    /// Emits a display-math wrapper carrying the raw TeX as HTML-escaped text
    /// content so the math engine can read it verbatim from the DOM.
    private func mathDisplayHTML(_ tex: String) -> String {
        "<div class=\"\(PreviewClass.math) \(PreviewClass.mathDisplay)\">\(escapeHTML(tex.trimmingCharacters(in: .whitespacesAndNewlines)))</div>"
    }

    private func setextHeadingBlock(
        from lines: [String],
        startIndex: Int,
        headingsByLine: [Int: Heading]
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
            "<h\(level) id=\"\(escapeAttribute(id))\">\(inlineHTML(title))</h\(level)>",
            startIndex + 2
        )
    }

    private func tableBlock(from lines: [String], startIndex: Int, footnotes: FootnoteContext? = nil) -> (html: String, nextIndex: Int)? {
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
                return "<th\(style)>\(inlineHTML(header.trimmingCharacters(in: .whitespaces), footnotes: footnotes))</th>"
            }
            .joined()
        let bodyHTML = rows
            .map { row in
                let cells = row.enumerated()
                    .map { index, cell in
                        let style = alignments[safe: index]?.htmlAttribute ?? ""
                        return "<td\(style)>\(inlineHTML(cell.trimmingCharacters(in: .whitespaces), footnotes: footnotes))</td>"
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
        footnotes: FootnoteContext,
        lineOffset: Int = 0
    ) -> (html: String, nextIndex: Int) {
        var quoteLines: [String] = []
        var index = startIndex

        while index < lines.count {
            let trimmed = lines[index].trimmedMarkdownLine
            guard trimmed.hasPrefix(">") else { break }

            let content = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
            quoteLines.append(String(content))
            index += 1
        }

        // Quote content lines map 1:1 to the consumed source lines, so the
        // nested render keeps absolute source-line spans by offsetting to the
        // quote's first line.
        let nestedMarkdown = quoteLines.joined(separator: "\n")
        let quote = renderBody(
            nestedMarkdown,
            outline: outlineBuilder.build(from: nestedMarkdown),
            footnotes: footnotes,
            lineOffset: lineOffset + startIndex
        )

        return ("<blockquote>\n\(quote)\n</blockquote>", index)
    }

    private func listBlock(from lines: [String], startIndex: Int, footnotes: FootnoteContext, lineOffset: Int = 0) -> (html: String, nextIndex: Int)? {
        guard parseListItem(lines[startIndex]) != nil else { return nil }

        // Collect the run of consecutive list lines; indented continuation lines
        // are included so they can become nested child lists. Each item records
        // its absolute source line (`lineOffset` keeps blockquote-nested lists
        // absolute, matching the block-level source-line spans).
        var items: [ListItem] = []
        var index = startIndex
        while index < lines.count, let item = parseListItem(lines[index], sourceLine: lineOffset + index + 1) {
            items.append(item)
            index += 1
        }

        // A tab or four spaces represents one nesting level.
        let levels = nestingLevels(for: items)

        let built = buildList(items: items, levels: levels, start: 0, level: levels[0], footnotes: footnotes)
        return (built.html, startIndex + built.next)
    }

    /// Derives each item's nesting level from indentation columns, using four
    /// columns per level and integer division for partial indentation.
    private func nestingLevels(for items: [ListItem]) -> [Int] {
        items.map { $0.indent / 4 }
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
        footnotes: FootnoteContext
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

            var content = "\(checkbox)\(inlineHTML(item.text, footnotes: footnotes))"
            index += 1

            // Attach any deeper items as nested child lists of this item.
            while index < items.count, levels[index] > level {
                let child = buildList(
                    items: items,
                    levels: levels,
                    start: index,
                    level: levels[index],
                    footnotes: footnotes
                )
                content += "\n\(child.html)"
                index = child.next
            }

            listItems.append("<li>\(content)</li>")
        }

        let className = hasTask ? " class=\"task-list\"" : ""
        return ("<\(tag)\(className)>\n\(listItems.joined(separator: "\n"))\n</\(tag)>", index)
    }

    private func paragraphBlock(from lines: [String], startIndex: Int, footnotes: FootnoteContext) -> (html: String, nextIndex: Int) {
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

        return ("<p>\(paragraphHTML(paragraphLines, footnotes: footnotes))</p>", max(index, startIndex + 1))
    }

    private func paragraphHTML(_ lines: [String], footnotes: FootnoteContext) -> String {
        lines.enumerated().map { index, line in
            let hasHardBreak = line.hasSuffix("  ") || line.hasSuffix("\\")
            let content: String

            if line.hasSuffix("\\") {
                content = String(line.dropLast()).trimmingCharacters(in: .whitespaces)
            } else {
                content = line.trimmingCharacters(in: .whitespaces)
            }

            let rendered = inlineHTML(content, footnotes: footnotes)

            // A soft line break (a newline mid-paragraph) renders as a visible
            // <br>, matching the editor's WYSIWYG expectation; only the
            // paragraph's final line — when it carries no explicit hard break —
            // omits the trailing break. Soft and hard breaks thus converge here.
            if index == lines.count - 1 && !hasHardBreak {
                return rendered
            }
            return "\(rendered)<br>"
        }.joined()
    }

    // MARK: Footnotes

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
    private func footnoteSectionHTML(_ context: FootnoteContext) -> String? {
        guard context.hasReferences else { return nil }

        let items = context.referencedLabels.map { label -> String in
            let base = context.anchorBase(for: label)
            let raw = (context.content(for: label) ?? [])
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            let rendered = inlineHTML(raw)

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
    /// 1-based line number recorded on the item; callers that only test
    /// whether a line is a list item can omit it.
    private func parseListItem(_ line: String, sourceLine: Int = 0) -> ListItem? {
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

            return ListItem(kind: .unordered, checked: checked, text: text, indent: indent, line: sourceLine)
        }

        guard let match = firstMatch(in: trimmed, pattern: #"^\d+[\.)]\s+(.+)$"#),
              let textRange = Range(match.range(at: 1), in: trimmed) else {
            return nil
        }

        return ListItem(kind: .ordered, checked: nil, text: String(trimmed[textRange]), indent: indent, line: sourceLine)
    }

    /// Counts the leading whitespace of a line in columns, treating a tab as 4
    /// columns. Used to determine list-item nesting depth.
    private func leadingIndentWidth(_ line: String) -> Int {
        var width = 0
        for character in line {
            if character == " " {
                width += 1
            } else if character == "\t" {
                width += 4
            } else {
                break
            }
        }
        return width
    }

    private func tableAlignments(in line: String) -> [TableAlignment]? {
        let cells = splitTableLine(line)
        guard !cells.isEmpty else { return nil }

        var alignments: [TableAlignment] = []

        for cell in cells {
            let trimmed = cell.trimmingCharacters(in: .whitespaces)
            guard trimmed.range(of: #"^:?-{3,}:?$"#, options: .regularExpression) != nil else {
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
    /// later passes (code, math, entities, autolinks, raw HTML, footnote anchors)
    /// are swapped for placeholder tokens up front; the text is escaped once; the
    /// emphasis/image/link passes then run on escaped text; finally the protected
    /// fragments are restored. Each pass is a named method below, so adding a new
    /// inline construct means inserting one entry at the right point in this list.
    private func inlineHTML(_ markdown: String, footnotes: FootnoteContext? = nil) -> String {
        let protector = InlineProtector()

        let pipeline: [(String) -> String] = [
            { protectCodeSpans($0, protector: protector) },
            { protectInlineMath($0, protector: protector) },
            { protectBackslashEscapes($0, protector: protector) },
            { protectHTMLEntities($0, protector: protector) },
            { protectAutolinks($0, protector: protector) },
            { protectRawHTML($0, protector: protector) },
            { applyFootnoteReferences($0, protector: protector, footnotes: footnotes) },
            { escapeHTML($0) },
            { renderEmphasis($0) },
            { renderImages($0) },
            { renderLinks($0) }
        ]

        let transformed = pipeline.reduce(markdown) { text, pass in pass(text) }
        return protector.restore(in: transformed)
    }

    /// Inline code spans `` `...` ``. The inner text is escaped and the whole span
    /// is protected so later passes never reinterpret code content.
    private func protectCodeSpans(_ text: String, protector: InlineProtector) -> String {
        replaceMatches(in: text, pattern: #"`([^`]+)`"#) { match, source in
            guard let codeRange = Range(match.range(at: 1), in: source) else {
                return matchText(match, in: source)
            }

            return protector.protect("<code>\(escapeHTML(String(source[codeRange])))</code>")
        }
    }

    /// Backslash-escaped punctuation (`\*`, `\_`, …); the escaped character is
    /// protected so it survives as a literal.
    private func protectBackslashEscapes(_ text: String, protector: InlineProtector) -> String {
        replaceMatches(in: text, pattern: ##"\\([!"#$%&'()*+,\-./:;<=>?@\[\]\\^_`{|}~])"##) { match, source in
            guard let escapedRange = Range(match.range(at: 1), in: source) else {
                return matchText(match, in: source)
            }

            return protector.protect(escapeHTML(String(source[escapedRange])))
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

    /// Pre-existing HTML entities (`&amp;`, `&#960;`, …), protected so the later
    /// `escapeHTML` pass does not double-escape the ampersand.
    private func protectHTMLEntities(_ text: String, protector: InlineProtector) -> String {
        replaceMatches(in: text, pattern: #"&(?:#\d+|#x[0-9A-Fa-f]+|[A-Za-z][A-Za-z0-9]+);"#) { match, source in
            protector.protect(matchText(match, in: source))
        }
    }

    /// Angle-bracket autolinks `<https://…>` / `<mailto:…>`, rendered to an anchor
    /// and protected.
    private func protectAutolinks(_ text: String, protector: InlineProtector) -> String {
        replaceMatches(in: text, pattern: #"<((?:https?|mailto):[^>\s]+)>"#) { match, source in
            guard let urlRange = Range(match.range(at: 1), in: source) else {
                return matchText(match, in: source)
            }

            let url = String(source[urlRange])
            return protector.protect("<a href=\"\(escapeAttribute(url))\">\(escapeHTML(url))</a>")
        }
    }

    /// A small whitelist of raw inline HTML tags, passed through verbatim (and
    /// protected) so authors can use them while everything else is escaped.
    private func protectRawHTML(_ text: String, protector: InlineProtector) -> String {
        replaceMatches(in: text, pattern: #"</?(?:abbr|b|br|cite|code|del|details|div|em|i|img|kbd|mark|small|span|strong|sub|summary|sup|u)(?:\s+[^<>]*)?/?>"#) { match, source in
            protector.protect(matchText(match, in: source))
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

    /// Inline images `![alt](src "title")`, optionally wrapped in a sized frame
    /// when the URL encodes dimensions so the browser can reserve space.
    private func renderImages(_ text: String) -> String {
        replaceMatches(in: text, pattern: #"!\[([^\]]*)\]\((\S+?)(?:\s+&quot;(.+?)&quot;)?\)"#) { match, source in
            guard let altRange = Range(match.range(at: 1), in: source),
                  let srcRange = Range(match.range(at: 2), in: source) else {
                return matchText(match, in: source)
            }

            let title: String
            if match.range(at: 3).location != NSNotFound, let titleRange = Range(match.range(at: 3), in: source) {
                title = " title=\"\(source[titleRange])\""
            } else {
                title = ""
            }

            let src = String(source[srcRange])
            let image = "<img src=\"\(src)\" alt=\"\(source[altRange])\"\(title)>"
            guard let dimensions = imageDimensions(from: src) else {
                return image
            }

            let sizedImage = "<img src=\"\(src)\" alt=\"\(source[altRange])\"\(title) width=\"\(dimensions.width)\" height=\"\(dimensions.height)\">"
            return "<span class=\"image-frame\" style=\"width: \(dimensions.width)px; aspect-ratio: \(dimensions.width) / \(dimensions.height);\">\(sizedImage)</span>"
        }
    }

    /// Inline links `[label](href "title")`. Links whose scheme could execute
    /// script are dropped, keeping the label as inert text.
    private func renderLinks(_ text: String) -> String {
        replaceMatches(in: text, pattern: #"\[([^\]]+)\]\((\S+?)(?:\s+&quot;(.+?)&quot;)?\)"#) { match, source in
            guard let labelRange = Range(match.range(at: 1), in: source),
                  let hrefRange = Range(match.range(at: 2), in: source) else {
                return matchText(match, in: source)
            }

            // Drop links whose scheme could execute script (javascript:, etc.),
            // keeping the visible label as inert text so the content survives.
            let href = String(source[hrefRange])
            guard !isDangerousLinkHref(href) else {
                return String(source[labelRange])
            }

            let title: String
            if match.range(at: 3).location != NSNotFound, let titleRange = Range(match.range(at: 3), in: source) {
                title = " title=\"\(source[titleRange])\""
            } else {
                title = ""
            }

            return "<a href=\"\(href)\"\(title)>\(source[labelRange])</a>"
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

    private func htmlDocument(body: String) -> String {
        """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        \(MathAssets.css)
        </style>
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
            width: min(100%, 860px);
            margin: 0 auto;
            padding: 52px 58px 80px;
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
        /* Keep diagram text/connectors legible against the preview background. */
        .diagram text {
            fill: var(--text);
        }
        .diagram path,
        .diagram line,
        .diagram rect,
        .diagram ellipse,
        .diagram polygon {
            stroke: var(--text);
        }
        /* Mermaid ships its own light/dark theme; let it manage its own colors. */
        .diagram-mermaid text { fill: revert; }
        .diagram-mermaid path,
        .diagram-mermaid line,
        .diagram-mermaid rect,
        .diagram-mermaid ellipse,
        .diagram-mermaid polygon { stroke: revert; }
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
        <script>
        \(MathAssets.javaScript)
        </script>
        <script>
        \(MathAssets.mhchem)
        </script>
        <script>
        // Exposed as a re-runnable function (scoped to a root element) so the
        // live-preview content swap can re-render math over freshly injected
        // content without reloading the page. Called once over the whole
        // document at load.
        window.__md2RenderMath = function (root) {
            if (typeof katex === "undefined") { return; }
            root = root || document;
            var nodes = root.querySelectorAll(".\(PreviewClass.mathInline), .\(PreviewClass.mathDisplay)");
            for (var i = 0; i < nodes.length; i++) {
                var el = nodes[i];
                var tex = el.textContent;
                var display = el.classList.contains("\(PreviewClass.mathDisplay)");
                try {
                    katex.render(tex, el, { displayMode: display, throwOnError: false });
                } catch (err) {
                    el.classList.add("\(PreviewClass.mathError)");
                    el.textContent = tex;
                }
            }
        };
        window.__md2RenderMath(document);
        </script>
        \(diagramScripts(for: body))
        </body>
        </html>
        """
    }

    /// Builds the diagram engine `<script>` tags and render bootstrap, but only
    /// for the diagram types the document actually uses. Documents without any
    /// diagrams pay nothing — notably the large Mermaid bundle is never inlined
    /// unless a `mermaid` block is present. Shared dependencies are emitted once,
    /// in dependency order, before the engines that consume them.
    private func diagramScripts(for body: String) -> String {
        let hasMermaid = body.contains(PreviewClass.diagramMermaid)
        let hasFlow = body.contains(PreviewClass.diagramFlow)
        let hasSequence = body.contains(PreviewClass.diagramSequence)

        guard hasMermaid || hasFlow || hasSequence else { return "" }

        var scripts: [String] = []
        func inline(_ js: String) {
            scripts.append("<script>\n\(js)\n</script>")
        }

        // Underscore + Raphael are shared dependencies; emit each once, first.
        if hasSequence {
            inline(DiagramAssets.underscore)
        }
        if hasFlow || hasSequence {
            inline(DiagramAssets.raphael)
        }
        if hasFlow {
            inline(DiagramAssets.flowchart)
        }
        if hasSequence {
            inline(DiagramAssets.sequence)
        }
        if hasMermaid {
            inline(DiagramAssets.mermaid)
        }

        inline(diagramBootstrap)
        return scripts.joined(separator: "\n")
    }

    /// Client-side bootstrap that renders each diagram placeholder via its
    /// engine. Each render is isolated in `try/catch` so one malformed diagram
    /// cannot blank the rest of the document; on failure the raw source is shown.
    /// Kept independent from the math bootstrap. Engine guards (`typeof …`) make
    /// it safe to run even when an engine script was not inlined.
    private let diagramBootstrap = """
    // Exposed as a re-runnable function (scoped to a root element) so the
    // live-preview content swap can re-render diagrams over freshly injected
    // content without reloading the page. Called once over the whole document
    // at load. Engine guards (`typeof …`) keep it safe when an engine script
    // was not inlined (e.g. a diagram type added after the initial load).
    window.__md2RenderDiagrams = function (root) {
        root = root || document;
        window.__md2MermaidSeq = window.__md2MermaidSeq || 0;
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
                    var source = el.textContent;
                    try {
                        mermaid.render("md2-mermaid-" + idx, source).then(function (result) {
                            el.innerHTML = result.svg;
                            reveal(el);
                        }).catch(function () {
                            fail(el, source);
                        });
                    } catch (err) {
                        fail(el, source);
                    }
                })(mers[k], window.__md2MermaidSeq++);
            }
        }
    };
    window.__md2RenderDiagrams(document);
    """

    private func replaceMatches(
        in source: String,
        pattern: String,
        transform: (NSTextCheckingResult, String) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return source
        }

        let nsRange = NSRange(source.startIndex..<source.endIndex, in: source)
        let matches = regex.matches(in: source, range: nsRange)
        var result = source

        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: transform(match, result))
        }

        return result
    }

    private func firstMatch(in source: String, pattern: String) -> NSTextCheckingResult? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
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

    /// Lowercased URL scheme prefixes that can execute script or smuggle active
    /// content; inline links using them are rendered as inert text instead of
    /// anchors. (Plain-prefix match — entity-obfuscated schemes are not
    /// normalized here; see review notes for the deeper hardening item.)
    private static let dangerousLinkSchemes = ["javascript:", "vbscript:", "data:"]

    private func isDangerousLinkHref(_ href: String) -> Bool {
        let normalized = href.trimmingCharacters(in: .whitespaces).lowercased()
        return Self.dangerousLinkSchemes.contains { normalized.hasPrefix($0) }
    }

    private func escapeHTML(_ source: String) -> String {
        HTMLEscaping.escape(source)
    }

    private func escapeAttribute(_ source: String) -> String {
        HTMLEscaping.escapeAttribute(source)
    }
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

/// Holds the fragments that inline rendering swaps out for placeholder tokens so
/// they survive HTML-escaping and the later regex passes untouched. A reference
/// type so the ordered pipeline passes can share one accumulator, then restore
/// every fragment in one final step.
private final class InlineProtector {
    private var fragments: [String] = []

    /// Stores `fragment` and returns the private-use-area token standing in for it.
    func protect(_ fragment: String) -> String {
        let token = "\u{E000}MD2-\(fragments.count)\u{E000}"
        fragments.append(fragment)
        return token
    }

    /// Replaces every protection token in `text` with its original fragment.
    /// Restores in descending index order: a fragment can only embed tokens
    /// created before it (lower index), so inserting outer fragments first lets
    /// later iterations resolve the tokens nested inside them.
    func restore(in text: String) -> String {
        var result = text
        for (index, fragment) in fragments.enumerated().reversed() {
            result = result.replacingOccurrences(of: "\u{E000}MD2-\(index)\u{E000}", with: fragment)
        }
        return result
    }
}

private struct ListItem {
    let kind: ListKind
    let checked: Bool?
    let text: String
    /// Raw leading-indentation width in columns (a tab counts as 4). Used to
    /// derive nesting depth when building nested lists.
    let indent: Int
    /// Absolute 1-based source line of the item, so a task checkbox can carry
    /// the line a preview click must toggle (`data-md2-task-line`).
    let line: Int
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
