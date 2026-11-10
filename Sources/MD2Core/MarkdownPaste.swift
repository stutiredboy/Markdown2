import Foundation

/// Value-only explicit paste conversion. Clipboard/UI objects never enter core.
public enum MarkdownPaste {
    public enum Kind: Equatable, Sendable { case plainText, markdown, table }
    public struct Payload: Sendable {
        public var plainText: String?
        public var html: Data?
        public var rtf: Data?
        public init(plainText: String? = nil, html: Data? = nil, rtf: Data? = nil) {
            self.plainText = plainText; self.html = html; self.rtf = rtf
        }
    }
    public struct Limits: Sendable {
        public var richBytes = 1_048_576
        public var plainBytes = 2_097_152
        public var outputBytes = 2_097_152
        public var tokens = 20_000
        public var depth = 64
        public var rows = 999
        public var columns = 128
        public var cells = 20_000
        public var tableOutputUTF16 = 100_000
        public var seconds: Double = 1
        public init() {}
    }
    public enum Failure: Error, Equatable, Sendable {
        case unavailable, unsupported, malformed, unsafe, limit, cancelled
    }
    public struct Output: Equatable, Sendable {
        public let text: String
        public let isBlock: Bool
        /// Whole-input plain fallback, never a partially converted rich fragment.
        public let fallbackReason: Failure?
        let maximumEditBytes: Int
        let maximumTableEditUTF16: Int?
        init(text: String, isBlock: Bool, fallbackReason: Failure?, limits: Limits, table: Bool = false) {
            self.text = text; self.isBlock = isBlock; self.fallbackReason = fallbackReason
            maximumEditBytes = limits.outputBytes
            maximumTableEditUTF16 = table ? limits.tableOutputUTF16 : nil
        }
    }
    public struct Edit: Equatable, Sendable {
        public let range: NSRange
        public let replacement: String
        public let selection: NSRange
    }

    public static func convert(_ kind: Kind, payload: Payload, limits: Limits = .init()) -> Result<Output, Failure> {
        let budget = PasteBudget(limits)
        do {
            try budget.check()
            switch kind {
            case .plainText:
                return .success(Output(text: try plain(payload, limits), isBlock: false, fallbackReason: nil, limits: limits))
            case .table:
                let text = try TSVPasteConverter.convert(plain(payload, limits), budget: budget)
                try budget.output(text)
                return .success(Output(text: text, isBlock: true, fallbackReason: nil, limits: limits, table: true))
            case .markdown:
                if let plain = payload.plainText, plain.utf8.count > limits.plainBytes { throw Failure.limit }
                guard payload.html != nil || payload.rtf != nil else {
                    return .success(Output(text: try plain(payload, limits), isBlock: false, fallbackReason: nil, limits: limits))
                }
                do {
                    let text: String
                    if let data = payload.html {
                        guard data.count <= limits.richBytes else { throw Failure.limit }
                        guard let html = String(data: data, encoding: .utf8) else { throw Failure.unsupported }
                        text = try HTMLPasteConverter.convert(html, budget: budget)
                    } else if let data = payload.rtf {
                        guard data.count <= limits.richBytes else { throw Failure.limit }
                        text = try RTFPasteConverter.convert(data, budget: budget)
                    } else { throw Failure.unavailable }
                    try budget.output(text)
                    guard !text.isEmpty else { throw Failure.unavailable }
                    return .success(Output(text: text, isBlock: true, fallbackReason: nil, limits: limits))
                } catch let failure as Failure {
                    // Cancellation is not a conversion failure and must never
                    // authorize a delayed fallback edit.
                    if failure == .cancelled || failure == .limit { throw failure }
                    let literal = PasteLiteral.prose(try plain(payload, limits))
                    try budget.output(literal)
                    return .success(Output(text: literal, isBlock: true, fallbackReason: failure, limits: limits))
                }
            }
        } catch let error as Failure { return .failure(error) }
        catch { return .failure(.malformed) }
    }

    private static func plain(_ payload: Payload, _ limits: Limits) throws -> String {
        guard let text = payload.plainText, !text.isEmpty else { throw Failure.unavailable }
        guard text.utf8.count <= limits.plainBytes, text.utf8.count <= limits.outputBytes else { throw Failure.limit }
        return text
    }

