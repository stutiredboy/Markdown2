import AppKit
import MD2Core

/// Parsing runs on a serial background actor. AppKit only receives the changed
/// attribute range; no full-document regex pass is on the keystroke path.
struct MarkdownStylePlan: Sendable {
    enum Kind: Int, Sendable { case code, heading1, heading2, heading3, heading4, heading5, heading6, quote, marker, inlineCode, bold, italic, link, codeText }
    struct Span: Hashable, Sendable { let range: NSRange; let kind: Kind }
    let text: String
    var spans: [Span] = []

    init(_ text: String) {
        self.text = text
        var spans: [Span] = []
        var fenced = false
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.byLines]) { line, content, enclosing, _ in
            let line = line ?? ""
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let range = NSRange(content, in: text)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fenced.toggle()
                spans.append(Span(range: NSRange(enclosing, in: text), kind: .code))
                spans.append(Span(range: range, kind: .codeText))
            } else if fenced {
                spans.append(Span(range: NSRange(enclosing, in: text), kind: .code))
                spans.append(Span(range: range, kind: .codeText))
            } else {
                let leading = line.drop { $0 == " " || $0 == "\t" }
                let level = leading.prefix { $0 == "#" }.count
                if (1...6).contains(level), leading.dropFirst(level).first == " " {
                    spans.append(Span(range: range, kind: Kind(rawValue: level)!))
                } else {
                    if trimmed.hasPrefix(">") { spans.append(Span(range: range, kind: .quote)) }
                    if let marker = line.range(of: #"^\s*(?:[-*+]|\d+[\.)])\s+"#, options: .regularExpression) {
                        let local = NSRange(marker, in: line)
                        let task = trimmed.hasPrefix("- [ ] ") || trimmed.lowercased().hasPrefix("- [x] ")
                        spans.append(Span(range: NSRange(location: range.location + (task ? 0 : local.location), length: task ? min(6, range.length) : local.length), kind: .marker))
                    }
                }
            }
        }
        let codeRanges = spans.filter { $0.kind == .code }.map(\.range)
        let patterns: [(String, Kind)] = [
            (#"`[^`\n]+`"#, .inlineCode),
            (#"\*\*[^*]+\*\*|__[^_]+__"#, .bold),
            (#"(?<!\*)\*(?!\s)[^*]+(?<!\s)\*(?!\*)"#, .italic),
            (#"\[[^\]]+\]\([^)]+\)"#, .link)
        ]
        for (pattern, kind) in patterns {
            let regex = try! NSRegularExpression(pattern: pattern)
            let full = NSRange(location: 0, length: (text as NSString).length)
            let matches = kind == .link
                ? MarkdownLinkSyntax.candidateRanges(in: text).compactMap { regex.firstMatch(in: text, options: .anchored, range: $0) }
                : regex.matches(in: text, range: full)
            var codeIndex = 0
            for match in matches {
                while codeIndex < codeRanges.count, NSMaxRange(codeRanges[codeIndex]) <= match.range.location { codeIndex += 1 }
                if codeIndex < codeRanges.count, NSIntersectionRange(codeRanges[codeIndex], match.range).length > 0 { continue }
                spans.append(Span(range: match.range, kind: kind))
            }
        }
        self.spans = spans
    }

    /// Include text edits and any syntax whose meaning changed beyond the edit
    /// (e.g. deleting a closing fence or a multi-line emphasis delimiter).
    func changedRange(from old: MarkdownStylePlan?) -> NSRange {
        let newUnits = Array(text.utf16)
        guard let old else { return NSRange(location: 0, length: newUnits.count) }
        let oldUnits = Array(old.text.utf16)
        var prefix = 0
        while prefix < min(oldUnits.count, newUnits.count), oldUnits[prefix] == newUnits[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(oldUnits.count, newUnits.count) - prefix,
              oldUnits[oldUnits.count - 1 - suffix] == newUnits[newUnits.count - 1 - suffix] { suffix += 1 }
        let oldEnd = oldUnits.count - suffix
        let newEnd = newUnits.count - suffix
        let delta = newUnits.count - oldUnits.count
        var lower = prefix
        var upper = newEnd
        var unchanged: Set<Span> = []
        for span in old.spans {
            if NSMaxRange(span.range) <= prefix {
                unchanged.insert(span)
            } else if span.range.location >= oldEnd {
                unchanged.insert(Span(range: NSRange(location: span.range.location + delta, length: span.range.length), kind: span.kind))
            } else {
                lower = min(lower, span.range.location)
                upper = max(upper, min(newUnits.count, NSMaxRange(span.range) + delta))
            }
        }
        let current = Set(spans)
        for span in unchanged.symmetricDifference(current) {
            lower = min(lower, span.range.location)
            upper = max(upper, NSMaxRange(span.range))
        }
        // Include paragraph terminators so deleted heading/code attributes do
        // not survive in the insertion attributes on an otherwise empty line.
        let range = NSRange(location: min(lower, newUnits.count), length: max(0, min(upper, newUnits.count) - lower))
        return (text as NSString).paragraphRange(for: range)
    }
}

actor MarkdownStyleWorker {
    func prepare(_ text: String, previous: MarkdownStylePlan?) -> (MarkdownStylePlan, NSRange)? {
        guard !Task.isCancelled else { return nil }
        let plan = MarkdownStylePlan(text)
        guard !Task.isCancelled else { return nil }
        return (plan, plan.changedRange(from: previous))
    }
}

@MainActor
final class MarkdownStylingController {
    private let worker = MarkdownStyleWorker()
    private var pending: Task<Void, Never>?
    private var previous: MarkdownStylePlan?
    private var generation = 0

    func schedule(in textView: NSTextView, willApply: @escaping @MainActor () -> Void = {}, didApply: @escaping @MainActor () -> Void = {}) {
        generation &+= 1
        let revision = generation
        pending?.cancel()
        let text = textView.string
        let previous = previous
        let worker = worker
        pending = Task { [weak self, weak textView] in
            // Coalesce rapid input and IME commits before doing syntax work.
            try? await Task.sleep(for: .milliseconds(25))
            guard !Task.isCancelled, let (plan, range) = await worker.prepare(text, previous: previous),
                  !Task.isCancelled, let self, self.generation == revision,
                  let textView, !textView.hasMarkedText(), textView.string == text else { return }
            // Loads, large pastes and fence edits can invalidate the entire
            // document. Apply bounded chunks and yield between them so even
            // these updates do not monopolize the main actor.
            self.previous = nil
            var cursor = range.location
            let source = text as NSString
            repeat {
                guard !Task.isCancelled, self.generation == revision,
                      !textView.hasMarkedText(), textView.string == text else { return }
                let chunk = source.rangeOfComposedCharacterSequences(for:
                    NSRange(location: cursor, length: min(8_192, NSMaxRange(range) - cursor)))
                willApply()
                let selection = textView.selectedRanges
                let clip = textView.enclosingScrollView?.contentView
                let origin = clip == nil ? nil : textView.visibleRect.origin
                MarkdownTextStyler.apply(plan, range: chunk, to: textView)
                textView.selectedRanges = selection
                if let origin {
                    // The first asynchronous font reflow can grow a previously
                    // short text view with a negative frame origin. Keep the
                    // document top-aligned, preserving document coordinates,
                    // otherwise the gutter/scroll probes look below the text.
                    textView.setFrameOrigin(.zero)
                    clip?.scroll(to: origin)
                    if let scrollView = textView.enclosingScrollView {
                        scrollView.reflectScrolledClipView(scrollView.contentView)
                    }
                }
                didApply()
                cursor = NSMaxRange(chunk)
                if cursor < NSMaxRange(range) { await Task.yield() }
            } while cursor < NSMaxRange(range)
            self.previous = plan
        }
    }

    func flush() async {
        repeat {
            let revision = generation
            await pending?.value
            if revision == generation { return }
        } while true
    }
    deinit { pending?.cancel() }
}

enum MarkdownTextStyler {
    @MainActor static func apply(to textView: NSTextView) {
        let plan = MarkdownStylePlan(textView.string)
        apply(plan, range: NSRange(location: 0, length: (plan.text as NSString).length), to: textView)
    }

    @MainActor static func apply(_ plan: MarkdownStylePlan, range: NSRange, to textView: NSTextView) {
        guard let storage = textView.textStorage, range.length > 0 else {
            synchronizeTypingAttributes(in: textView)
            return
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        paragraph.paragraphSpacing = 7
        storage.beginEditing()
        storage.setAttributes([.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph], range: range)
        for span in plan.spans {
            let clipped = NSIntersectionRange(range, span.range)
            guard clipped.length > 0 else { continue }
            let attributes: [NSAttributedString.Key: Any]
            switch span.kind {
            case .code: attributes = [.markdownCodeBlock: true]
            case .codeText: attributes = [.font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)]
            case .heading1, .heading2, .heading3, .heading4, .heading5, .heading6:
                attributes = [.font: NSFont.boldSystemFont(ofSize: max(17, 30 - CGFloat(span.kind.rawValue * 3))), .foregroundColor: NSColor.labelColor]
            case .quote: attributes = [.foregroundColor: NSColor.secondaryLabelColor]
            case .marker: attributes = [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)]
            case .inlineCode: attributes = [.font: NSFont.monospacedSystemFont(ofSize: 15, weight: .regular), .backgroundColor: NSColor.textColor.withAlphaComponent(0.08)]
            case .bold: attributes = [.font: NSFont.boldSystemFont(ofSize: 16)]
            case .italic: attributes = [.font: NSFontManager.shared.convert(NSFont.systemFont(ofSize: 16), toHaveTrait: .italicFontMask)]
            case .link: attributes = [.foregroundColor: NSColor.linkColor]
            }
            storage.addAttributes(attributes, range: clipped)
        }
        storage.endEditing()
        synchronizeTypingAttributes(in: textView)
        textView.needsDisplay = true
    }

    /// Keeps AppKit's insertion attributes aligned with the styled source line.
    /// `isRichText == false` does not infer these attributes from syntax styling,
    /// so an input method otherwise renders its provisional Latin letters with
    /// NSTextView's 12pt default even when the caret is in a 24pt heading.
    @MainActor
    static func synchronizeTypingAttributes(in textView: NSTextView) {
        guard !textView.hasMarkedText(), let storage = textView.textStorage else { return }

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 4
        paragraphStyle.paragraphSpacing = 7
        var typingAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 16),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraphStyle
        ]

        if let index = insertionAttributeIndex(
            at: textView.selectedRange().location,
            in: storage.string as NSString
        ) {
            for key in [NSAttributedString.Key.font, .foregroundColor, .paragraphStyle] {
                if let value = storage.attribute(key, at: index, effectiveRange: nil) {
                    typingAttributes[key] = value
                }
            }
        }

        textView.typingAttributes = typingAttributes
    }

    /// Chooses the character whose visual style should be inherited at a caret.
    /// At a line terminator/end-of-document the preceding character owns the
    /// style; at a line start the following character does. Empty lines retain
    /// the base style carried by their newline.
    private static func insertionAttributeIndex(at location: Int, in string: NSString) -> Int? {
        guard string.length > 0 else { return nil }
        let clamped = max(0, min(location, string.length))
        let newline = unichar(10)

        if clamped < string.length, string.character(at: clamped) != newline {
            return clamped
        }
        if clamped > 0, string.character(at: clamped - 1) != newline {
            return clamped - 1
        }
        return min(clamped, string.length - 1)
    }

}
