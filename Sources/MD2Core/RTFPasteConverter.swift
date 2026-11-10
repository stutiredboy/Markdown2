import Foundation

/// Strict text/Unicode/bold/italic RTF subset. Unknown semantic controls reject
/// the entire input. In particular this is not the platform rich-text importer.
enum RTFPasteConverter {
    private struct State {
        var bold = false
        var italic = false
        var unicodeFallback = 1
        var skipped = false
        var destinationPosition = true
    }
    static func convert(_ data: Data, budget: PasteBudget) throws -> String {
        let bytes = Array(data)
        guard bytes.starts(with: Array("{\\rtf1".utf8)) else { throw MarkdownPaste.Failure.malformed }
        var stack: [State] = [], state = State(), index = 0, output = "", units: [UInt16] = []
        var pendingFallback = 0, sawRoot = false, closedRoot = false
        func flush() throws {
            guard !units.isEmpty else { return }
            // Reject broken Unicode rather than silently substituting U+FFFD.
            var offset = 0
            while offset < units.count {
                if UTF16.isLeadSurrogate(units[offset]) {
                    guard offset + 1 < units.count, UTF16.isTrailSurrogate(units[offset + 1]) else { throw MarkdownPaste.Failure.malformed }
                    offset += 2
                } else {
                    guard !UTF16.isTrailSurrogate(units[offset]) else { throw MarkdownPaste.Failure.malformed }
                    offset += 1
                }
            }
            let literal = PasteLiteral.escape(String(decoding: units, as: UTF16.self))
            let trimmed = literal.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || (!state.bold && !state.italic) { output += literal }
            else {
                let marker = state.bold ? (state.italic ? "***" : "**") : "*"
                output += (literal.first?.isWhitespace == true ? " " : "") + marker + trimmed + marker + (literal.last?.isWhitespace == true ? " " : "")
            }
            units.removeAll(keepingCapacity: true)
            try budget.output(output)
        }
        func append(_ byte: UInt8) throws {
            if pendingFallback > 0 { pendingFallback -= 1; return }
            if state.skipped { return }
            guard let string = String(bytes: [byte], encoding: .windowsCP1252) else { throw MarkdownPaste.Failure.unsupported }
            units.append(contentsOf: string.utf16)
            state.destinationPosition = false
        }
        func isLetter(_ byte: UInt8) -> Bool { (65...90).contains(byte) || (97...122).contains(byte) }
        let metadata: Set<String> = ["fonttbl", "colortbl", "generator"]
        // Cosmetic document/character properties only. Semantic controls such
        // as lists, fields, underline, strike, super/sub and hidden text reject.
        let cosmetic: Set<String> = ["ansi", "deff", "deflang", "deflangfe", "f", "fs", "cf", "cb", "highlight", "lang", "langfe", "kerning", "expnd", "expndtw", "cocoartf", "cocoatextscaling", "cocoaplatform", "paperw", "paperh", "margl", "margr", "margt", "margb", "vieww", "viewh", "viewkind", "pard", "ql", "qr", "qc", "qj", "li", "ri", "fi", "sa", "sb", "sl", "slmult", "tx", "deftab", "widowctrl", "hyphauto", "fet"]
        while index < bytes.count {
            let byte = bytes[index]; index += 1
            if index % 1024 == 0 || [92, 123, 125].contains(byte) { try budget.check(depth: stack.count, token: [92, 123, 125].contains(byte)) }
            if closedRoot {
                guard [9, 10, 13, 32].contains(byte) else { throw MarkdownPaste.Failure.malformed }
                continue
            }
            if byte == 123 {
                try flush(); state.destinationPosition = false; stack.append(state); state.destinationPosition = true; sawRoot = true
                try budget.check(depth: stack.count)
                continue
            }
            if byte == 125 {
                try flush()
                guard let previous = stack.popLast() else { throw MarkdownPaste.Failure.malformed }
                state = previous
                if stack.isEmpty { closedRoot = true }
                continue
            }
            guard !stack.isEmpty else { throw MarkdownPaste.Failure.malformed }
            if byte == 10 || byte == 13 { continue } // RTF transport line wrapping
            guard byte == 92 else { try append(byte); continue }
            guard index < bytes.count else { throw MarkdownPaste.Failure.malformed }
            let control = bytes[index]; index += 1
            if [92, 123, 125].contains(control) { try append(control); continue }
            if control == 39 {
                guard index + 1 < bytes.count, let value = UInt8(String(decoding: bytes[index..<(index + 2)], as: UTF8.self), radix: 16) else { throw MarkdownPaste.Failure.malformed }
                index += 2; try append(value); continue
            }
            if control == 42 {
                // Only recognized metadata may follow an ignorable destination.
                guard index < bytes.count, bytes[index] == 92 else { throw MarkdownPaste.Failure.malformed }
                continue
            }
            if !isLetter(control) {
                if state.skipped { continue }
                if control == 126 { units.append(0xA0); continue }
                if control == 95 { units.append(0x2011); continue }
                throw MarkdownPaste.Failure.unsupported
            }
            let start = index - 1
            while index < bytes.count, isLetter(bytes[index]) { index += 1 }
            let word = String(decoding: bytes[start..<index], as: UTF8.self)
            let numberStart = index
            if index < bytes.count, bytes[index] == 45 { index += 1 }
            while index < bytes.count, (48...57).contains(bytes[index]) { index += 1 }
            let number = index == numberStart ? nil : Int(String(decoding: bytes[numberStart..<index], as: UTF8.self))
            if index > numberStart, number == nil { throw MarkdownPaste.Failure.malformed }
            if index < bytes.count, bytes[index] == 32 { index += 1 }
            if state.skipped { continue }
            if metadata.contains(word) {
                guard stack.count > 1, state.destinationPosition else { throw MarkdownPaste.Failure.malformed }
                try flush(); state.skipped = true; continue
            }
            state.destinationPosition = false
            switch word {
            case "rtf": guard number == 1, stack.count == 1 else { throw MarkdownPaste.Failure.unsupported }
            case "ansicpg": guard number == 1252 else { throw MarkdownPaste.Failure.unsupported }
            case "uc": guard let number, (0...16).contains(number) else { throw MarkdownPaste.Failure.unsupported }; state.unicodeFallback = number
            case "u":
                guard let number, (-32768...65535).contains(number), pendingFallback == 0 else { throw MarkdownPaste.Failure.malformed }
                units.append(UInt16(truncatingIfNeeded: number)); pendingFallback = state.unicodeFallback
            case "b": try flush(); state.bold = number != 0
            case "i": try flush(); state.italic = number != 0
            case "plain": try flush(); state.bold = false; state.italic = false
            case "par", "line": try flush(); output += word == "par" ? "\n\n" : "\n"
            case "tab": units.append(9)
            default:
                guard cosmetic.contains(word) else { throw MarkdownPaste.Failure.unsupported }
            }
        }
        guard sawRoot, closedRoot, stack.isEmpty, pendingFallback == 0 else { throw MarkdownPaste.Failure.malformed }
        try flush()
        try budget.output(output)
        return output
    }
}
