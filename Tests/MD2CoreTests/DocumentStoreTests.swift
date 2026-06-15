import Foundation
import Testing
@testable import MD2App
@testable import MD2Core

@MainActor
struct DocumentStoreTests {
    @Test func newStoreIsReusableEmptyDocument() {
        let store = DocumentStore()

        #expect(store.isReusableEmptyDocument)
        #expect(store.fileURL == nil)
        #expect(!store.isDirty)
        #expect(store.displayTitle == "Untitled.md")
    }

    @Test func editingMarksDirtyAndNotReusable() {
        let store = DocumentStore()
        store.text = "# Changed\n\nNew body."

        #expect(store.isDirty)
        #expect(!store.isReusableEmptyDocument)
        #expect(store.displayTitle == "Untitled.md *")
    }

    @Test func reassigningSameTextDoesNotMarkDirty() {
        let store = DocumentStore()
        store.text = store.text

        #expect(!store.isDirty)
        #expect(store.isReusableEmptyDocument)
    }

    @Test func renderedDocumentTracksTextChanges() {
        let store = DocumentStore()
        store.text = "# Heading One\n\nSome words here."
        // The render that feeds the preview/stats is debounced off the keystroke
        // path; flush it so the synchronous assertions below see current content.
        store.flushPendingRender()

        #expect(store.rendered.outline.first?.title == "Heading One")
        #expect(store.rendered.html.contains("Heading One"))
        #expect(store.rendered.stats.words > 0)
    }

    @Test func toggleTaskChecksAndUnchecksMarker() {
        let store = DocumentStore()
        store.text = "# Title\n\n- [ ] Draft\n- [x] Review"

        store.toggleTask(atLine: 3, to: true)
        #expect(store.text == "# Title\n\n- [x] Draft\n- [x] Review")
        #expect(store.isDirty)

        store.toggleTask(atLine: 4, to: false)
        #expect(store.text == "# Title\n\n- [x] Draft\n- [ ] Review")
    }

    @Test func toggleTaskHandlesUppercaseMarker() {
        let store = DocumentStore()
        store.text = "- [X] Draft"

        store.toggleTask(atLine: 1, to: false)

        #expect(store.text == "- [ ] Draft")
    }

    @Test func toggleTaskPreservesNestingAndBlockquotePrefixes() {
        let store = DocumentStore()
        store.text = "- [ ] parent\n    - [ ] child\n\n> - [ ] quoted task"

        store.toggleTask(atLine: 2, to: true)
        store.toggleTask(atLine: 4, to: true)

        #expect(store.text == "- [ ] parent\n    - [x] child\n\n> - [x] quoted task")
    }

    @Test func toggleTaskIsIdempotentForDuplicateRequests() {
        let store = DocumentStore()
        store.text = "- [ ] once"

        store.toggleTask(atLine: 1, to: true)
        let afterFirst = store.text
        store.toggleTask(atLine: 1, to: true)

        #expect(store.text == afterFirst)
        #expect(store.text == "- [x] once")
    }

    @Test func toggleTaskIgnoresInvalidTargets() {
        let store = DocumentStore()
        let original = "# Title\n\nPlain paragraph.\n- [ ] task"
        store.text = original
        let dirtyBefore = store.isDirty

        store.toggleTask(atLine: 1, to: true) // heading, not a task
        store.toggleTask(atLine: 3, to: true) // paragraph, not a task
        store.toggleTask(atLine: 99, to: true) // out of range
        store.toggleTask(atLine: 0, to: true) // below range

        #expect(store.text == original)
        #expect(store.isDirty == dirtyBefore)
    }

    @Test func toggleTaskMatchesRendererTaskLineMetadata() {
        // The line the renderer stamps on the checkbox is the line the toggle
        // edits: round-trip one through the other.
        let store = DocumentStore()
        store.text = "# Title\n\n> note\n> - [ ] quoted\n\n- [ ] plain"
        store.flushPendingRender()

        #expect(store.rendered.html.contains(#"data-md2-task-line="4""#))
        #expect(store.rendered.html.contains(#"data-md2-task-line="6""#))

        store.toggleTask(atLine: 4, to: true)
        store.toggleTask(atLine: 6, to: true)

        #expect(store.text == "# Title\n\n> note\n> - [x] quoted\n\n- [x] plain")
    }
}
