import Foundation

public struct DocumentStats: Equatable, Sendable {
    public let words: Int
    public let characters: Int
    public let lines: Int
    public let readingMinutes: Int

    public init(markdown: String) {
        self = MarkdownRenderer().render(markdown, assetMode: .appScheme).stats
    }

    /// Count authored, rendered text. Source line count remains useful for
    /// navigation and is deliberately independent of soft wrapping in the UI.
    public init(plainText: String, sourceLines: Int? = nil) {
        if Task.isCancelled {
            characters = 0
            lines = 0
            words = 0
            readingMinutes = 0
            return
        }
        characters = plainText.count
        lines = sourceLines ?? (plainText.isEmpty ? 0 : plainText.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).count)

        var wordCount = 0
        var hanCount = 0
        // ICU groups Chinese into words. Split Han characters out before using
        // its word boundaries for other scripts, including mixed 中文English.
        var otherText = ""
        for character in plainText {
            if Task.isCancelled { break }
            if character.unicodeScalars.contains(where: Self.isHan) {
                wordCount += 1
                hanCount += 1
                otherText.append(" ")
            } else {
                otherText.append(character)
            }
        }
        otherText.enumerateSubstrings(
            in: otherText.startIndex..<otherText.endIndex,
            options: [.byWords, .localized]
        ) { _, _, _, _ in
            if Task.isCancelled { return }
            wordCount += 1
        }

        words = wordCount
        let readingTime = Double(hanCount) / 400.0 + Double(wordCount - hanCount) / 240.0
        readingMinutes = wordCount == 0 ? 0 : max(1, Int(ceil(readingTime)))
    }

    private static func isHan(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x3007, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
             0x20000...0x2FA1F, 0x30000...0x3347F:
            true
        default:
            false
        }
    }
}
