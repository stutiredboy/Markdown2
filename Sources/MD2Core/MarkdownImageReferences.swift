import Foundation

/// A deliberately small source-editing grammar, not a second Markdown renderer.
/// Only ordinary top-level blocks without literal/container syntax are eligible.
/// Every scan is bounded and every returned range addresses the original UTF-16.
public enum MarkdownImageReferences {
    public struct Reference: Equatable, Sendable {
        public let destination: String
        public let range: NSRange
    }
    public struct Scan: Sendable {
        public var references: [Reference] = []
        fileprivate var syntaxRanges: [NSRange] = []
        public var unsupported: [String] = []
        public var excludedBlocks = 0
        public var exceededLimit = false
    }
    public static let maximumSourceUnits = 4 * 1024 * 1024
    public static let maximumCandidates = 10_000
    private static let maximumCandidateUnits = 8_192

    public static func scan(_ text: String) -> Scan {
        var result = Scan()
        guard text.utf16.count <= maximumSourceUnits else {
            result.exceededLimit = true
            return result
        }
        let source = text as NSString
        var offset = 0
        var block: [(String, Int, Bool)] = []
        var containers = ContainerExclusionState()
        var fence: MarkdownFence?
        var frontMatter = false
        var htmlUntil: String?
        var mathUntil: String?
        var environment: (open: String, close: String, depth: Int)?
        func flush() {
            guard !block.isEmpty else { return }
            defer { block.removeAll(keepingCapacity: true) }
            // A backtick/math/HTML token anywhere can protect a multiline span.
            // Container lazy continuations and definitions are excluded together.
            let uncertain = block.contains { line, _, inContainer in
                inContainer || MarkdownLine.isIndentedCode(line) || isPotentialDefinition(line) ||
                    line.contains("`") || line.contains("$") ||
                    line.contains("\\(") || line.contains("\\[") || line.contains("\\begin{")
            }
            if uncertain { result.excludedBlocks += 1; return }
            var candidates = Scan()
            for (line, base, _) in block {
                let firstSyntax = candidates.syntaxRanges.count
                scanLine(line, base: base, into: &candidates)
                if candidates.exceededLimit { result.exceededLimit = true; return }
                // Accepted image syntax (including its inert attribute payload)
                // cannot open a raw HTML block. Everything outside it still can.
                if maskingImageSyntax(line, base: base, ranges: candidates.syntaxRanges[firstSyntax...]).contains("<") {
                    result.excludedBlocks += 1; return
                }
            }
            guard result.references.count + result.unsupported.count + candidates.references.count + candidates.unsupported.count <= maximumCandidates else {
                result.exceededLimit = true; return
            }
            result.references += candidates.references
            result.unsupported += candidates.unsupported
        }
        while offset < source.length {
            var start = 0, end = 0, contentsEnd = 0
            source.getLineStart(&start, end: &end, contentsEnd: &contentsEnd,
                                for: NSRange(location: offset, length: 0))
            let line = source.substring(with: NSRange(location: start, length: contentsEnd - start))
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            offset = end
            if start == 0, trimmed == "---" { frontMatter = true; result.excludedBlocks += 1; continue }
            if frontMatter {
                if trimmed == "---" { frontMatter = false }
                continue
            }
            let containerContent = strippedContainer(trimmed)
            if let current = fence {
                if current.isClosed(by: containerContent) { fence = nil }
                continue
            }
            if var current = environment {
                current.depth += containerContent.components(separatedBy: current.open).count - 1
                current.depth -= containerContent.components(separatedBy: current.close).count - 1
                environment = current.depth <= 0 && containerContent.hasSuffix(current.close) ? nil : current
                continue
            }
            if let closer = mathUntil {
                if containerContent.hasSuffix(closer) { mathUntil = nil }
                continue
            }
            if let closer = htmlUntil {
                if line.lowercased().contains(closer) { htmlUntil = nil }
                continue
            }
            let inContainer = containers.consume(line)
            if containerContent.hasPrefix("\\begin{"),
               let closing = containerContent.firstIndex(of: "}"),
               containerContent.distance(from: containerContent.startIndex, to: closing) <= 80 {
                let name = containerContent.dropFirst(7).prefix { $0 != "}" }
                let opener = "\\begin{\(name)}", closer = "\\end{\(name)}"
                let depth = containerContent.components(separatedBy: opener).count - containerContent.components(separatedBy: closer).count
                flush(); result.excludedBlocks += 1
                if depth > 0 || !containerContent.hasSuffix(closer) { environment = (opener, closer, depth) }
                continue
            }
            for (opener, closer) in [("$$", "$$"), ("\\[", "\\]")] {
                if containerContent.hasPrefix(opener), !containerContent.dropFirst(opener.count).hasSuffix(closer) {
                    flush(); mathUntil = closer; result.excludedBlocks += 1; break
                }
            }
            if mathUntil != nil { continue }
            var imageSyntax = Scan()
            if containerContent.contains("<") { scanLine(containerContent, base: 0, into: &imageSyntax) }
            let lower = maskingImageSyntax(containerContent, base: 0, ranges: imageSyntax.syntaxRanges[...]).lowercased()
            for (opener, closer) in [("<!--", "-->"), ("<script", "</script>"), ("<style", "</style>"), ("<pre", "</pre>")] {
                if lower.contains(opener), !lower.contains(closer) {
                    flush(); htmlUntil = closer; result.excludedBlocks += 1
                    break
                }
            }
            if htmlUntil != nil { continue }
            if lower.contains("<"), !lower.contains(">") {
                flush(); htmlUntil = ">"; result.excludedBlocks += 1; continue
            }
            if let opening = MarkdownFence.opening(in: containerContent) {
                flush(); fence = opening; result.excludedBlocks += 1; continue
            }
            if trimmed.isEmpty { flush() } else { block.append((line, start, inContainer)) }
            if result.exceededLimit { break }
        }
        flush()
        return result
    }

