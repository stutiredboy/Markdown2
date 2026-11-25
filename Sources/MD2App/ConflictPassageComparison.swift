/// A two-way comparison of immutable source snapshots. A passage's one-based,
/// half-open line range is empty when that side has no counterpart.
struct ConflictPassageComparison: Sendable {
    struct Passage: Sendable {
        let editorLines: Range<Int>
        let diskLines: Range<Int>
        let editorText: String
        let diskText: String
    }

    let passages: [Passage]
    let isCoarse: Bool

    static func compare(editor: String, disk: String) throws -> Self {
        try Task.checkCancellation()
        let identical = Self(passages: [], isCoarse: false)
        if editor.utf8.elementsEqual(disk.utf8) { return identical }

        // Scan the common prefix even on very large documents. Only index the
        // differing region, with a cap for newline-heavy inputs.
        var editorReader = LineReader(editor), diskReader = LineReader(disk)
        var firstLine = 1
        var left = try editorReader.next(), right = try diskReader.next()
        while let a = left, let b = right, a.utf8.elementsEqual(b.utf8) {
            firstLine += 1
            left = try editorReader.next()
            right = try diskReader.next()
        }
        if left == nil && right == nil { return identical }

        let editorTail = try editorReader.remaining(startingWith: left)
        let diskTail = try diskReader.remaining(startingWith: right)
        guard let editorLines = editorTail.lines, let diskLines = diskTail.lines else {
            return Self(passages: [Passage(
                editorLines: firstLine..<(firstLine + editorTail.count),
                diskLines: firstLine..<(firstLine + diskTail.count),
                editorText: left.map { String(editor[$0.startIndex...]) } ?? "",
                diskText: right.map { String(disk[$0.startIndex...]) } ?? ""
            )], isCoarse: true)
        }

        var editorEnd = editorLines.count, diskEnd = diskLines.count
        while editorEnd > 0, diskEnd > 0,
              editorLines[editorEnd - 1].utf8.elementsEqual(diskLines[diskEnd - 1].utf8) {
            try Task.checkCancellation()
            editorEnd -= 1
            diskEnd -= 1
        }

        func passage(_ a: Range<Int>, _ b: Range<Int>) -> Passage {
            Passage(editorLines: (firstLine + a.lowerBound)..<(firstLine + a.upperBound),
                    diskLines: (firstLine + b.lowerBound)..<(firstLine + b.upperBound),
                    editorText: editorLines[a].joined(separator: "\n"),
                    diskText: diskLines[b].joined(separator: "\n"))
        }
        guard editorEnd > 0 && diskEnd > 0 else {
            return Self(passages: [passage(0..<editorEnd, 0..<diskEnd)], isCoarse: false)
        }

        // Assign byte-exact integer IDs once so the diff's inner loop never
        // rescans a long paragraph or silently ignores normalization-only edits.
        var lineIDs: [LineKey: Int] = [:]
        func id(for text: Substring) throws -> Int {
            try Task.checkCancellation()
            let key = LineKey(text: text)
            if let id = lineIDs[key] { return id }
            let id = lineIDs.count
            lineIDs[key] = id
            return id
        }
        let a = try editorLines[..<editorEnd].map(id)
        let b = try diskLines[..<diskEnd].map(id)
        guard let matches = try matchingRuns(a, b) else {
            return Self(passages: [passage(0..<editorEnd, 0..<diskEnd)], isCoarse: true)
        }
        var passages: [Passage] = []
        var editorIndex = 0, diskIndex = 0
        for match in matches {
            if editorIndex < match.editor || diskIndex < match.disk {
                passages.append(passage(editorIndex..<match.editor, diskIndex..<match.disk))
            }
            editorIndex = match.editor + match.length
            diskIndex = match.disk + match.length
        }
        if editorIndex < editorEnd || diskIndex < diskEnd {
            passages.append(passage(editorIndex..<editorEnd, diskIndex..<diskEnd))
        }
        return Self(passages: passages, isCoarse: false)
    }

