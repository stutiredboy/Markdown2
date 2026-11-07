import Foundation

/// Shared by the block regression tests and the optimized standalone probe.
enum BlockScalingWorkload: String, CaseIterable {
    case blankRun, flatList, looseList, swiftFence, plainFence, listFence, longParagraph, repeatedHeadings

    func document(count: Int) -> String {
        switch self {
        case .blankRun:
            return "- parent\n" + String(repeating: "\n", count: count)
                + "  continuation\n\n# Outside\n\nText[^n] [ref]\n\n[^n]: note\n[ref]: https://example.com"
        case .flatList:
            return (0..<count).map { "- item \($0)" }.joined(separator: "\n")
        case .looseList:
            return (0..<count).map { "- item \($0)\n\n  continuation \($0)" }.joined(separator: "\n\n")
        case .swiftFence, .plainFence:
            let language = self == .swiftFence ? "swift" : ""
            return "```\(language)\n" + String(repeating: "let value = calculate(42) // comment\n", count: count) + "```"
        case .listFence:
            return "- parent\n\n  ```swift\n" + String(repeating: "  let value = calculate(42) // comment\n", count: count) + "  ```"
        case .longParagraph:
            return String(repeating: "A plain paragraph with English and 中文 text.\n", count: count)
        case .repeatedHeadings:
            return String(repeating: "# Repeated\n\nParagraph [ref].\n\n", count: count)
                + "[ref]: https://example.com"
        }
    }

    func matches(_ body: String, headingCount: Int, count: Int) -> Bool {
        switch self {
        case .blankRun:
            return headingCount == 1 && body.contains("id=\"outside\"")
                && body.contains("data-md2-source-line=\"\(count + 4)\"")
                && body.contains("href=\"#fn-n\"") && body.contains("href=\"https://example.com\"")
                && body.contains("continuation")
        case .flatList, .looseList:
            return body.components(separatedBy: "<li ").count - 1 == count
        case .swiftFence, .listFence:
            return body.components(separatedBy: "tok-keyword").count - 1 == count
                && body.components(separatedBy: "tok-comment").count - 1 == count
        case .plainFence:
            return body.components(separatedBy: "let value = calculate(42) // comment").count - 1 == count
        case .longParagraph:
            return body.components(separatedBy: "A plain paragraph").count - 1 == count
        case .repeatedHeadings:
            return headingCount == count && body.contains("id=\"repeated-\(count)\"")
                && body.components(separatedBy: "href=\"https://example.com\"").count - 1 == count
        }
    }
}