    /// Wrap structured output as a standalone block. Plain/fallback text stays
    /// byte-for-byte equivalent at the String UTF-16 boundary.
    public static func edit(_ source: String, selection: NSRange, output: Output) -> Edit? {
        let ns = source as NSString
        guard selection.location != NSNotFound, selection.location >= 0, selection.length >= 0,
              selection.location <= ns.length, selection.length <= ns.length - selection.location else { return nil }
        for offset in [selection.location, NSMaxRange(selection)] where offset > 0 && offset < ns.length {
            if UTF16.isLeadSurrogate(ns.character(at: offset - 1)), UTF16.isTrailSurrogate(ns.character(at: offset)) { return nil }
        }
        // A literal fragment can still become part of surrounding Markdown
        // destinations or HTML attributes. Without a full context parser, only
        // adopt fallback where no non-whitespace source remains outside the
        // user's original selection. Never expand that selection automatically.
        if output.fallbackReason != nil {
            let outside = ns.substring(to: selection.location) + ns.substring(from: NSMaxRange(selection))
            guard outside.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        }
        var replacement = output.text
        if output.isBlock {
            let start = selection.location, end = NSMaxRange(selection)
            let beforeRange = NSRange(location: 0, length: start)
            let afterRange = NSRange(location: end, length: ns.length - end)
            let previousLF = ns.range(of: "\n", options: .backwards, range: beforeRange).location
            let previousCR = ns.range(of: "\r", options: .backwards, range: beforeRange).location
            let lastLF = previousLF == NSNotFound ? -1 : previousLF
            let lastCR = previousCR == NSNotFound ? -1 : previousCR
            let ending: String
            if lastLF >= 0, lastLF > lastCR { ending = lastLF > 0 && ns.character(at: lastLF - 1) == 13 ? "\r\n" : "\n" }
            else if lastCR >= 0 { ending = "\r" }
            else {
                let nextLF = ns.range(of: "\n", range: afterRange).location
                let nextCR = ns.range(of: "\r", range: afterRange).location
                if nextCR != NSNotFound, nextLF == NSNotFound || nextCR < nextLF {
                    ending = nextCR + 1 < ns.length && ns.character(at: nextCR + 1) == 10 ? "\r\n" : "\r"
                } else { ending = "\n" }
            }
            replacement = output.text.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n").replacingOccurrences(of: "\n", with: ending)
            // Only the nearest two logical line endings decide block spacing;
            // don't copy/normalize the entire document around a small paste.
            let before = ns.substring(with: NSRange(location: max(0, start - 4), length: min(4, start)))
                .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            let after = ns.substring(with: NSRange(location: end, length: min(4, ns.length - end)))
                .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            if start > 0 { replacement = String(repeating: ending, count: before.hasSuffix("\n\n") ? 0 : before.hasSuffix("\n") ? 1 : 2) + replacement }
            if end < ns.length { replacement += String(repeating: ending, count: after.hasPrefix("\n\n") ? 0 : after.hasPrefix("\n") ? 1 : 2) }
        }
        guard replacement.utf8.count <= output.maximumEditBytes else { return nil }
        if let maximum = output.maximumTableEditUTF16, replacement.utf16.count > maximum { return nil }
        return Edit(range: selection, replacement: replacement,
                    selection: NSRange(location: selection.location + replacement.utf16.count, length: 0))
    }
}

/// Each parser consumes at most the captured input size and checks this shared
/// deadline between tokens/rows and inside long byte scans.
final class PasteBudget {
    let limits: MarkdownPaste.Limits
    private let deadline: ContinuousClock.Instant
    private var tokens = 0
    init(_ limits: MarkdownPaste.Limits) {
        self.limits = limits
        deadline = ContinuousClock.now.advanced(by: .seconds(max(0, limits.seconds)))
    }
    func check(depth: Int = 0, token: Bool = false) throws {
        if Task.isCancelled { throw MarkdownPaste.Failure.cancelled }
        if token { tokens += 1 }
        guard ContinuousClock.now < deadline, depth <= limits.depth, tokens <= limits.tokens else { throw MarkdownPaste.Failure.limit }
    }
    func output(_ text: String) throws {
        try check()
        guard text.utf8.count <= limits.outputBytes else { throw MarkdownPaste.Failure.limit }
    }
}

/// Keep literal clipboard text from turning into new Markdown constructs.
/// Entities protect table delimiters before the renderer splits columns.
enum PasteLiteral {
    static func prose(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n").map { line in
                // Protect indentation from becoming an indented code block.
                // ASCII whitespace remains ASCII after entity decoding.
                let prefix = line.prefix { $0 == " " || $0 == "\t" }
                return prefix.map { $0 == " " ? "&#32;" : "&#9;" }.joined() + escape(String(line.dropFirst(prefix.count)))
            }.joined(separator: "\n")
    }
    static func escape(_ text: String, table: Bool = false) -> String {
        var result = ""
        let units = Array(text.unicodeScalars)
        let firstNonSpace = units.firstIndex(where: { $0 != " " }) ?? units.count
        let lastNonSpace = units.lastIndex(where: { $0 != " " }) ?? -1
        for (index, scalar) in units.enumerated() {
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\\": result += "&#92;"
            case "|": result += "&#124;"
            case "`": result += "&#96;"
            case "(", ")", "[", "]", "$": result += "&#\(scalar.value);"
            case "\r": break // callers normalize CR before escaping
            case "\n": result += table ? "<br>" : "\n"
            case "\t": result += table ? "&#9;" : "\t"
            case " " where table && (index < firstNonSpace || index > lastNonSpace): result += "&#32;"
            default:
                if "!*_[]()#~$+-={}:.".unicodeScalars.contains(scalar) { result += "\\" }
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }
}
