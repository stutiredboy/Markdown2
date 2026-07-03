import Foundation

/// Decodes a Markdown file's bytes into text with a fixed, predictable
/// fallback order: a Unicode byte-order mark is authoritative when present;
/// otherwise strict UTF-8, then GB18030 (a byte-compatible superset of GBK and
/// GB2312). Each step is an exact decode — no statistical charset guessing —
/// so the result is deterministic and testable. Returns `nil` when nothing
/// plausibly decodes the bytes as text.
enum MarkdownFileDecoder {
    struct DecodedFile: Equatable {
        let text: String
        /// True when the bytes were not plain UTF-8 (a BOM'd Unicode form or
        /// GB18030): the next save, which always writes plain UTF-8, will
        /// change the file's bytes.
        let usedFallbackEncoding: Bool
    }

    static func decode(_ data: Data) -> DecodedFile? {
        if let bom = decodeByteOrderMark(data) {
            return bom
        }
        if let utf8 = String(data: data, encoding: .utf8) {
            return DecodedFile(text: utf8, usedFallbackEncoding: false)
        }
        if let gb = String(data: data, encoding: Self.gb18030),
           isPlausibleText(gb) {
            return DecodedFile(text: gb, usedFallbackEncoding: true)
        }
        return nil
    }

    /// GB18030 has no `String.Encoding` constant; bridge it from CoreFoundation.
    static let gb18030 = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
    )

    /// Decodes data led by a Unicode BOM, stripping the mark. UTF-32LE is
    /// checked before UTF-16LE because its BOM (`FF FE 00 00`) begins with the
    /// UTF-16LE mark.
    private static func decodeByteOrderMark(_ data: Data) -> DecodedFile? {
        let marks: [(bom: [UInt8], encoding: String.Encoding)] = [
            ([0x00, 0x00, 0xFE, 0xFF], .utf32BigEndian),
            ([0xFF, 0xFE, 0x00, 0x00], .utf32LittleEndian),
            ([0xEF, 0xBB, 0xBF], .utf8),
            ([0xFE, 0xFF], .utf16BigEndian),
            ([0xFF, 0xFE], .utf16LittleEndian)
        ]
        for (bom, encoding) in marks where data.starts(with: bom) {
            guard let text = String(data: data.dropFirst(bom.count), encoding: encoding) else {
                return nil
            }
            return DecodedFile(text: text, usedFallbackEncoding: true)
        }
        return nil
    }

    /// GB18030 assigns meaning to almost any byte sequence, so a binary file
    /// can "decode" into garbage. Real text does not contain control
    /// characters beyond tab/newline/carriage-return; their presence rejects
    /// the decode.
    private static func isPlausibleText(_ text: String) -> Bool {
        !text.unicodeScalars.contains { scalar in
            (scalar.value < 0x20 && scalar.value != 0x09 && scalar.value != 0x0A && scalar.value != 0x0D)
                || scalar.value == 0x7F
        }
    }
}
