import AppKit

extension NSAttributedString.Key {
    /// Marks characters that belong to a fenced code block so the layout manager
    /// can paint one continuous, full-width background behind them — including the
    /// line/paragraph spacing and empty lines that a `.backgroundColor` text
    /// attribute would leave unshaded.
    static let markdownCodeBlock = NSAttributedString.Key("md2.markdownCodeBlock")
    static let markdownAutoClosing = NSAttributedString.Key("md2.markdownAutoClosing")
}

/// Draws code-block shading by filling whole line-fragment rects (which include
/// line and paragraph spacing) across the full container width, so a fenced block
/// renders as a seamless panel instead of per-line stripes.
final class CodeBlockLayoutManager: NSLayoutManager {
    /// Matches the preview's `--code-bg` (light #f6f8fa / dark #27272a) and adapts
    /// to the effective appearance when `setFill()` resolves it during drawing.
    private static let codeBackgroundColor = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark
            ? NSColor(red: 0x27 / 255, green: 0x27 / 255, blue: 0x2A / 255, alpha: 1)
            : NSColor(red: 0xF6 / 255, green: 0xF8 / 255, blue: 0xFA / 255, alpha: 1)
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        // Paint the code-block panel first so inline-code backgrounds and find
        // highlights (drawn by super) land on top and stay visible.
        drawCodeBlockBackgrounds(forGlyphRange: glyphsToShow, at: origin)
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }

    private func drawCodeBlockBackgrounds(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard let textStorage else { return }

        Self.codeBackgroundColor.setFill()

        enumerateLineFragments(forGlyphRange: glyphsToShow) { rect, _, container, lineGlyphRange, _ in
            let charRange = self.characterRange(forGlyphRange: lineGlyphRange, actualGlyphRange: nil)
            guard charRange.length > 0,
                  charRange.location < textStorage.length,
                  textStorage.attribute(.markdownCodeBlock, at: charRange.location, effectiveRange: nil) != nil
            else { return }

            // Convert the (container-relative) line fragment rect to view
            // coordinates and stretch it across the full container width.
            var fillRect = rect
            fillRect.origin.x = origin.x
            fillRect.origin.y = rect.origin.y + origin.y
            fillRect.size.width = container.size.width
            fillRect.fill()
        }
    }
}
