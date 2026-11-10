import Foundation

/// Parses an inert semantic subset. No browser, importer, resource resolver or
/// HTML recovery guesses are used; unsupported structure rejects the fragment.
enum HTMLPasteConverter {
    private indirect enum Node {
        case text(String)
        case element(String, [String: String], [Node])
    }
    private struct Frame {
        var name: String
        var attributes: [String: String]
        var children: [Node] = []
    }
    private static let allowed: Set<String> = ["html", "head", "body", "meta", "title", "div", "span", "p", "br", "b", "strong", "i", "em", "a", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "li", "pre", "code", "blockquote"]
    private static let dangerous: Set<String> = ["script", "style", "img", "picture", "source", "video", "audio", "iframe", "embed", "object", "svg", "math", "link", "base", "form", "input"]

    static func convert(_ input: String, budget: PasteBudget) throws -> String {
        var source = input
        if let start = source.range(of: "<!--StartFragment-->"), let end = source.range(of: "<!--EndFragment-->", range: start.upperBound..<source.endIndex) {
            source = String(source[start.upperBound..<end.lowerBound])
        } else if source.hasPrefix("Version:"), let html = source.firstIndex(of: "<") {
            source = String(source[html...])
        }
        let bytes = Array(source.utf8)
        var stack = [Frame(name: "root", attributes: [:])]
        var index = 0
        while index < bytes.count {
            try budget.check(depth: stack.count - 1, token: true)
            if bytes[index] != 60 {
                let start = index
                while index < bytes.count, bytes[index] != 60 {
                    if index % 1024 == 0 { try budget.check() }
                    index += 1
                }
                let value = String(decoding: bytes[start..<index], as: UTF8.self)
                let decoded = HTMLSafety.decodeHTMLAttributeEntities(value)
                if stack.last?.name == "head", !decoded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    throw MarkdownPaste.Failure.malformed
                }
                stack[stack.count - 1].children.append(.text(decoded))
                continue
            }
            if bytes[index...].starts(with: Array("<!--".utf8)) {
                index += 4
                var found = false
                while index + 2 < bytes.count {
                    if index % 1024 == 0 { try budget.check() }
                    if bytes[index] == 45, bytes[index + 1] == 45, bytes[index + 2] == 62 { index += 3; found = true; break }
                    index += 1
                }
                guard found else { throw MarkdownPaste.Failure.malformed }
                continue
            }
            let start = index
            index += 1
            var quote: UInt8?
            while index < bytes.count {
                if index % 1024 == 0 { try budget.check() }
                let byte = bytes[index]
                if let active = quote { if byte == active { quote = nil } }
                else if byte == 34 || byte == 39 { quote = byte }
                else if byte == 62 { break }
                index += 1
            }
            guard index < bytes.count, quote == nil else { throw MarkdownPaste.Failure.malformed }
            let token = Array(bytes[(start + 1)..<index]); index += 1
            if String(decoding: token, as: UTF8.self).lowercased() == "!doctype html" { continue }
            let tag = try parseTag(token)
            if dangerous.contains(tag.name) { throw MarkdownPaste.Failure.unsafe }
            guard allowed.contains(tag.name) else { throw MarkdownPaste.Failure.unsupported }
            if tag.closing {
                guard stack.count > 1, stack.last?.name == tag.name else { throw MarkdownPaste.Failure.malformed }
                let frame = stack.removeLast()
                stack[stack.count - 1].children.append(.element(frame.name, frame.attributes, frame.children))
            } else {
                // A title in body content must not silently erase its text.
                // Inert void meta markers have no content to discard and remain
                // allowed in clipboard fragments after attribute validation.
                if stack.last?.name == "title" || (stack.last?.name == "head" && !["title", "meta"].contains(tag.name)) {
                    throw MarkdownPaste.Failure.malformed
                }
                if tag.name == "title", stack.last?.name != "head" {
                    throw MarkdownPaste.Failure.malformed
                }
                if tag.name == "head" {
                    guard let parent = stack.last,
                          (parent.name == "root" && stack.count == 1) || (parent.name == "html" && stack.count == 2),
                          isInertHeaderPrefix(parent.children),
                          isInertHeaderPrefix(stack[0].children) else { throw MarkdownPaste.Failure.malformed }
                }
                try validate(tag.name, attributes: tag.attributes)
                if ["br", "meta"].contains(tag.name) {
                    stack[stack.count - 1].children.append(.element(tag.name, tag.attributes, []))
                } else {
                    guard !tag.selfClosing else { throw MarkdownPaste.Failure.malformed }
                    stack.append(Frame(name: tag.name, attributes: tag.attributes))
                    try budget.check(depth: stack.count - 1)
                }
            }
        }
        guard stack.count == 1 else { throw MarkdownPaste.Failure.malformed }
        let result = try render(stack[0].children, budget: budget).trimmingCharacters(in: .whitespacesAndNewlines)
        try budget.output(result)
        return result
    }

    private static func isInertHeaderPrefix(_ nodes: [Node]) -> Bool {
        nodes.allSatisfy { node in
            switch node {
            case .text(let text): return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .element(let name, _, _): return name == "meta"
            }
        }
    }

    private struct Tag {
        let name: String
        let attributes: [String: String]
        let closing: Bool
        let selfClosing: Bool
    }
    private static func parseTag(_ bytes: [UInt8]) throws -> Tag {
        var index = 0
        func spaces() { while index < bytes.count, [9, 10, 12, 13, 32].contains(bytes[index]) { index += 1 } }
        let closing = bytes.first == 47
        if closing { index += 1 }
        let start = index
        while index < bytes.count, isName(bytes[index]) { index += 1 }
        guard index > start else { throw MarkdownPaste.Failure.malformed }
        let name = String(decoding: bytes[start..<index], as: UTF8.self).lowercased()
        var attributes: [String: String] = [:]
        var selfClosing = false
        while index < bytes.count {
            let old = index
            spaces()
            if index == bytes.count { break }
            if bytes[index] == 47 {
                index += 1; spaces(); selfClosing = true
                guard index == bytes.count else { throw MarkdownPaste.Failure.malformed }
                break
            }
            guard !closing, index > old else { throw MarkdownPaste.Failure.malformed }
            let attrStart = index
            while index < bytes.count, isName(bytes[index]) { index += 1 }
            guard index > attrStart else { throw MarkdownPaste.Failure.malformed }
            let key = String(decoding: bytes[attrStart..<index], as: UTF8.self).lowercased()
            spaces()
            var value = ""
            if index < bytes.count, bytes[index] == 61 {
                index += 1; spaces()
                guard index < bytes.count else { throw MarkdownPaste.Failure.malformed }
                if bytes[index] == 34 || bytes[index] == 39 {
                    let quote = bytes[index]; index += 1
                    let valueStart = index
                    while index < bytes.count, bytes[index] != quote { index += 1 }
                    guard index < bytes.count else { throw MarkdownPaste.Failure.malformed }
                    value = String(decoding: bytes[valueStart..<index], as: UTF8.self); index += 1
                } else {
                    let valueStart = index
                    while index < bytes.count, ![9, 10, 12, 13, 32].contains(bytes[index]) {
                        guard ![34, 39, 60, 61, 96].contains(bytes[index]) else { throw MarkdownPaste.Failure.malformed }
                        index += 1
                    }
                    value = String(decoding: bytes[valueStart..<index], as: UTF8.self)
                }
            }
            guard attributes[key] == nil else { throw MarkdownPaste.Failure.malformed }
            attributes[key] = HTMLSafety.decodeHTMLAttributeEntities(value)
        }
        guard !(closing && selfClosing) else { throw MarkdownPaste.Failure.malformed }
        return Tag(name: name, attributes: attributes, closing: closing, selfClosing: selfClosing)
    }
    private static func isName(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || [45, 58, 95].contains(byte)
    }
    private static func validate(_ name: String, attributes: [String: String]) throws {
        for (key, value) in attributes {
            if key.hasPrefix("on") || ["src", "srcset", "background", "poster", "action", "formaction", "xlink:href"].contains(key) { throw MarkdownPaste.Failure.unsafe }
            if key == "style" {
                let lower = value.lowercased()
                if lower.contains("url") || lower.contains("@import") || lower.contains("expression") { throw MarkdownPaste.Failure.unsafe }
                continue // CSS/font/color/layout are intentionally not preserved.
            }
            if ["class", "id", "title", "lang", "dir", "role"].contains(key) || key.hasPrefix("aria-") || key.hasPrefix("data-") { continue }
            if name == "meta", ["charset", "content", "name"].contains(key) { continue }
            if name == "a", key == "href" {
                guard !value.unicodeScalars.contains(where: { $0.value <= 32 || $0.value == 127 }), MarkdownEditing.clipboardURL(value) != nil else { throw MarkdownPaste.Failure.unsafe }
                continue
            }
            if name == "a", ["target", "rel"].contains(key) { continue }
            if name == "ol", key == "start", let value = Int(value), (0...999_999).contains(value) { continue }
            throw MarkdownPaste.Failure.unsupported
        }
    }
    private static func collapse(_ value: String) -> String {
        var result = "", inSpace = false
        for scalar in value.unicodeScalars {
            if [9, 10, 12, 13, 32].contains(scalar.value) {
                if !inSpace { result += " " }; inSpace = true
            } else { result.unicodeScalars.append(scalar); inSpace = false }
        }
        return result
    }
    private static func rawText(_ nodes: [Node]) -> String {
        nodes.map { node in
            switch node {
            case .text(let value): return value
            case .element(let name, _, let children): return name == "br" ? "\n" : rawText(children)
            }
        }.joined().replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }
    private static func maxTicks(_ text: String) -> Int {
        var run = 0, longest = 0
        for character in text { run = character == "`" ? run + 1 : 0; longest = max(longest, run) }
        return longest
    }
    private final class RenderBuffer {
        let budget: PasteBudget
        let boundaryAllowance: Int
        var text = ""
        private var bytes = 0, leadingBytes = 0, trailingBytes = 0
        private var hasContent = false

        init(budget: PasteBudget) throws {
            self.budget = budget
            let limits = budget.limits
            guard limits.outputBytes >= 0, limits.richBytes >= 0, limits.tokens >= 0 else { throw MarkdownPaste.Failure.limit }
            // Copied boundary whitespace is bounded by raw input; each parsed
            // block adds at most four boundary LFs. Final output stays capped.
            let (generated, overflow) = limits.tokens.multipliedReportingOverflow(by: 4)
            let (allowance, addedOverflow) = limits.richBytes.addingReportingOverflow(generated)
            guard !overflow, !addedOverflow else { throw MarkdownPaste.Failure.limit }
            boundaryAllowance = allowance
        }

        func append(_ fragment: String) throws {
            try budget.check()
            let addedBytes = fragment.utf8.count
            let (total, overflow) = bytes.addingReportingOverflow(addedBytes)
            guard !overflow,
                  total <= budget.limits.outputBytes || total - budget.limits.outputBytes <= boundaryAllowance else { throw MarkdownPaste.Failure.limit }
            let whitespace = CharacterSet.whitespacesAndNewlines
            // Scan only the new fragment's edges, never the accumulated output.
            // Pending trailing whitespace becomes interior when content arrives.
            if let first = fragment.unicodeScalars.firstIndex(where: { !whitespace.contains($0) }),
               let last = fragment.unicodeScalars.lastIndex(where: { !whitespace.contains($0) }) {
                if !hasContent { leadingBytes += fragment[..<first].utf8.count }
                trailingBytes = fragment[fragment.unicodeScalars.index(after: last)...].utf8.count
                hasContent = true
            } else if hasContent { trailingBytes += addedBytes }
            else { leadingBytes += addedBytes }
            guard total - leadingBytes - trailingBytes <= budget.limits.outputBytes else { throw MarkdownPaste.Failure.limit }
            bytes = total
            text += fragment
        }
    }
    // Keep recursive traversal frames small at the supported depth of 64.
    // Serialization temporaries live in non-recursive wrapping helpers.
    private static func render(_ nodes: [Node], budget: PasteBudget, bold: Bool = false, italic: Bool = false) throws -> String {
        let output = try RenderBuffer(budget: budget)
        for node in nodes {
            try budget.check()
            switch node {
            case .text(let value): try output.append(PasteLiteral.escape(collapse(value)))
            case .element(let name, let attributes, let children):
                try output.append(renderElement(name, attributes: attributes, children: children, budget: budget, bold: bold, italic: italic))
            }
        }
        return output.text
    }
    private static func renderElement(_ name: String, attributes: [String: String], children: [Node], budget: PasteBudget, bold: Bool, italic: Bool) throws -> String {
        if name == "head" { try validateHead(children); return "" }
        if ["meta", "title"].contains(name) { return "" }
        if ["pre", "code"].contains(name) { return renderCode(children, block: name == "pre") }
        if ["ul", "ol"].contains(name) { return try renderList(children, ordered: name == "ol", start: Int(attributes["start"] ?? "1") ?? 1, budget: budget) }
        let isBold = ["b", "strong"].contains(name), isItalic = ["i", "em"].contains(name)
        let content = try render(children, budget: budget, bold: bold || isBold, italic: italic || isItalic)
        return try wrap(content, name: name, attributes: attributes, bold: bold, italic: italic)
    }
    private static func validateHead(_ children: [Node]) throws {
        for child in children {
            switch child {
            case .text(let value) where value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty: break
            case .element(let name, _, _) where ["meta", "title"].contains(name): break
            default: throw MarkdownPaste.Failure.unsupported
            }
        }
    }
    private static func renderCode(_ children: [Node], block: Bool) -> String {
        if block {
            let literal = rawText(children)
            let fence = String(repeating: "`", count: max(3, maxTicks(literal) + 1))
            return "\n\n" + fence + "\n" + literal + (literal.hasSuffix("\n") ? "" : "\n") + fence + "\n\n"
        }
        let literal = collapse(rawText(children))
        guard !literal.isEmpty else { return "" }
        let delimiter = String(repeating: "`", count: maxTicks(literal) + 1)
        let pad = literal.hasPrefix("`") || literal.hasSuffix("`") || (literal.hasPrefix(" ") && literal.hasSuffix(" ") && !literal.allSatisfy({ $0 == " " })) ? " " : ""
        return delimiter + pad + literal + pad + delimiter
    }
    private static func renderList(_ children: [Node], ordered: Bool, start: Int, budget: PasteBudget) throws -> String {
        var items: [String] = [], number = start
        for child in children {
            if case .text(let value) = child, value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            guard case .element("li", _, let itemChildren) = child else { throw MarkdownPaste.Failure.unsupported }
            let item = try render(itemChildren, budget: budget).trimmingCharacters(in: .whitespacesAndNewlines)
            let marker = ordered ? "\(number). " : "- "
            let lines = item.components(separatedBy: "\n")
            items.append(marker + (lines.first ?? "") + lines.dropFirst().map { "\n" + String(repeating: " ", count: marker.count) + $0 }.joined())
            number += 1
        }
        return "\n\n" + items.joined(separator: "\n") + "\n\n"
    }
    private static func wrap(_ content: String, name: String, attributes: [String: String], bold: Bool, italic: Bool) throws -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "b", "strong", "i", "em":
            guard !content.contains("\n") else { throw MarkdownPaste.Failure.unsupported }
            let isBold = ["b", "strong"].contains(name)
            if (isBold && bold) || (!isBold && italic) || trimmed.isEmpty { return content }
            let marker = isBold ? "**" : "*"
            return (content.first?.isWhitespace == true ? " " : "") + marker + trimmed + marker + (content.last?.isWhitespace == true ? " " : "")
        case "a":
            guard !content.contains("\n"), !content.contains("](") else { throw MarkdownPaste.Failure.unsupported }
            if let href = attributes["href"], let url = MarkdownEditing.clipboardURL(href) { return "[" + content + "](" + url + ")" }
            return content
        case "br": return "<br>"
        case "p", "div": return trimmed.isEmpty ? "" : "\n\n" + trimmed + "\n\n"
        case "h1", "h2", "h3", "h4", "h5", "h6":
            guard !trimmed.contains("\n") else { throw MarkdownPaste.Failure.unsupported }
            return "\n\n" + String(repeating: "#", count: Int(name.dropFirst())!) + " " + trimmed + "\n\n"
        case "blockquote": return "\n\n" + trimmed.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n") + "\n\n"
        case "li": throw MarkdownPaste.Failure.unsupported // only list parent may consume li
        default: return content
        }
    }
}
