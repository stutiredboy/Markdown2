import Foundation
import Testing
@testable import MD2App
@testable import MD2Core

@MainActor
struct PreviewReaderUXTests {
    @Test func frontMatterDetectionOnlyEnablesMetadataForParsedFields() {
        let markdown = """
        ---
        title: Notes
        ---

        # Body
        """

        #expect(FrontMatterMetadataVisibility.hasDisplayableFrontMatter(in: markdown))
        #expect(!FrontMatterMetadataVisibility.hasDisplayableFrontMatter(in: "# Body"))
        #expect(!FrontMatterMetadataVisibility.hasDisplayableFrontMatter(in: "---\nnot closed"))
    }

    @Test func sharedRendererStillEmitsFrontMatterForExports() {
        let markdown = """
        ---
        title: Notes
        ---

        # Body
        """

        let document = MarkdownRenderer().render(markdown)
        let body = document.body.withoutSourceLineMetadata

        #expect(body.contains(#"<pre class="front-matter"><code>title: Notes</code></pre>"#))
        #expect(document.html.contains(#"<pre class="front-matter""#))
        #expect(document.html.contains(#"<h1 id="body" data-md2-source-line="5">Body</h1>"#))
    }

    @Test func previewHelpersEncodeFrontMatterVisibilityAsJSBooleans() {
        #expect(MarkdownPreviewView.jsBoolean(true) == "true")
        #expect(MarkdownPreviewView.jsBoolean(false) == "false")
    }

    @Test func imageFailureKindDistinguishesRemoteLocalAndGenericSources() {
        #expect(MarkdownPreviewView.imageFailureKind(for: " https://example.com/a.png ") == .remote)
        #expect(MarkdownPreviewView.imageFailureKind(for: "http://example.com/a.png") == .remote)
        #expect(MarkdownPreviewView.imageFailureKind(for: "assets/a.png") == .local)
        #expect(MarkdownPreviewView.imageFailureKind(for: "/tmp/a.png") == .local)
        #expect(MarkdownPreviewView.imageFailureKind(for: "file:///tmp/a.png") == .local)
        #expect(MarkdownPreviewView.imageFailureKind(for: "\(LocalImageSchemeHandler.scheme)://image/token") == .local)
        #expect(MarkdownPreviewView.imageFailureKind(for: "data:image/png;base64,broken") == .generic)
        #expect(MarkdownPreviewView.imageFailureKind(for: "blob:https://example.com/token") == .generic)
    }

    @Test func splitLayoutMinimumWidthAccountsForOutlineAndPaneMinimums() {
        #expect(DocumentLayoutMetrics.splitEditorMinWidth == 360)
        #expect(DocumentLayoutMetrics.splitPreviewMinWidth == 420)
        #expect(DocumentLayoutMetrics.outlineSidebarWidth == 230)
        #expect(DocumentLayoutMetrics.minimumWindowWidth(mode: .write, showsOutline: true) == 780)
        #expect(DocumentLayoutMetrics.minimumWindowWidth(mode: .read, showsOutline: true) == 780)
        #expect(DocumentLayoutMetrics.minimumWindowWidth(mode: .split, showsOutline: false) == 816)
        #expect(DocumentLayoutMetrics.minimumWindowWidth(mode: .split, showsOutline: true) == 1046)
    }

    @Test func splitEditSyncGateSuppressesPreviewDrivenEditorSyncDuringEditWindow() {
        let editAt = Date(timeIntervalSinceReferenceDate: 1_000)
        let deadline = SplitEditSyncGate.suppressionDeadline(afterEditAt: editAt)

        #expect(abs(deadline.timeIntervalSince(editAt) - SplitEditSyncGate.editSuppressionWindow) < 0.001)
        #expect(!SplitEditSyncGate.allowsPreviewDrivenEditorSync(
            now: editAt.addingTimeInterval(SplitEditSyncGate.editSuppressionWindow - 0.01),
            suppressUntil: deadline
        ))
        #expect(SplitEditSyncGate.allowsPreviewDrivenEditorSync(
            now: deadline,
            suppressUntil: deadline
        ))
    }

    @Test func outlineKeyboardNavigationSelectsPredictably() {
        let headings = [
            Heading(id: "intro", level: 1, title: "Intro", line: 1),
            Heading(id: "setup", level: 2, title: "Setup", line: 8),
            Heading(id: "usage", level: 2, title: "Usage", line: 20)
        ]

        #expect(OutlineKeyboardNavigation.selectedID(after: .down, in: headings, currentID: nil) == "intro")
        #expect(OutlineKeyboardNavigation.selectedID(after: .up, in: headings, currentID: nil) == "usage")
        #expect(OutlineKeyboardNavigation.selectedID(after: .down, in: headings, currentID: "intro") == "setup")
        #expect(OutlineKeyboardNavigation.selectedID(after: .up, in: headings, currentID: "usage") == "setup")
        #expect(OutlineKeyboardNavigation.selectedID(after: .up, in: headings, currentID: "intro") == "intro")
        #expect(OutlineKeyboardNavigation.selectedID(after: .down, in: headings, currentID: "usage") == "usage")
        #expect(OutlineKeyboardNavigation.selectedID(after: .down, in: [], currentID: nil) == nil)
    }

    @Test func readerUXLocalizationKeysResolveInSupportedLanguages() {
        let english = AppSettings(defaults: UserDefaults(suiteName: "PreviewReaderUXTests-en-\(UUID().uuidString)")!)
        english.language = .english
        #expect(english.text(.showMetadata) == "Show metadata")
        #expect(english.text(.hideMetadata) == "Hide metadata")
        #expect(english.text(.remoteImageUnavailable) == "Remote image could not be loaded")
        #expect(english.text(.imageLoadFailed) == "Image could not be loaded")
        #expect(english.text(.navigateToHeading) == "Navigate to heading")

        let chinese = AppSettings(defaults: UserDefaults(suiteName: "PreviewReaderUXTests-zh-\(UUID().uuidString)")!)
        chinese.language = .zhHans
        #expect(chinese.text(.showMetadata) == "显示元数据")
        #expect(chinese.text(.hideMetadata) == "隐藏元数据")
        #expect(chinese.text(.remoteImageUnavailable) == "无法加载远程图片")
        #expect(chinese.text(.imageLoadFailed) == "无法加载图片")
        #expect(chinese.text(.navigateToHeading) == "跳转到标题")
    }
}
