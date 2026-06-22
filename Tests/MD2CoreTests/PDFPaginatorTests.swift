import CoreGraphics
import XCTest
@testable import MD2App

final class PDFPaginatorTests: XCTestCase {
    // MARK: - Fixed bands (no safe breaks)

    func testTallContentSplitsIntoFixedBands() {
        // 2000 tall, 720 band, no cuts → 720, 720, 560.
        let bands = PDFPaginator.bands(sourceHeight: 2000, maxBand: 720, cuts: [])
        XCTAssertEqual(bands?.count, 3)
        XCTAssertEqual(bands?[0].height ?? -1, 720, accuracy: 0.01)
        XCTAssertEqual(bands?[2].height ?? -1, 560, accuracy: 0.01)
    }

    func testShortContentIsASingleBand() {
        let bands = PDFPaginator.bands(sourceHeight: 300, maxBand: 720, cuts: [])
        XCTAssertEqual(bands?.count, 1)
        XCTAssertEqual(bands?[0].height ?? -1, 300, accuracy: 0.01)
    }

    func testZeroHeightStillProducesOneBand() {
        // Defensive: never return an empty band list.
        XCTAssertEqual(PDFPaginator.bands(sourceHeight: 0, maxBand: 720, cuts: [])?.count, 1)
    }

    // MARK: - Safe-break snapping

    func testBreaksEndPagesAtSafePositions() {
        // Safe breaks at 700 and 1390 → (0–700), (700–1390), (1390–2000).
        let bands = PDFPaginator.bands(sourceHeight: 2000, maxBand: 720, cuts: [700, 1390])
        XCTAssertEqual(bands?.count, 3)
        XCTAssertEqual(bands?[0].height ?? -1, 700, accuracy: 0.01)
        XCTAssertEqual(bands?[1].height ?? -1, 690, accuracy: 0.01)
    }

    func testEarlyBreakForcesMorePages() {
        // A single break at 100 → (0–100), (100–820), (820–1540), (1540–2000) = 4.
        let bands = PDFPaginator.bands(sourceHeight: 2000, maxBand: 720, cuts: [100])
        XCTAssertEqual(bands?.count, 4)
        XCTAssertEqual(bands?[0].height ?? -1, 100, accuracy: 0.01)
    }

    func testUnsortedCutsPickTheLargestThatFits() {
        // `bands` sorts internally, so caller order does not matter: the page must
        // still end at 710 (largest break <= 720), not 700.
        let bands = PDFPaginator.bands(sourceHeight: 2000, maxBand: 720, cuts: [700, 710, 60])
        XCTAssertEqual(bands?[0].height ?? -1, 710, accuracy: 0.01)
    }

    // MARK: - Boundary cases (line/image edges vs the page limit)

    func testLineBottomExactlyAtLimitEndsPageThere() {
        // A safe break exactly at the page limit (720) is honored (cut <= limit),
        // so page 1 ends precisely at the line bottom — no off-by-one split.
        let bands = PDFPaginator.bands(sourceHeight: 1500, maxBand: 720, cuts: [720])
        XCTAssertEqual(bands?.first?.top ?? -1, 0, accuracy: 0.01)
        XCTAssertEqual(bands?.first?.height ?? -1, 720, accuracy: 0.01)
    }

    func testImageTopJustBeforeLimitPushesImageToNextPage() {
        // Image spans 700..1300; its top (700) is the last safe break <= 720, so
        // page 1 ends at 700 and the image starts page 2 intact (never split).
        let bands = PDFPaginator.bands(sourceHeight: 1400, maxBand: 720, cuts: [700, 1300])
        XCTAssertEqual(bands?[0].height ?? -1, 700, accuracy: 0.01) // page 1 ends at image top
        XCTAssertEqual(bands?[1].top ?? -1, 700, accuracy: 0.01)    // page 2 starts at image top
    }

    func testImageTopExactlyAtPageStartIsNotResplit() {
        // When a page begins exactly at an image top, the same-position break must
        // not be re-selected (cut must advance past `top`), so the image fills the
        // page instead of producing a zero-height page.
        let bands = PDFPaginator.bands(sourceHeight: 1300, maxBand: 720, cuts: [0, 600])
        XCTAssertEqual(bands?[0].top ?? -1, 0, accuracy: 0.01)
        XCTAssertGreaterThan(bands?[0].height ?? 0, 0)
    }