    private static func maskingImageSyntax(_ line: String, base: Int, ranges: ArraySlice<NSRange>) -> String {
        guard line.contains("<"), !ranges.isEmpty else { return line }
        let probe = NSMutableString(string: line)
        for range in ranges.reversed() {
            probe.replaceCharacters(in: NSRange(location: range.location - base, length: range.length), with: " ")
        }
        return probe as String
    }

    /// Definitions can share a paragraph with following lines, so keep the
    /// whole block literal. A complete ordinary `[label][ref]` or inline link
    /// does not turn neighboring images into definitions.
    private static func isPotentialDefinition(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("[") else { return false }
        guard let close = trimmed.firstIndex(of: "]") else { return true }
        let label = trimmed[..<close]
        let after = trimmed.index(after: close)
        return label.contains("\\") || trimmed.hasPrefix("[^") ||
            (after < trimmed.endIndex && trimmed[after] == ":")
    }

    /// Persist the outer container across paragraph breaks. A less-indented
    /// line after a blank boundary returns to top level; without that boundary,
    /// prose may be a lazy continuation. Nested list markers retain the outer
    /// list's content column. This state only excludes; it never fabricates a
    /// source mapping for nested content.
    private struct ContainerExclusionState {
        var list: (indent: Int, content: Int)?
        var quote = false
        var afterBlank = false

        mutating func consume(_ line: String) -> Bool {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                afterBlank = true
                return list != nil || quote
            }
            let indent = MarkdownIndentation.width(line)
            if trimmed.hasPrefix(">") {
                quote = true; afterBlank = false
                return true
            }
            if let marker = Self.listMarker(in: line, indent: indent) {
                if list == nil || indent <= list!.indent { list = marker }
                quote = false; afterBlank = false
                return true
            }
            if let list {
                if indent >= list.content {
                    afterBlank = false
                    return true
                }
                if !afterBlank, MarkdownLine.heading(in: line) == nil,
                   !MarkdownLine.isHorizontalRule(line), MarkdownFence.opening(in: line) == nil {
                    return true
                }
                self.list = nil
            }
            if quote {
                if !afterBlank { return true }
                quote = false
            }
            afterBlank = false
            return false
        }

        private static func listMarker(in line: String, indent: Int) -> (indent: Int, content: Int)? {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let range = trimmed.range(of: #"^(?:[-*+]|[0-9]{1,9}[.)])[ \t]+"#, options: .regularExpression) else { return nil }
            let marker = String(trimmed[range])
            let delimiter = marker.prefix { $0 != " " && $0 != "\t" }
            let gap = String(marker.dropFirst(delimiter.count))
            return (indent, MarkdownIndentation.contentColumn(markerIndent: indent,
                delimiterWidth: delimiter.count, gap: gap))
        }
    }

