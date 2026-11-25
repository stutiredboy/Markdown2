import Foundation

struct EditorSourcePosition: Equatable {
    let line: Int
    let column: Int

    static let start = Self(line: 1, column: 1)
}

struct EditorSelection {
    let text: String?
    let start: EditorSourcePosition
    let end: EditorSourcePosition
}

/// Keep a checkpoint at each visited line start and along unusually long lines.
/// TextKit offsets are UTF-16; columns count user-perceived characters.
struct EditorSourceIndex {
    private static let lineBreaks = CharacterSet(charactersIn: "\r\n")
    private static let stride = 1024
    private var checkpoints = [(offset: 0, position: EditorSourcePosition.start)]

    mutating func invalidate(from editStart: Int) {
        // Inserting LF after CR or a combining mark after a base character can
        // change the boundary immediately before the reported edit.
        let safeOffset = max(0, editStart - 1)
        if checkpoints.last!.offset > safeOffset {
            checkpoints.removeSubrange(index(at: safeOffset) + 1 ..< checkpoints.count)
        }
    }

    mutating func line(at offset: Int, in source: NSString) -> Int {
        let checkpoint = checkpoint(at: offset, in: source)
        return checkpoint.position.line
    }

    mutating func position(at offset: Int, in source: NSString) -> EditorSourcePosition {
        let target = min(max(0, offset), source.length)
        let checkpoint = checkpoint(at: target, in: source)
        let count = source.substring(with: NSRange(location: checkpoint.offset, length: target - checkpoint.offset)).count
        return EditorSourcePosition(line: checkpoint.position.line, column: checkpoint.position.column + count)
    }

    private mutating func checkpoint(at offset: Int, in source: NSString) -> (offset: Int, position: EditorSourcePosition) {
        let target = min(max(0, offset), source.length)
        while let last = checkpoints.last, last.offset < target {
            let remaining = NSRange(location: last.offset, length: target - last.offset)
            let next = source.rangeOfCharacter(from: Self.lineBreaks, options: .literal, range: remaining)
            let end = next.location == NSNotFound ? target : next.location
            if end - last.offset > Self.stride {
                // Walk graphemes forward once. An NSString composed-range lookup
                // at every checkpoint can rescan a whole regional-indicator run.
                var segment = source.substring(with: NSRange(location: last.offset, length: end - last.offset))
                segment.makeContiguousUTF8()
                var cursor = segment.startIndex
                var location = last.offset
                var column = last.position.column
                while let boundary = segment.index(cursor, offsetBy: Self.stride, limitedBy: segment.endIndex),
                      boundary < segment.endIndex {
                    location += segment[cursor..<boundary].utf16.count
                    column += Self.stride
                    checkpoints.append((location, EditorSourcePosition(line: last.position.line, column: column)))
                    cursor = boundary
                }
            }
            guard next.location != NSNotFound else { break }
            var afterBreak = NSMaxRange(next)
            if source.character(at: next.location) == 0x0D, afterBreak < source.length,
               source.character(at: afterBreak) == 0x0A { afterBreak += 1 }
            checkpoints.append((afterBreak, EditorSourcePosition(line: last.position.line + 1, column: 1)))
        }
        return checkpoints[index(at: target)]
    }

    private func index(at offset: Int) -> Int {
        var lower = 0
        var upper = checkpoints.count
        while upper - lower > 1 {
            let middle = lower + (upper - lower) / 2
            if checkpoints[middle].offset <= offset { lower = middle } else { upper = middle }
        }
        return lower
    }
}
