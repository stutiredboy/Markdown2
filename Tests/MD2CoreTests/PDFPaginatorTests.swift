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
}