    private struct LineKey: Hashable {
        let text: Substring
        static func == (lhs: Self, rhs: Self) -> Bool { lhs.text.utf8.elementsEqual(rhs.text.utf8) }
        func hash(into hasher: inout Hasher) {
            if text.utf8.withContiguousStorageIfAvailable({ buffer in
                hasher.combine(bytes: UnsafeRawBufferPointer(buffer))
            }) == nil {
                // Foreign NSString storage may not provide a contiguous UTF-8 view.
                let bytes = Array(text.utf8)
                bytes.withUnsafeBytes { hasher.combine(bytes: $0) }
            }
        }
    }

    /// Count CRLF once. Keep the final empty line and
    /// distinguish a zero-byte document from a document containing a newline.
    private struct LineReader {
        let source: String
        var start: String.Index?

        init(_ source: String) {
            self.source = source
            start = source.isEmpty ? nil : source.startIndex
        }

        mutating func next() throws -> Substring? {
            guard let start else { return nil }
            let bytes = source.utf8
            var cursor = start
            while cursor < bytes.endIndex {
                try Task.checkCancellation()
                let limit = bytes.index(cursor, offsetBy: 32_768, limitedBy: bytes.endIndex) ?? bytes.endIndex
                if let end = bytes[cursor..<limit].firstIndex(where: { $0 == 10 || $0 == 13 }) {
                    var next = bytes.index(after: end)
                    if bytes[end] == 13, next < bytes.endIndex, bytes[next] == 10 {
                        bytes.formIndex(after: &next)
                    }
                    self.start = next
                    return source[start..<end]
                }
                cursor = limit
            }
            self.start = nil
            return source[start...]
        }

        mutating func remaining(startingWith first: Substring?) throws -> (lines: [Substring]?, count: Int) {
            guard let first else { return ([], 0) }
            var lines: [Substring]? = [first]
            var count = 1
            while let line = try next() {
                count += 1
                if count > 65_536 { lines = nil }
                lines?.append(line)
            }
            return (lines, count)
        }
    }

    private struct Run {
        let editor: Int
        let disk: Int
        let length: Int
        let previous: Int?
    }

    /// Myers' furthest-reaching path on each diagonal. Cap both the edit
    /// distance and the number of line comparisons. On exhaustion the caller
    /// displays the entire unmatched region from both versions.
    private static func matchingRuns(_ a: [Int], _ b: [Int]) throws -> [Run]? {
        let editLimit = 128
        guard abs(a.count - b.count) <= editLimit else { return nil }
        var comparisonsLeft = 1_000_000
        var runs: [Run] = []
        typealias Path = (end: Int, run: Int?)
        var frontier: [Int: Path] = [:]

        for edits in 0...editLimit {
            try Task.checkCancellation()
            var next: [Int: Path] = [:]
            for diagonal in stride(from: -edits, through: edits, by: 2) {
                // Deleting an editor line moves right. Inserting a disk line
                // moves down. Only keep the path that reaches furthest.
                let deletion = frontier[diagonal - 1].flatMap { path -> Path? in
                    path.end < a.count ? (path.end + 1, path.run) : nil
                }
                let insertion = frontier[diagonal + 1].flatMap { path -> Path? in
                    path.end - (diagonal + 1) < b.count ? path : nil
                }
                let path: Path
                if edits == 0 { path = (0, nil) }
                else if let deletion, deletion.end >= (insertion?.end ?? -1) { path = deletion }
                else if let insertion { path = insertion }
                else { continue }

                var x = path.end, y = x - diagonal
                while x < a.count, y < b.count {
                    comparisonsLeft -= 1
                    guard comparisonsLeft >= 0 else { return nil }
                    guard a[x] == b[y] else { break }
                    x += 1
                    y += 1
                }
                var run = path.run
                if x > path.end {
                    runs.append(Run(editor: path.end, disk: path.end - diagonal,
                                    length: x - path.end, previous: run))
                    run = runs.count - 1
                }
                if x == a.count && y == b.count {
                    var result: [Run] = []
                    while let index = run {
                        result.append(runs[index])
                        run = runs[index].previous
                    }
                    return result.reversed()
                }
                next[diagonal] = (x, run)
            }
            frontier = next
        }
        return nil
    }
}
