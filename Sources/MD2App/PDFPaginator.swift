import CoreGraphics
import Foundation

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
}
