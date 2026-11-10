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
        var requiresDestination = false
    }
    static func convert(_ data: Data, budget: PasteBudget) throws -> String {
        let bytes = Array(data)
        guard bytes.starts(with: Array("{\\rtf1".utf8)) else { throw MarkdownPaste.Failure.malformed }
        var stack: [State] = [], state = State(), index = 0, output = "", units: [UInt16] = []
        var pendingFallback = 0, sawRoot = false, closedRoot = false, bodyStarted = false
        var previousWasCR = false
        func appendDecodedUnit(_ unit: UInt16) {
            // Formatting/group boundaries may flush between the CR and LF of
            // one textual line ending. Normalize the decoded character stream,
            // not individual formatting runs or transport wrapping bytes.
            if unit == 10, previousWasCR { previousWasCR = false; return }
            previousWasCR = unit == 13
            units.append(unit == 13 ? 10 : unit)
        }
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
            let leading = literal.prefix(while: \.isWhitespace)
            let remainder = literal.dropFirst(leading.count)
            let trailingCount = remainder.reversed().prefix(while: \.isWhitespace).count
            let content = remainder.dropLast(trailingCount)
            if content.isEmpty || (!state.bold && !state.italic) { output += literal }
            else {
                let marker = state.bold ? (state.italic ? "***" : "**") : "*"
                output += leading + marker + content + marker + remainder.suffix(trailingCount)
            }
            units.removeAll(keepingCapacity: true)
            try budget.output(output)
        }
        func append(_ byte: UInt8) throws {
            if state.skipped { return }
            guard !state.requiresDestination else { throw MarkdownPaste.Failure.malformed }
            if pendingFallback > 0 { pendingFallback -= 1; return }
            guard let string = String(bytes: [byte], encoding: .windowsCP1252) else { throw MarkdownPaste.Failure.unsupported }
            for unit in string.utf16 { appendDecodedUnit(unit) }
            state.destinationPosition = false
            bodyStarted = true
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
                guard !state.requiresDestination else { throw MarkdownPaste.Failure.malformed }
                pendingFallback = 0 // An unescaped group boundary ends ANSI fallback scanning.
                try flush(); state.destinationPosition = false; stack.append(state); state.destinationPosition = true; sawRoot = true
                try budget.check(depth: stack.count)
                continue
            }
            if byte == 125 {
                guard !state.requiresDestination else { throw MarkdownPaste.Failure.malformed }
                pendingFallback = 0
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
            if !isLetter(control) {
                if state.skipped { continue }
                guard !state.requiresDestination else { throw MarkdownPaste.Failure.malformed }
                // Every control symbol is one ANSI fallback token, regardless
                // of the character/style it would otherwise produce.
                if pendingFallback > 0 { pendingFallback -= 1; continue }
                if control == 42 {
                    guard stack.count == 2, state.destinationPosition, !bodyStarted else { throw MarkdownPaste.Failure.malformed }
                    state.requiresDestination = true
                    continue
                }
                state.destinationPosition = false
                bodyStarted = true
                if control == 126 { appendDecodedUnit(0xA0); continue }
                if control == 95 { appendDecodedUnit(0x2011); continue }
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
            // A binary token includes its literal byte payload. Even when it
            // is only a skipped Unicode fallback, braces/backslashes inside its
            // bytes must never be interpreted as RTF structure.
            if word == "bin" {
                guard let number, number >= 0, number <= bytes.count - index else { throw MarkdownPaste.Failure.malformed }
                if state.skipped { index += number; continue }
                guard !state.requiresDestination, pendingFallback > 0 else { throw MarkdownPaste.Failure.unsupported }
                index += number; pendingFallback -= 1
                continue
            }
            if state.skipped { continue }
            if state.requiresDestination {
                guard metadata.contains(word) else { throw MarkdownPaste.Failure.unsupported }
                state.requiresDestination = false
            }
            if pendingFallback > 0 { pendingFallback -= 1; continue }
            if metadata.contains(word) {
                guard stack.count == 2, state.destinationPosition, !bodyStarted else { throw MarkdownPaste.Failure.malformed }
                try flush(); state.skipped = true; continue
            }
            state.destinationPosition = false
            switch word {
            case "rtf": guard number == 1, stack.count == 1 else { throw MarkdownPaste.Failure.unsupported }
            case "ansicpg": guard number == 1252 else { throw MarkdownPaste.Failure.unsupported }
            case "uc": guard let number, (0...16).contains(number) else { throw MarkdownPaste.Failure.unsupported }; state.unicodeFallback = number
            case "u":
                guard let number, (-32768...65535).contains(number), pendingFallback == 0 else { throw MarkdownPaste.Failure.malformed }
                appendDecodedUnit(UInt16(truncatingIfNeeded: number)); pendingFallback = state.unicodeFallback; bodyStarted = true
            case "b": try flush(); state.bold = number != 0
            case "i": try flush(); state.italic = number != 0
            case "plain": try flush(); state.bold = false; state.italic = false
            case "par", "line": try flush(); output += word == "par" ? "\n\n" : "\n"; previousWasCR = false; bodyStarted = true
            case "tab": appendDecodedUnit(9); bodyStarted = true
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
