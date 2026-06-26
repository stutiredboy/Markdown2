import Foundation

public struct OutlineBuilder: Sendable {
    public init() {}

    public func build(from markdown: String) -> [Heading] {
        let lines = markdown.normalizedMarkdownLines
        var headings: [Heading] = []
        var usedSlugs: [String: Int] = [:]
        var activeFence: String?
        var index = leadingFrontMatterEndIndex(in: lines) ?? 0

        while index < lines.count {
            let line = lines[index]

            if let marker = MarkdownLine.fenceMarker(in: line) {
                if activeFence == marker {
                    activeFence = nil
                } else if activeFence == nil {
                    activeFence = marker
                }
                index += 1
                continue
            }

            if activeFence != nil || MarkdownLine.isIndentedCode(line) {
                index += 1
                continue
            }

            if let heading = MarkdownLine.heading(in: line) {
                appendHeading(
                    level: heading.level,
                    title: heading.title,
                    line: index + 1,
                    headings: &headings,
                    usedSlugs: &usedSlugs
                )
                index += 1
                continue
            }

            if index + 1 < lines.count,
               let level = MarkdownLine.setextHeadingLevel(in: lines[index + 1]),
               !line.trimmedMarkdownLine.isEmpty,
               !line.trimmedMarkdownLine.hasPrefix(">"),
               MarkdownLine.fenceMarker(in: line) == nil,
               !MarkdownLine.isHorizontalRule(line) {
                appendHeading(
                    level: level,
                    title: line.trimmedMarkdownLine,
                    line: index + 1,
                    headings: &headings,
                    usedSlugs: &usedSlugs
                )
                index += 2
                continue
            }

            index += 1
        }

        return headings
    }

    private func leadingFrontMatterEndIndex(in lines: [String]) -> Int? {
        guard lines.first?.trimmedMarkdownLine == "---" else { return nil }

        var index = 1
        while index < lines.count {
            if lines[index].trimmedMarkdownLine == "---" {
                return index + 1
            }
            index += 1
        }
        return nil
    }

    private func appendHeading(
        level: Int,
        title: String,
        line: Int,
        headings: inout [Heading],
        usedSlugs: inout [String: Int]
    ) {
        let id = Slugger.uniqueSlug(for: title, usedSlugs: &usedSlugs)
        headings.append(
            Heading(
                id: id,
                level: level,
                title: title,
                line: line
            )
        )
    }
}
