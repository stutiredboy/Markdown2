import AppKit

/// A document's editor text system — the TextKit 1 stack and the source text
/// view — created once and kept alive across mode switches.
///
/// `NSTextView` records every undoable edit as an action whose target is the
/// text view itself, unretained, so the text view must outlive every action on
/// its undo manager. A text view built per editor would be freed by each mode
/// switch while its actions stayed on the stack, and Undo after Write → Read →
/// Write would message a deallocated object. The document therefore owns this
/// session, and with it the only text view it ever gets: each new editor scroll
/// view re-hosts that view, so the undo history and the selection survive the
/// switch.
///
/// The session is also the text view's permanent delegate. `NSText.delegate` is
/// `assign`, so pointing a long-lived text view at a coordinator SwiftUI may
/// release would leave it dangling; the session instead forwards to whichever
/// coordinator is mounted (held weakly). While none is — Read mode — undo and
/// redo still change the text view, and the session hands that text straight to
/// the document, so Edit ▸ Undo keeps working there.
@MainActor
final class MarkdownEditorSession: NSObject, NSTextViewDelegate {
    /// The document's undo manager: the window returns it to the Edit menu and
    /// the text view registers its edits on it.
    let undoManager: UndoManager
    /// Receives the new text when the text view changes while no editor is
    /// mounted (undo/redo or a checkbox toggle in Read mode).
    var onUnmountedTextChange: ((String) -> Void)?

    private(set) var textView: NSTextView?
    private weak var coordinator: MarkdownEditorView.Coordinator?
    /// True while `applyUndoableEdit` runs, so the mounted editor can tell the
    /// document's own edit from typing.
    private(set) var isApplyingDocumentEdit = false

    init(undoManager: UndoManager = UndoManager()) {
        self.undoManager = undoManager
    }

    /// The session's text view, built on first use with `text` as its content.
    func loadTextView(text: String) -> NSTextView {
        if let textView { return textView }

        // Build the TextKit 1 stack manually so the editor uses a custom layout
        // manager that paints continuous code-block backgrounds.
        let textStorage = NSTextStorage()
        let layoutManager = CodeBlockLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(
            containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        )
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)