    private static func strippedContainer(_ line: String) -> String {
        var remaining = line[...]
        // Container stripping is only used to exclude literal regions. Never
        // use it to invent edit offsets or to collect container images.
        for _ in 0..<64 {
            remaining = remaining.drop(while: { $0 == " " || $0 == "\t" })
            if remaining.hasPrefix(">") { remaining = remaining.dropFirst(); continue }
            if let marker = remaining.range(of: #"^(?:[-*+]|[0-9]{1,9}[.)])[ \t]+"#, options: .regularExpression) {
                remaining = remaining[marker.upperBound...]; continue
            }
            break
        }
        return String(remaining)
    }

    private static func scanLine(_ line: String, base: Int, into result: inout Scan) {
        let units = Array(line.utf16)
        // An image-shaped string inside an ordinary link title/label is not a
        // safe independent image destination. Reuse the bounded candidate walk.
        let enclosingLinks = MarkdownLinkSyntax.candidateRanges(in: line).filter {
            $0.location == 0 || units[$0.location - 1] != 33
        }
        var enclosingIndex = 0
        let lastBrace = units.lastIndex(of: 125) ?? -1
        var index = 0
        while index + 1 < units.count {
            if units[index] == 92 { index += 2; continue }
            guard units[index] == 33, units[index + 1] == 91 else { index += 1; continue }
            if result.references.count + result.unsupported.count >= maximumCandidates {
                result.exceededLimit = true; return
            }
            while enclosingIndex < enclosingLinks.count, NSMaxRange(enclosingLinks[enclosingIndex]) <= index {
                enclosingIndex += 1
            }
            if enclosingIndex < enclosingLinks.count, NSLocationInRange(index, enclosingLinks[enclosingIndex]) {
                let end = NSMaxRange(enclosingLinks[enclosingIndex])
                result.unsupported.append(String(decoding: units[index..<min(end, index + 80)], as: UTF16.self))
                index = end; continue
            }
            let start = index
            let bound = min(units.count, start + maximumCandidateUnits)
            var cursor = index + 2
            while cursor < bound, units[cursor] != 93, units[cursor] != 91, units[cursor] != 92 { cursor += 1 }
            guard cursor < bound, units[cursor] == 93 else {
                result.unsupported.append(String(decoding: units[start..<min(bound, start + 80)], as: UTF16.self))
                index = max(cursor, index + 2); continue
            }
            cursor += 1
            guard cursor < bound, units[cursor] == 40 else {
                result.unsupported.append(String(decoding: units[start..<cursor], as: UTF16.self))
                index = cursor; continue
            }
            cursor += 1
            let angled = cursor < bound && units[cursor] == 60
            if angled { cursor += 1 }
            let destinationStart = cursor
            if angled {
                while cursor < bound, ![60, 62, 92].contains(units[cursor]) { cursor += 1 }
            } else {
                while cursor < bound, ![9, 32, 40, 41, 60, 62, 92].contains(units[cursor]) { cursor += 1 }
            }
            let destinationEnd = cursor
            var valid = destinationStart < destinationEnd
            if angled {
                valid = valid && cursor < bound && units[cursor] == 62
                if valid { cursor += 1 }
            }
            // Exactly the renderer's optional double-quoted title. No rewrite
            // of its spelling, whitespace, or trailing figure attributes.
            if cursor < bound, [9, 32].contains(units[cursor]) {
                while cursor < bound, [9, 32].contains(units[cursor]) { cursor += 1 }
                if cursor < bound, units[cursor] == 34 {
                    cursor += 1
                    while cursor < bound, units[cursor] != 34, units[cursor] != 92 { cursor += 1 }
                    if cursor < bound, units[cursor] == 34 { cursor += 1 } else { valid = false }
                } else { valid = false }
            }
            valid = valid && cursor < bound && units[cursor] == 41
            if valid {
                let raw = String(decoding: units[destinationStart..<destinationEnd], as: UTF16.self)
                result.references.append(Reference(destination: LinkReference.decode(raw),
                    range: NSRange(location: base + destinationStart, length: destinationEnd - destinationStart)))
                index = MarkdownLinkSyntax.endOfImageAttributes(in: units, after: cursor + 1,
                                                                 lastClosingBrace: lastBrace)
                result.syntaxRanges.append(NSRange(location: base + start, length: index - start))
            } else {
                result.unsupported.append(String(decoding: units[start..<min(bound, start + 80)], as: UTF16.self))
                // The candidate may contain more literal image examples. Consume
                // this bounded candidate rather than interpreting nested content.
                index = max(cursor + 1, index + 2)
            }
        }
    }
}
