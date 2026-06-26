import CoreGraphics
import Foundation
import Testing
@testable import MD2App

struct ExportProfileTests {
    // MARK: - Default profile reproduces prior output

    @Test func defaultProfileIsA4PortraitNarrowWithNoRunningText() {
        let profile = ExportProfile.default

        #expect(profile.pageSize == .a4)
        #expect(profile.orientation == .portrait)
        #expect(profile.margins == .preset(.narrow))
        #expect(profile.showsPageNumbers == false)
        #expect(profile.header.isEmpty)
        #expect(profile.footer.isEmpty)
        #expect(profile.hasRunningText == false)
    }

    @Test func defaultPageGeometryMatchesPreviousFixedConstants() {
        // The previous PDFExporter constants were A4 (595.28 × 841.89) and a
        // uniform 36pt narrow margin; the default profile must resolve to those.
        let profile = ExportProfile.default

        #expect(abs(profile.pageSizePoints.width - 595.28) < 0.01)
        #expect(abs(profile.pageSizePoints.height - 841.89) < 0.01)
        let insets = profile.marginInsets
        #expect(insets.top == 36)
        #expect(insets.left == 36)
        #expect(insets.bottom == 36)
        #expect(insets.right == 36)
    }

    // MARK: - Page size & orientation

    @Test func pageSizePointsAreCorrect() {
        #expect(PageSize.letter.portraitPoints == CGSize(width: 612, height: 792))
        #expect(PageSize.legal.portraitPoints == CGSize(width: 612, height: 1008))
    }

    @Test func landscapeSwapsWidthAndHeight() {
        var profile = ExportProfile(pageSize: .letter, orientation: .landscape)
        #expect(profile.pageSizePoints == CGSize(width: 792, height: 612))
        #expect(profile.pageSizePoints.width > profile.pageSizePoints.height)

        profile.orientation = .portrait
        #expect(profile.pageSizePoints == CGSize(width: 612, height: 792))
    }

    // MARK: - Margins

    @Test func marginPresetPointsAreCorrect() {
        #expect(PageMargins.MarginPreset.none.points == 0)
        #expect(PageMargins.MarginPreset.narrow.points == 36)
        #expect(PageMargins.MarginPreset.normal.points == 72)
        #expect(PageMargins.MarginPreset.wide.points == 108)
    }

    @Test func presetMarginsResolveUniformly() {
        let insets = PageMargins.preset(.wide).insets
        #expect(insets == EdgeInsetsPoints(top: 108, left: 108, bottom: 108, right: 108))
    }

    @Test func customMarginsResolvePerSideAndClampNegatives() {
        let insets = PageMargins.custom(top: 10, left: 20, bottom: -5, right: 40).insets
        #expect(insets == EdgeInsetsPoints(top: 10, left: 20, bottom: 0, right: 40))
    }

    // MARK: - Running text & tokens

    @Test func hasRunningTextReflectsAnyActiveContent() {
        #expect(ExportProfile(showsPageNumbers: true).hasRunningText)
        #expect(ExportProfile(header: RunningText(center: "Draft")).hasRunningText)
        #expect(ExportProfile(footer: RunningText(right: "{page}")).hasRunningText)
        #expect(ExportProfile().hasRunningText == false)
    }

    @Test func tokenResolverSubstitutesAllTokens() {
        let context = RunningTextContext(title: "My Doc", date: "2026-06-25", page: 3, pageCount: 12)
        #expect(RunningTextToken.resolve("{title}", with: context) == "My Doc")
        #expect(RunningTextToken.resolve("{date}", with: context) == "2026-06-25")
        #expect(RunningTextToken.resolve("{page} / {pageCount}", with: context) == "3 / 12")
        #expect(
            RunningTextToken.resolve("{title} — page {page}", with: context) == "My Doc — page 3"
        )
    }

    @Test func tokenResolverLeavesPlainTextUntouched() {
        let context = RunningTextContext(title: "T", date: "D", page: 1, pageCount: 1)
        #expect(RunningTextToken.resolve("Confidential", with: context) == "Confidential")
        #expect(RunningTextToken.resolve("", with: context) == "")
    }

    // MARK: - Codable round-trip (persistence)

    @Test func profileSurvivesCodableRoundTrip() throws {
        let original = ExportProfile(
            pageSize: .legal,
            orientation: .landscape,
            margins: .custom(top: 10, left: 20, bottom: 30, right: 40),
            showsPageNumbers: true,
            pageNumberAlignment: .right,
            header: RunningText(left: "{title}", center: "", right: "{date}"),
            footer: RunningText(center: "{page} / {pageCount}"),
            runningTextFontSize: 11
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ExportProfile.self, from: data)

        #expect(decoded == original)
    }

    @Test func presetMarginsSurviveCodableRoundTrip() throws {
        let original = ExportProfile(margins: .preset(.normal))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ExportProfile.self, from: data)
        #expect(decoded.margins == .preset(.normal))
    }
}
