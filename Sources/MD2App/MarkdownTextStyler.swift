import AppKit

enum MarkdownTextStyler {
    @MainActor
    static func apply(to textView: NSTextView) {
        guard let storage = textView.textStorage else { return }

        let fullRange = NSRange(location: 0, length: storage.length)
        let baseFont = NSFont.systemFont(ofSize: 16)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 4
        paragraphStyle.paragraphSpacing = 7

        storage.beginEditing()
        storage.setAttributes([
            .font: baseFont,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraphStyle
        ], range: fullRange)

        applyBlockStyles(to: storage)
        applyInlineStyles(to: storage)
        storage.endEditing()

        synchronizeTypingAttributes(in: textView)

        // Re-styling the whole document shifts line positions (heading fonts are
        // taller than body text), but lines that merely moved — without their own
        // attributes changing — are not marked for redisplay. The caret-reveal
        // scroll that follows a keystroke then blits those stale pixels (NSClipView
        // always minimizes the invalidated region on macOS 11+, copying the rest),
        // leaving ghost copies of headings stacked at the viewport edge. Forcing a
        // full redraw guarantees the blitted pixels are overdrawn before the frame
        // is shown, so no ghosts survive.
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

    private static func applyBlockStyles(to storage: NSTextStorage) {
        let source = storage.string
        var activeFence = false

        source.enumerateSubstrings(
            in: source.startIndex..<source.endIndex,
            options: [.byLines, .substringNotRequired]
        ) { _, substringRange, enclosingRange, _ in
            let lineRange = NSRange(substringRange, in: source)
            // The enclosing range includes the line terminator, so the marker
            // covers newlines and empty lines too — the layout manager then fills
            // those fragments and the inter-line spacing seamlessly.
            let fullLineRange = NSRange(enclosingRange, in: source)
            let line = String(source[substringRange])
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Preserve trailing whitespace for ATX heading recognition. A line
            // containing only "## " is already a heading input context; trimming
            // both ends turned it into "##" until the IME committed a character,
            // so provisional letters were rendered with the body font.
            let leadingTrimmed = String(line.drop { $0 == " " || $0 == "\t" })

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                activeFence.toggle()
                addCodeLineStyle(to: storage, contentRange: lineRange, lineRange: fullLineRange)
                return
            }

            if activeFence {
                addCodeLineStyle(to: storage, contentRange: lineRange, lineRange: fullLineRange)
                return
            }

            if let headingLevel = headingLevel(in: leadingTrimmed) {
                let size = max(17, 30 - CGFloat(headingLevel * 3))
                storage.addAttributes([
                    .font: NSFont.boldSystemFont(ofSize: size),
                    .foregroundColor: NSColor.labelColor
                ], range: lineRange)
                return
            }

            if trimmed.hasPrefix(">") {
                storage.addAttributes([
                    .foregroundColor: NSColor.secondaryLabelColor
                ], range: lineRange)
            }

            if isListLine(trimmed), let markerRange = markerRange(in: line, lineRange: lineRange) {
                storage.addAttributes([
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .font: NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)
                ], range: markerRange)
            }
        }
    }

    private static func applyInlineStyles(to storage: NSTextStorage) {
        let string = storage.string
        let full = NSRange(string.startIndex..<string.endIndex, in: string)

        // `[^`\n]+` (not `[^`]+`) keeps inline code on a single line; otherwise the
        // span runs from a fence's backtick across the whole code block to the next
        // backtick, painting an uneven overlay over the block panel.
        addRegexAttributes(
            to: storage,
            pattern: #"`[^`\n]+`"#,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 15, weight: .regular),
                .backgroundColor: NSColor.textColor.withAlphaComponent(0.08)
            ],
            range: full
        )

        addRegexAttributes(
            to: storage,
            pattern: #"\*\*[^*]+\*\*|__[^_]+__"#,
            attributes: [
                .font: NSFont.boldSystemFont(ofSize: 16)
            ],
            range: full
        )

        addRegexAttributes(
            to: storage,
            pattern: #"(?<!\*)\*(?!\s)[^*]+(?<!\s)\*(?!\*)"#,
            attributes: [
                .font: NSFontManager.shared.convert(NSFont.systemFont(ofSize: 16), toHaveTrait: .italicFontMask)
            ],
            range: full
        )

        addRegexAttributes(
            to: storage,
            pattern: #"\[[^\]]+\]\([^)]+\)"#,
            attributes: [
                .foregroundColor: NSColor.linkColor
            ],
            range: full
        )
    }

    private static func addCodeLineStyle(to storage: NSTextStorage, contentRange: NSRange, lineRange: NSRange) {
        if contentRange.length > 0 {
            storage.addAttribute(
                .font,
                value: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
                range: contentRange
            )
        }
        // The marker drives the continuous panel drawn by CodeBlockLayoutManager;
        // applying it over the full line (incl. terminator) keeps the panel gapless.
        storage.addAttribute(.markdownCodeBlock, value: true, range: lineRange)
    }

    private static func headingLevel(in trimmedLine: String) -> Int? {
        let count = trimmedLine.prefix { $0 == "#" }.count
        guard (1...6).contains(count), trimmedLine.dropFirst(count).first == " " else {
            return nil
        }
        return count
    }

    private static func isListLine(_ trimmedLine: String) -> Bool {
        if trimmedLine.hasPrefix("- ") || trimmedLine.hasPrefix("* ") || trimmedLine.hasPrefix("+ ") {
            return true
        }

        return trimmedLine.range(of: #"^\d+[\.)]\s+"#, options: .regularExpression) != nil
    }

    private static func markerRange(in line: String, lineRange: NSRange) -> NSRange? {
        if line.trimmingCharacters(in: .whitespaces).hasPrefix("- [ ] ") ||
            line.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("- [x] ") {
            return NSRange(location: lineRange.location, length: min(6, lineRange.length))
        }

        if let range = line.range(of: #"^\s*(?:[-*+]|\d+[\.)])\s+"#, options: .regularExpression) {
            let nsRange = NSRange(range, in: line)
            return NSRange(location: lineRange.location + nsRange.location, length: nsRange.length)
        }

        return nil
    }

    private static func addRegexAttributes(
        to storage: NSTextStorage,
        pattern: String,
        attributes: [NSAttributedString.Key: Any],
        range: NSRange
    ) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return
        }

        let string = storage.string
        regex.enumerateMatches(in: string, range: range) { match, _, _ in
            guard let match, match.range.location < storage.length else { return }
            // Inline markdown is not interpreted inside fenced code, and any
            // overlay there would break the uniform code-block panel.
            if rangeIntersectsCodeBlock(match.range, in: storage) {
                return
            }
            storage.addAttributes(attributes, range: match.range)
        }
    }

    private static func rangeIntersectsCodeBlock(_ range: NSRange, in storage: NSTextStorage) -> Bool {
        var intersectsCodeBlock = false
        storage.enumerateAttribute(.markdownCodeBlock, in: range, options: []) { value, _, stop in
            if value != nil {
                intersectsCodeBlock = true
                stop.pointee = true
            }
        }
        return intersectsCodeBlock
    }
}
