import CoreGraphics
import Foundation
import MD2Core

/// Computes print page bands for the PDF exporter. Given the document height and
/// the safe break offsets discovered in the rendered page, it splits the content
/// into pages — each at most a printable height tall and ending at the largest
/// safe break that fits — so a line of text or an atomic block is never sliced
/// across a page boundary. The exporter captures each band separately and
/// composes them onto fixed-size pages.
///
/// This is pure geometry with no WebKit/AppKit dependency, so it can be exercised
/// in isolation. It deliberately replaces `NSPrintOperation`'s pagination of an
/// offscreen web view, which produced structurally invalid, multi-gigabyte output
/// (millions of empty pages with no page-tree root).
enum PDFPaginator {
    /// Per-side page margins, in points.
    struct Margins: Equatable {
        var top: CGFloat
        var left: CGFloat
        var bottom: CGFloat
        var right: CGFloat

        init(top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat) {
            self.top = top
            self.left = left
            self.bottom = bottom
            self.right = right
        }

        init(uniform: CGFloat) {
            self.init(top: uniform, left: uniform, bottom: uniform, right: uniform)
        }
    }

    /// Hard ceiling so a degenerate source can never produce a runaway document.
    static let maxPages = 5000

    /// Greedily splits `[0, sourceHeight]` into bands of at most `maxBand`, ending
    /// each at the largest safe `cut` that fits. `cuts` are safe break offsets
    /// from the top of the document, in the same coordinate space as
    /// `sourceHeight` and `maxBand`; they need not be sorted. Returns `nil` if the
    /// band count would exceed `maxPages`.
    static func bands(
        sourceHeight: CGFloat,
        maxBand: CGFloat,
        cuts: [CGFloat]
    ) -> [(top: CGFloat, height: CGFloat)]? {
        let sortedCuts = cuts.sorted()
        var bands: [(top: CGFloat, height: CGFloat)] = []
        var top: CGFloat = 0
        while top < sourceHeight - 0.5 {
            if bands.count >= maxPages { return nil }
            let limit = top + maxBand
            var cut = min(limit, sourceHeight)
            // Only snap to a safe break when the page would otherwise split
            // content mid-document (the final page just runs to the end).
            if !sortedCuts.isEmpty, limit < sourceHeight,
               let safe = sortedCuts.last(where: { $0 > top + 1 && $0 <= limit }) {
                cut = safe
            }
            if cut <= top { cut = min(limit, sourceHeight) } // guarantee progress
            bands.append((top: top, height: cut - top))
            top = cut
        }
        if bands.isEmpty {
            bands.append((top: 0, height: min(maxBand, sourceHeight)))
        }
        return bands
    }

    /// The uniform scale that fits a captured `source` rect into the printable
    /// `box`, fitting width and never exceeding height. For a normal band the
    /// source width already equals the box width and the source height is below it
    /// (the exporter caps bands with a cushion), so this returns ≈1 — content draws
    /// at native size with no down-scaling. Only a degenerate source taller than
    /// the box (a single atomic block taller than a page) scales below 1 to fit.
    /// Returns 1 for an empty/degenerate input so a caller never divides by zero.
    static func fitScale(source: CGSize, into box: CGSize) -> CGFloat {
        guard source.width > 0, source.height > 0, box.width > 0, box.height > 0 else { return 1 }
        return min(box.width / source.width, box.height / source.height)
    }

    // MARK: - Outline (PDF bookmarks)

    /// A single heading resolved to its output page, ready to be nested into an
    /// outline tree. `pageIndex` is 0-based; `offsetInPage` is the heading's Y
    /// offset (CSS px) below the top of that page's printable area.
    struct OutlineEntry: Equatable {
        let title: String
        let level: Int
        let pageIndex: Int
        let offsetInPage: CGFloat

        init(title: String, level: Int, pageIndex: Int, offsetInPage: CGFloat) {
            self.title = title
            self.level = level
            self.pageIndex = pageIndex
            self.offsetInPage = offsetInPage
        }
    }

    /// A node in the hierarchical outline tree. A reference type so the tree can be
    /// assembled by appending children to ancestors while building.
    final class OutlineNode {
        let title: String
        let pageIndex: Int
        let offsetInPage: CGFloat
        var children: [OutlineNode]

        init(title: String, pageIndex: Int, offsetInPage: CGFloat, children: [OutlineNode] = []) {
            self.title = title
            self.pageIndex = pageIndex
            self.offsetInPage = offsetInPage
            self.children = children
        }
    }

    /// Returns the 0-based index of the page band whose half-open range
    /// `[top, top + height)` contains `offset`. An offset before the first band maps
    /// to page 0 and one at or past the last band maps to the last page, so a
    /// heading always resolves to a valid page. Returns 0 for an empty band list.
    static func pageIndex(forOffset offset: CGFloat, in bands: [(top: CGFloat, height: CGFloat)]) -> Int {
        guard !bands.isEmpty else { return 0 }
        if offset < bands[0].top { return 0 }
        for index in bands.indices {
            let band = bands[index]
            if offset >= band.top, offset < band.top + band.height {
                return index
            }
        }
        return bands.count - 1
    }

    /// Resolves document headings into outline entries, preserving heading order
    /// and requiring every heading to have a probed DOM offset. A missing offset
    /// means the PDF outline would be incomplete, so callers should fail export
    /// rather than silently write a PDF that violates the bookmark guarantee.
    static func outlineEntries(
        for headings: [Heading],
        headingOffsets: [String: CGFloat],
        bands: [(top: CGFloat, height: CGFloat)]
    ) -> [OutlineEntry]? {
        guard !headings.isEmpty else { return [] }
        guard !bands.isEmpty else { return nil }

        var entries: [OutlineEntry] = []
        entries.reserveCapacity(headings.count)
        for heading in headings {
            guard let offset = headingOffsets[heading.id], offset.isFinite else {
                return nil
            }
            let pageIndex = pageIndex(forOffset: offset, in: bands)
            let offsetInPage = max(0, offset - bands[pageIndex].top)
            entries.append(
                OutlineEntry(
                    title: heading.title,
                    level: heading.level,
                    pageIndex: pageIndex,
                    offsetInPage: offsetInPage
                )
            )
        }
        return entries
    }

    /// Builds an outline tree from `entries` in document order, nesting each entry
    /// under the nearest preceding entry of a *shallower* `level` (else as a root).
    /// Equal- or higher-level entries close the current branch, so a level jump back
    /// up (e.g. `3 → 1`) starts a new top-level node.
    static func outlineTree(from entries: [OutlineEntry]) -> [OutlineNode] {
        var roots: [OutlineNode] = []
        // Ancestor path: nodes paired with their source level, deepest last.
        var stack: [(node: OutlineNode, level: Int)] = []

        for entry in entries {
            let node = OutlineNode(
                title: entry.title,
                pageIndex: entry.pageIndex,
                offsetInPage: entry.offsetInPage
            )
            while let last = stack.last, last.level >= entry.level {
                stack.removeLast()
            }
            if let parent = stack.last?.node {
                parent.children.append(node)
            } else {
                roots.append(node)
            }
            stack.append((node, entry.level))
        }
        return roots
    }
}