    func testImageBottomExactlyAtLimitKeepsImageWhole() {
        // Image 0..720 with its bottom exactly at the limit fits wholly on page 1.
        let bands = PDFPaginator.bands(sourceHeight: 1500, maxBand: 720, cuts: [720])
        XCTAssertEqual(bands?[0].height ?? -1, 720, accuracy: 0.01)
    }

    // MARK: - Guard rails

    func testRunawayContentIsRejected() {
        // Content so tall it would exceed the page ceiling must not be emitted.
        let bands = PDFPaginator.bands(
            sourceHeight: 720 * CGFloat(PDFPaginator.maxPages + 10),
            maxBand: 720,
            cuts: []
        )
        XCTAssertNil(bands)
    }

    // MARK: - Band height invariant

    func testNoBandExceedsMaxBand() {
        // The compose step draws each band top-aligned in a printable box and must
        // never need to clip content away, so no band may be taller than `maxBand`.
        let cases: [(CGFloat, CGFloat, [CGFloat])] = [
            (2000, 720, []),
            (2000, 720, [700, 1390]),
            (2000, 720, [100]),
            (1517.5, 723.89, [120.4, 500.2, 1300.9]), // non-integer, A4-like
            (5000, 745.89, Array(stride(from: 30.0, to: 5000.0, by: 31.5)).map { CGFloat($0) }),
        ]
        for (height, maxBand, cuts) in cases {
            guard let bands = PDFPaginator.bands(sourceHeight: height, maxBand: maxBand, cuts: cuts) else {
                XCTFail("expected bands for height=\(height)")
                continue
            }
            for band in bands {
                XCTAssertLessThanOrEqual(
                    band.height, maxBand + 0.01,
                    "band height \(band.height) exceeds maxBand \(maxBand)"
                )
            }
            // Bands must tile [0, height] exactly, with no gap or overlap.
            XCTAssertEqual(bands.first?.top ?? -1, 0, accuracy: 0.01)
            XCTAssertEqual((bands.last.map { $0.top + $0.height }) ?? -1, height, accuracy: 0.01)
        }
    }

    // MARK: - Fit scale (width-fit, never exceed height)

    func testFitScaleIsOneWhenBandFitsBox() {
        // Normal band: width equals the printable width and height is below it
        // (the exporter caps band height with a cushion) → no down-scaling.
        let scale = PDFPaginator.fitScale(
            source: CGSize(width: 499, height: 700),
            into: CGSize(width: 499, height: 745)
        )
        XCTAssertEqual(scale, 1, accuracy: 0.0001)
    }

    func testFitScaleShrinksToFitHeight() {
        // A single atomic block taller than a page scales down to fit the height.
        let scale = PDFPaginator.fitScale(
            source: CGSize(width: 499, height: 1490),
            into: CGSize(width: 499, height: 745)
        )
        XCTAssertEqual(scale, 0.5, accuracy: 0.0001)
    }

    func testFitScaleShrinksToFitWidth() {
        // A source wider than the box scales down so its width fits.
        let scale = PDFPaginator.fitScale(
            source: CGSize(width: 998, height: 700),
            into: CGSize(width: 499, height: 745)
        )
        XCTAssertEqual(scale, 0.5, accuracy: 0.0001)
    }

    func testFitScaleNeverLeavesContentLargerThanBox() {
        // Whatever the source, the scaled size must fit within the box.
        let box = CGSize(width: 499, height: 745)
        for source in [CGSize(width: 998, height: 300),
                       CGSize(width: 300, height: 2000),
                       CGSize(width: 1200, height: 1600)] {
            let scale = PDFPaginator.fitScale(source: source, into: box)
            XCTAssertLessThanOrEqual(source.width * scale, box.width + 0.01)
            XCTAssertLessThanOrEqual(source.height * scale, box.height + 0.01)
        }
    }

    func testFitScaleDegenerateInputReturnsOne() {
        XCTAssertEqual(PDFPaginator.fitScale(source: .zero, into: CGSize(width: 499, height: 745)), 1)
        XCTAssertEqual(PDFPaginator.fitScale(source: CGSize(width: 499, height: 700), into: .zero), 1)
    }
}
