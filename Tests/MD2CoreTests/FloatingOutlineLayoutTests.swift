import CoreGraphics
import Testing
@testable import MD2App

struct FloatingOutlineLayoutTests {
    @Test(arguments: [(ReadingWidth.narrow, CGFloat(1080)), (.comfortable, 1240), (.wide, 1540)])
    func centeredColumnRequires220PointsPerSide(option: (ReadingWidth, CGFloat)) {
        let (readingWidth, minimumPreviewWidth) = option
        let typography = TypographySettings(readingWidth: readingWidth)
        #expect(!showsOutline(width: minimumPreviewWidth - 0.5, typography: typography))
        #expect(showsOutline(width: minimumPreviewWidth, typography: typography))
        #expect(showsOutline(width: minimumPreviewWidth + 100, typography: typography))
    }

    @Test func respectsReadingWidthAndZoom() {
        let typography = TypographySettings(fontSize: 20, zoom: 1.1, readingWidth: .narrow)
        #expect(!showsOutline(width: 1319, typography: typography))
        #expect(showsOutline(width: 1320, typography: typography))
        #expect(!showsOutline(width: 10_000, typography: TypographySettings(readingWidth: .full)))
    }

    @Test func requiresReadModeHeadingsAndNoLeftOutline() {
        #expect(showsOutline())
        #expect(!showsOutline(mode: .write))
        #expect(!showsOutline(mode: .split))
        #expect(!showsOutline(hasHeadings: false))
        #expect(!showsOutline(showsLeftOutline: true))
    }

    @Test func folderOutlineOnlyTakesPrecedenceWhenVisible() {
        #expect(FloatingOutlineLayout.showsLeftOutline(standaloneOutline: true, folderSection: nil, folderSidebarVisible: false))
        #expect(!FloatingOutlineLayout.showsLeftOutline(standaloneOutline: false, folderSection: nil, folderSidebarVisible: false))
        #expect(FloatingOutlineLayout.showsLeftOutline(standaloneOutline: false, folderSection: .outline, folderSidebarVisible: true))
        #expect(!FloatingOutlineLayout.showsLeftOutline(standaloneOutline: true, folderSection: .outline, folderSidebarVisible: false))
        #expect(!FloatingOutlineLayout.showsLeftOutline(standaloneOutline: true, folderSection: .files, folderSidebarVisible: true))
    }

    @Test func waitsForWebKitAndAllowsSpaceForOverflowAndScrollbars() {
        #expect(!showsOutline(margin: nil))
        #expect(!showsOutline(margin: 219.5))
        #expect(showsOutline(margin: 220))
        #expect(!showsOutline(width: 1239, margin: 300))
    }

    private func showsOutline(
        mode: EditorMode = .read,
        hasHeadings: Bool = true,
        showsLeftOutline: Bool = false,
        width: CGFloat = 2000,
        typography: TypographySettings = TypographySettings(),
        margin: CGFloat? = 220
    ) -> Bool {
        FloatingOutlineLayout.isVisible(
            mode: mode, hasHeadings: hasHeadings, showsLeftOutline: showsLeftOutline,
            previewWidth: width, typography: typography, measuredMargin: margin
        )
    }
}
