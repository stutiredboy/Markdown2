import Foundation

/// The byte format travels with the document, including recovery snapshots.
struct MarkdownFileFormat: Codable, Equatable, Sendable {
    enum Encoding: String, Codable, CaseIterable, Sendable {
        case utf8 = "UTF-8", utf16LE = "UTF-16 LE", utf16BE = "UTF-16 BE"
        case utf32LE = "UTF-32 LE", utf32BE = "UTF-32 BE", gbk = "GBK", gb18030 = "GB18030"

        var stringEncoding: String.Encoding {
            switch self {
            case .utf8: .utf8
            case .utf16LE: .utf16LittleEndian
            case .utf16BE: .utf16BigEndian
            case .utf32LE: .utf32LittleEndian
            case .utf32BE: .utf32BigEndian
            case .gbk: MarkdownFileDecoder.gbk
            case .gb18030: MarkdownFileDecoder.gb18030
            }
        }

        var bom: Data {
            switch self {
            case .utf8: Data([0xef, 0xbb, 0xbf])
            case .utf16LE: Data([0xff, 0xfe])
            case .utf16BE: Data([0xfe, 0xff])
            case .utf32LE: Data([0xff, 0xfe, 0, 0])
            case .utf32BE: Data([0, 0, 0xfe, 0xff])
            case .gbk, .gb18030: Data()
            }
        }
    }

    enum LineEnding: String, Codable, Sendable {
        case lf = "LF", crlf = "CRLF", cr = "CR", mixed = "Mixed"

        static func detect(_ text: String) -> Self {
            let hasCRLF = text.contains("\r\n")
            let rest = text.replacingOccurrences(of: "\r\n", with: "")
            let hasCR = rest.contains("\r"), hasLF = rest.contains("\n")
            if [hasCRLF, hasCR, hasLF].filter({ $0 }).count > 1 { return .mixed }
            return hasCRLF ? .crlf : hasCR ? .cr : .lf
        }

        func applying(to text: String) -> String {
            // Keep mixed files verbatim, rather than silently normalizing them.
            guard self != .mixed else { return text }
            let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
            return normalized.replacingOccurrences(of: "\n", with: self == .crlf ? "\r\n" : self == .cr ? "\r" : "\n")
        }
    }

    var encoding: Encoding = .utf8
    var hasBOM = false
    var lineEnding: LineEnding = .lf
    var encodingLabel: String { encoding.rawValue + (hasBOM ? " BOM" : "") }

    /// No replacement characters, transliteration, or silent charset upgrades.
    func encode(_ text: String) -> Data? {
        let source = lineEnding.applying(to: text)
        guard let body = source.data(using: encoding.stringEncoding, allowLossyConversion: false),
              String(data: body, encoding: encoding.stringEncoding) == source else { return nil }
        return (hasBOM ? encoding.bom : Data()) + body
    }
}

/// BOM is authoritative, otherwise strict UTF-8, GBK, then GB18030. A GBK
/// round trip distinguishes its narrower repertoire from the GB18030 superset.
enum MarkdownFileDecoder {
    struct DecodedFile: Equatable {
        let text: String
        let format: MarkdownFileFormat
        var usedFallbackEncoding: Bool { format.encoding != .utf8 || format.hasBOM }
    }

    static let gbk = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.GBK_95.rawValue)))
    static let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))

    static func decode(_ data: Data) -> DecodedFile? {
        // UTF-32LE must precede UTF-16LE, whose BOM is its prefix.
        for encoding in [MarkdownFileFormat.Encoding.utf32BE, .utf32LE, .utf8, .utf16BE, .utf16LE]
        where data.starts(with: encoding.bom) {
            let body = data.dropFirst(encoding.bom.count)
            guard let text = String(data: body, encoding: encoding.stringEncoding),
                  text.data(using: encoding.stringEncoding, allowLossyConversion: false) == body else {
                return nil // A malformed BOM-marked file must not fall through.
            }
            return DecodedFile(text: text, format: .init(encoding: encoding, hasBOM: true, lineEnding: .detect(text)))
        }
        for encoding in [MarkdownFileFormat.Encoding.utf8, .gbk, .gb18030] {
            guard let text = String(data: data, encoding: encoding.stringEncoding),
                  encoding == .utf8 || isPlausibleText(text),
                  text.data(using: encoding.stringEncoding, allowLossyConversion: false) == data else { continue }
            return DecodedFile(text: text, format: .init(encoding: encoding, lineEnding: .detect(text)))
        }
        return nil
    }

    private static func isPlausibleText(_ text: String) -> Bool {
        !text.unicodeScalars.contains { scalar in
            (scalar.value < 0x20 && scalar.value != 0x09 && scalar.value != 0x0a && scalar.value != 0x0d)
                || scalar.value == 0x7f
        }
    }
}
