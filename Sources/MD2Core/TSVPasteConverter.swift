import Foundation

/// A small quoted-TSV grammar; malformed quoting is never guessed or truncated.
enum TSVPasteConverter {
    static func convert(_ source: String, budget: PasteBudget) throws -> String {
        let bytes = Array(source.utf8)
        var index = 0, rows: [[String]] = [], row: [String] = [], field: [UInt8] = []
        var quoted = false, closed = false, fieldStart = true, endedRecord = false, cells = 0
        func finishField() throws {
            row.append(String(decoding: field, as: UTF8.self))
            field.removeAll(keepingCapacity: true)
            closed = false; fieldStart = true; cells += 1
            guard row.count <= budget.limits.columns, cells <= budget.limits.cells else { throw MarkdownPaste.Failure.limit }
        }
        func finishRow() throws {
            try finishField()
            rows.append(row); row.removeAll(keepingCapacity: true)
            guard rows.count <= budget.limits.rows else { throw MarkdownPaste.Failure.limit }
            try budget.check()
        }
        while index < bytes.count {
            if index % 1024 == 0 { try budget.check() }
            let byte = bytes[index]
            endedRecord = false
            if quoted {
                if byte == 34 {
                    if index + 1 < bytes.count, bytes[index + 1] == 34 { field.append(34); index += 2; continue }
                    quoted = false; closed = true; index += 1; continue
                }
                if byte == 13 {
                    field.append(10); index += index + 1 < bytes.count && bytes[index + 1] == 10 ? 2 : 1; continue
                }
                field.append(byte); index += 1; continue
            }
            if byte == 9 { try finishField(); index += 1; continue }
            if byte == 10 || byte == 13 {
                try finishRow(); endedRecord = true
                index += byte == 13 && index + 1 < bytes.count && bytes[index + 1] == 10 ? 2 : 1
                continue
            }
            if closed { throw MarkdownPaste.Failure.malformed }
            if byte == 34 {
                guard fieldStart else { throw MarkdownPaste.Failure.malformed }
                quoted = true; fieldStart = false; index += 1; continue
            }
            field.append(byte); fieldStart = false; index += 1
        }
        guard !quoted else { throw MarkdownPaste.Failure.malformed }
        if !endedRecord { try finishRow() }
        guard let width = rows.map(\.count).max(), width > 0 else { throw MarkdownPaste.Failure.unavailable }
        guard (rows.count + 1) * width <= budget.limits.cells else { throw MarkdownPaste.Failure.limit }
        var lines: [String] = []
        var size = 0
        for (offset, cells) in rows.enumerated() {
            try budget.check()
            let padded = cells + Array(repeating: "", count: width - cells.count)
            let line = "| " + padded.map { PasteLiteral.escape($0, table: true) }.joined(separator: " | ") + " |"
            size += line.utf8.count + 1
            guard size <= budget.limits.outputBytes else { throw MarkdownPaste.Failure.limit }
            lines.append(line)
            if offset == 0 { lines.append("| " + Array(repeating: "---", count: width).joined(separator: " | ") + " |") }
        }
        let result = lines.joined(separator: "\n")
        guard result.utf16.count <= budget.limits.tableOutputUTF16 else { throw MarkdownPaste.Failure.limit }
        return result
    }
}