        let textView = MarkdownSourceTextView(frame: .zero, textContainer: textContainer)
        // Accept image file drops on top of whatever the text view already takes
        // (string drags for in-editor text move), so the drop handler can turn
        // dropped images into attachments without disabling text drag-and-drop.
        textView.registerForDraggedTypes(textView.registeredDraggedTypes + [.fileURL])
        textView.delegate = self
        textView.string = text
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.textContainerInset = NSSize(width: 58, height: 48)
        textView.backgroundColor = .textBackgroundColor
        textView.drawsBackground = true
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        self.textView = textView
        return textView
    }

    /// Makes the text view `scrollView`'s document view, taking it out of the
    /// scroll view that hosted it before, and routes its delegate callbacks to
    /// `coordinator`. SwiftUI may build the next editor before tearing down the
    /// previous one, so this does not wait for `unhost`.
    func host(in scrollView: NSScrollView, coordinator: MarkdownEditorView.Coordinator) {
        guard let textView else { return }
        if let previous = textView.enclosingScrollView, previous !== scrollView {
            previous.documentView = nil
        }
        // The text view tracks its host's width through autoresizing, which only
        // applies size *changes*. Give it the new host's current (still zero)
        // size, as a freshly built view starts, so it follows this scroll view
        // instead of keeping its previous host's width on top.
        textView.frame = NSRect(origin: .zero, size: scrollView.contentSize)
        textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
        // Find highlights belong to the editor that painted them; a new editor
        // starts with no search, so none may survive the switch.
        if let layoutManager = textView.layoutManager {
            layoutManager.removeTemporaryAttribute(
                .backgroundColor,
                forCharacterRange: NSRange(location: 0, length: (textView.string as NSString).length)
            )
        }
        self.coordinator = coordinator
        scrollView.documentView = textView
    }

    /// Detaches the text view from an editor SwiftUI is tearing down, unless a
    /// newer editor has already re-hosted it.
    func unhost(from scrollView: NSScrollView, coordinator: MarkdownEditorView.Coordinator) {
        guard let textView, self.coordinator === coordinator else { return }
        self.coordinator = nil
        if textView.enclosingScrollView === scrollView {
            scrollView.documentView = nil
        }
    }

    /// Applies a document-originated change — a preview checkbox toggle — through
    /// the text view's editing path, so it lands on the undo stack in order with
    /// the user's typing and Undo reverts it. Builds the text view if the editor
    /// was never shown. Returns false, leaving the caller to change the text
    /// itself (without undo), when the text view cannot take the edit: an input
    /// method owns marked text, or its content is not `current`.
    func applyUndoableEdit(changing current: String, to newText: String) -> Bool {
        let textView = loadTextView(text: current)
        // A literal (code-unit) comparison: the edit's range is computed in UTF-16
        // offsets, which canonical-equivalence `==` would not guarantee match.
        guard let storage = textView.textStorage,
              !textView.hasMarkedText(),
              (storage.string as NSString).isEqual(to: current) else { return false }
        guard let change = TextReplacement(from: storage.string, to: newText) else { return true }

        // Its own undo group: never merged into the typing that came before.
        textView.breakUndoCoalescing()
        isApplyingDocumentEdit = true
        defer { isApplyingDocumentEdit = false }
        guard textView.shouldChangeText(in: change.range, replacementString: change.replacement) else {
            return false
        }
        storage.replaceCharacters(in: change.range, with: change.replacement)
        textView.didChangeText()
        textView.breakUndoCoalescing()
        return true
    }

    /// Mirrors a change the undo history cannot describe — opening a file, a
    /// reload from disk, or any text that reached the document without passing
    /// through the editor — and clears that history: every recorded action
    /// addresses ranges of the text just replaced, so undoing one would raise or
    /// silently corrupt the document (NSDocument revert semantics). The change is
    /// applied as one minimal replacement that records no undo action, keeping
    /// the styling, layout, and selection of the text around it. Returns false,
    /// changing nothing, while an input method owns marked text; the mounted
    /// editor applies the text once composition ends.
    @discardableResult
    func resetText(to newText: String) -> Bool {
        guard let textView, let storage = textView.textStorage else {
            undoManager.removeAllActions()
            return true
        }
        guard !textView.hasMarkedText() else { return false }

        if let change = TextReplacement(from: storage.string, to: newText) {
            storage.replaceCharacters(in: change.range, with: change.replacement)
            // TextKit moves the selection with the edit; clamp defensively, since
            // restoring a selection past the end raises.
            let length = storage.length
            textView.selectedRanges = textView.selectedRanges.map { value in
                let range = value.rangeValue
                let location = min(range.location, length)
                return NSValue(range: NSRange(location: location, length: min(range.length, length - location)))
            }
            coordinator?.textWasReplaced(in: textView)
        }
        textView.breakUndoCoalescing()
        undoManager.removeAllActions()
        return true
    }

    // MARK: NSTextViewDelegate

    func undoManager(for view: NSTextView) -> UndoManager? {
        undoManager
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        coordinator?.textView(textView, doCommandBy: commandSelector) ?? false
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        coordinator?.textViewDidChangeSelection(notification)
    }

    func textDidChange(_ notification: Notification) {
        if let coordinator {
            coordinator.textDidChange(notification)
        } else if let textView, !textView.hasMarkedText() {
            onUnmountedTextChange?(textView.string)
        }
    }
}

/// The single replacement that turns one text into another: the UTF-16 range of
/// the old text between the two texts' common prefix and suffix, and the new
/// text that replaces it. Editing only that range leaves the attributes,
/// layout, and selection of everything around the change alone.
struct TextReplacement: Equatable {
    let range: NSRange
    let replacement: String

    /// `nil` when the texts are identical. The boundaries never split a
    /// surrogate pair, so `replacement` is always well-formed.
    init?(from old: String, to new: String) {
        let oldUnits = Array(old.utf16)
        let newUnits = Array(new.utf16)
        let shorter = min(oldUnits.count, newUnits.count)

        var prefix = 0
        while prefix < shorter, oldUnits[prefix] == newUnits[prefix] { prefix += 1 }
        if prefix == oldUnits.count, prefix == newUnits.count { return nil }
        if prefix > 0, UTF16.isLeadSurrogate(oldUnits[prefix - 1]) { prefix -= 1 }

        var suffix = 0
        while suffix < shorter - prefix,
              oldUnits[oldUnits.count - 1 - suffix] == newUnits[newUnits.count - 1 - suffix] {
            suffix += 1
        }
        if suffix > 0, UTF16.isTrailSurrogate(oldUnits[oldUnits.count - suffix]) { suffix -= 1 }

        range = NSRange(location: prefix, length: oldUnits.count - suffix - prefix)
        replacement = (new as NSString).substring(
            with: NSRange(location: prefix, length: newUnits.count - suffix - prefix)
        )
    }
}
