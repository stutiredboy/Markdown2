import AppKit
import MD2Core
import SwiftUI
import UniformTypeIdentifiers

/// Fresh SwiftUI hosts can attach and acquire their size on different turns.
/// Notify the pending selection reveal when either prerequisite changes.
final class MarkdownEditorScrollView: NSScrollView {
    var onLayout: (() -> Void)?

    func attachEditor(_ editor: NSTextView) {
        // The clip view sizes its document during attachment. Seed it with the
        // retained width before SwiftUI's first layout so a zero-width mount
        // cannot force TextKit to rewrap the entire document.
        if contentSize.width <= 0 {
            let width = editor.frame.width > 0 ? editor.frame.width : DocumentLayoutMetrics.splitEditorMinWidth
            let size = NSScrollView.frameSize(forContentSize: NSSize(width: width, height: 1),
                horizontalScrollerClass: nil, verticalScrollerClass: hasVerticalScroller ? NSScroller.self : nil,
                borderType: borderType, controlSize: .regular, scrollerStyle: scrollerStyle)
            setFrameSize(size)
        }
        editor.setFrameOrigin(.zero)
        editor.setFrameSize(NSSize(width: contentSize.width, height: max(contentSize.height, editor.frame.height)))
        editor.minSize = NSSize(width: 0, height: contentSize.height)
        documentView = editor
    }

    override func layout() {
        super.layout()
        onLayout?()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onLayout?()
    }
}

/// Hands the surrounding view a way to read the editor's *live* viewport
/// anchor at the instant a mode switch is requested, instead of relying on
/// the last (possibly stale) debounced scroll callback.
@MainActor
final class EditorViewportReader {
    fileprivate var capture: (() -> ViewportAnchor?)?
    /// Reads the editor's top-of-viewport position as a fractional source line
    /// (the integer top line plus progress through that line's height) for smooth
    /// Side by Side follow.
    fileprivate var fractionalLine: (() -> Double?)?
    /// Scrolls the editor directly to a (possibly fractional) source line so it
    /// can follow the preview continuously, without a settle loop.
    fileprivate var scrollToLine: ((Double) -> Void)?

    /// The current top-of-viewport anchor from the live text view, or `nil`
    /// when the editor is not mounted or has no measurable geometry yet.
    func currentAnchor() -> ViewportAnchor? {
        capture?()
    }

    /// The editor's current top-of-viewport position as a fractional source line.
    func currentTopFractionalLine() -> Double? {
        fractionalLine?()
    }

    /// Drives the editor to follow the preview to `line` (continuous sync).
    func scrollToFollowLine(_ line: Double) {
        scrollToLine?(line)
    }
}

struct MarkdownEditorView: NSViewRepresentable {
    @Binding var text: String
    @Binding var jumpLine: Int?
    /// Fraction (0...1) to scroll to on mount when no line anchor applies.
    @Binding var jumpFraction: Double?
    /// Mode-switch viewport anchor to apply on mount; takes precedence over
    /// `jumpLine`/`jumpFraction` and is consumed once applied.
    @Binding var jumpAnchor: ViewportAnchor?
    /// Exposes on-demand capture of the live viewport anchor for mode switches.
    var viewportReader: EditorViewportReader?
    /// Reports the source line at the top of the visible rect whenever the
    /// viewport changes, so the surrounding view can anchor a mode switch to it.
    /// `drivesPreviewSync` is true when this change should pull the Side by Side
    /// preview into alignment — a genuine user scroll (wheel/drag) or the
    /// once-per-mode-switch settle — and false for edit-induced caret-reveal
    /// scrolls and follow-scroll settles, which must not drive the preview.
    var onAnchorLineChange: (_ line: Int, _ drivesPreviewSync: Bool) -> Void = { _, _ in }
    /// Called immediately when the user edits text, before the binding update
    /// triggers markdown rendering. Reports the 1-based source line of the caret
    /// after the edit so Side by Side can follow the editing position.
    var onTextEdit: (_ caretLine: Int) -> Void = { _ in }
    /// Called when the user presses Esc in the editor text. The owner decides
    /// what it means (dismiss a visible find bar first, else the single-pane
    /// switch-to-preview gesture).
    var onEnterPreview: () -> Void = {}
    /// The current edit-mode find query.
    @Binding var findQuery: String
    // Value inputs make option/scope mutations observable to SwiftUI even when
    // the native editor is the only visible pane. The session owns the values.
    var findOptions = TextSearch.Options()
    var findScope = FindSession.Scope.document
    var findUsesRegex = false
    var findRegexResultsEpoch: UInt64 = 0
    var validatesRegexReplacement = false
    /// Formatting reveal takes precedence over an automatic restored-query jump.
    var findMayRevealMatches = true
    /// A next/previous navigation request; consumed once applied.
    @Binding var findNavigation: FindCommand?
    /// Replacement text for edit-mode replace actions.
    @Binding var findReplacement: String
    /// A replace-current/all request; consumed once applied.
    @Binding var replaceCommand: FindReplaceCommand?
    /// Changes whenever the editor surface should become first responder.
    /// A folder tab without a request leaves focus in the file browser.
    let focusToken: UUID?
    /// A source line to select and reveal (a preview gutter click); applied
    /// once per token, after any mode-switch anchor has settled, then cleared
    /// so an editor mounted later does not replay it.
    @Binding var lineSelection: LineSelectionRequest?
    /// Programmatic line/anchor jumps usually focus the editor in single-pane
    /// mode. In Side by Side, the editor can be only the scroll follower, so it
    /// must not steal focus from the preview pane.
    var focusOnProgrammaticScroll: Bool = true
    /// Called when the text view receives a standard Find key/menu action before
    /// SwiftUI commands can route it through `DocumentStore`.
    var onFindShortcut: (_ action: FindCommand.Action) -> Void = { _ in }
    /// Reports match count and the 1-based index of the current match.
    var onFindResult: (_ total: Int, _ index: Int) -> Void = { _, _ in }
    /// Captures the intended range and source before asynchronous attachment
    /// work. DocumentStore performs guarded, undoable adoption on completion.
    var onInsertImageAttachments: (_ sources: [ImageAttachmentSource], _ range: NSRange, _ source: String) async -> Void = { _, _, _ in }
    /// Whether the source line-number gutter is drawn in the text view's left
    /// inset. Toggling it changes no text, selection, or geometry, so it cannot
    /// re-wrap the document; while it is on, clicking a number selects its line.
    var showsLineNumbers: Bool = false
    var usesTypewriterScrolling: Bool = false
    /// The document's editor text system. Every editor the document mounts
    /// re-hosts its one text view, so the undo history — whose actions target
    /// that view — survives mode switches. `nil` gives this editor a private
    /// session, for an editor not backed by a document.
    var session: MarkdownEditorSession? = nil
    var formatCommand: MarkdownFormatCommand? = nil
    var sourceAccessibilityLabel: String? = nil
    var typography: TypographySettings = .init()
    var onSelectionChange: (String?) -> Void = { _ in }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = MarkdownEditorScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true

        let coordinator = context.coordinator
        let session = coordinator.session
        coordinator.initializesCaretFromAnchor = session.textView == nil && jumpAnchor?.targetSourceLine != nil
        let textView = session.loadTextView(text: text)
        textView.setAccessibilityLabel(sourceAccessibilityLabel)
        (textView as? MarkdownSourceTextView)?.typography = typography
        session.host(in: scrollView, coordinator: coordinator)
        if let sourceTextView = textView as? MarkdownSourceTextView {
            // Weak: the text view outlives this editor and must not keep its
            // coordinator, or the SwiftUI state the callbacks capture, alive.
            sourceTextView.onFindAction = { [weak coordinator] action in
                coordinator?.onFindShortcut(action)
            }
            sourceTextView.onInsertImageAttachments = { [weak coordinator] sources, range, source in
                await coordinator?.onInsertImageAttachments(sources, range, source)
            }
            sourceTextView.showsLineNumbers = showsLineNumbers
        }
        // Document-level changes reach the kept text view through the session,
        // so it lags the binding only when one bypassed it.
        if coordinator.shouldApplyBoundText(text, to: textView) {
            session.resetText(to: text)
        }

        coordinator.scheduleStyle(in: textView)

        // Observe scrolling so the top visible line can anchor a mode switch.
        let clipView = scrollView.contentView
        clipView.postsBoundsChangedNotifications = true
        coordinator.observe(scrollView: scrollView)
        scrollView.onLayout = { [weak coordinator] in coordinator?.scheduleSelectionReveal() }
        coordinator.requestSelectionReveal(in: textView)

        viewportReader?.capture = { [weak scrollView] in
            guard let scrollView else { return nil }
            return Coordinator.viewportAnchor(in: scrollView)
        }
        viewportReader?.fractionalLine = { [weak scrollView] in
            guard let scrollView else { return nil }
            return Coordinator.topVisibleFractionalLine(in: scrollView)
        }
        viewportReader?.scrollToLine = { [weak scrollView, weak coord = context.coordinator] line in
            guard let scrollView, let coord else { return }
            coord.followScroll(toFractionalLine: line, in: scrollView)
        }

        DispatchQueue.main.async {
            guard session.isHosted(by: coordinator) else { return }
            coordinator.reportSelection(in: textView)
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.onSelectionChange = onSelectionChange
        context.coordinator.onEnterPreview = onEnterPreview
        context.coordinator.onAnchorLineChange = onAnchorLineChange
        context.coordinator.onTextEdit = onTextEdit
        context.coordinator.onFindShortcut = onFindShortcut
        context.coordinator.onFindResult = onFindResult
        context.coordinator.onInsertImageAttachments = onInsertImageAttachments
        context.coordinator.usesTypewriterScrolling = usesTypewriterScrolling
        // SwiftUI can still update an outgoing editor after the incoming one has
        // re-hosted the session's text view; that scroll view is empty now and
        // must not claim the viewport reader or touch the text.
        guard let textView = scrollView.documentView as? NSTextView,
              textView === context.coordinator.session.textView else { return }
        if textView.accessibilityLabel() != sourceAccessibilityLabel {
            textView.setAccessibilityLabel(sourceAccessibilityLabel)
        }
        viewportReader?.capture = { [weak scrollView] in
            guard let scrollView else { return nil }
            return Coordinator.viewportAnchor(in: scrollView)
        }
        viewportReader?.fractionalLine = { [weak scrollView] in
            guard let scrollView else { return nil }
            return Coordinator.topVisibleFractionalLine(in: scrollView)
        }
        viewportReader?.scrollToLine = { [weak scrollView, weak coord = context.coordinator] line in
            guard let scrollView, let coord else { return }
            coord.followScroll(toFractionalLine: line, in: scrollView)
        }
        (textView as? MarkdownSourceTextView)?.showsLineNumbers = showsLineNumbers
        if let sourceView = textView as? MarkdownSourceTextView, sourceView.typography != typography {
            sourceView.typography = typography
            context.coordinator.scheduleStyle(in: textView)
        }

        if context.coordinator.shouldApplyBoundText(text, to: textView) {
            // Opens and reloads already arrive through the session; this is text
            // that reached the document some other way. Mirroring it with
            // `textView.string =` would leave every undo action pointing at
            // ranges of the old text, so the session also drops that history.
            context.coordinator.session.resetText(to: text)
        }

        context.coordinator.configureRegexFind(
            query: $findQuery, replacement: $findReplacement, navigation: $findNavigation,
            mayReveal: findMayRevealMatches, showsReplacement: validatesRegexReplacement
        )
        context.coordinator.updateFind(query: findQuery, in: textView, revealMatches: findMayRevealMatches)
        context.coordinator.updateRegexReplacementValidation()

        if let formatCommand, context.coordinator.session.lastFormatToken != formatCommand.token {
            context.coordinator.session.lastFormatToken = formatCommand.token
            // insertText publishes through the binding; do it after SwiftUI's
            // update pass, with the same focus/IME checks as the menu sender.
            DispatchQueue.main.async { [weak textView] in
                guard let textView, textView.window?.firstResponder === textView else { return }
                (textView as? MarkdownSourceTextView)?.performMarkdownAction(formatCommand.action)
            }
        }

        // Consume navigation/replace commands by their token, not by clearing the
        // binding here. Mutating an observed binding inside `updateNSView` does not
        // reliably take effect before the next update, so a `self.findNavigation =
        // nil` here can be re-read as non-nil on the immediately following pass that
        // the command's own side effects (a match-count change) trigger — replaying
        // the action forever. Tracking the last-consumed token in the coordinator
        // (the same pattern as `lastFocusToken`) runs each command exactly once.
        if let findNavigation, context.coordinator.lastFindNavigationToken != findNavigation.token {
            context.coordinator.lastFindNavigationToken = findNavigation.token
            context.coordinator.handleFindNavigation(findNavigation.action, in: textView)
        }

        if let replaceCommand, context.coordinator.lastReplaceCommandToken != replaceCommand.token {
            context.coordinator.lastReplaceCommandToken = replaceCommand.token
            let coordinator = context.coordinator
            let snapshot = replaceCommand.snapshot ?? FindReplacementSnapshot(query: findQuery, replacement: findReplacement,
                                                    textView: textView, find: coordinator.session.find)
            let queryBinding = $findQuery
            let replacementBinding = $findReplacement
            // Editing publishes document/search state; do it outside SwiftUI's
            // update pass, after consuming the token exactly once. Revalidate the
            // exact invocation context so a new edit/query/host cannot be hit.
            coordinator.session.scheduleFindReplacement { [weak textView, weak coordinator] in
                guard let textView, let coordinator, coordinator.session.isHosted(by: coordinator) else { return }
                coordinator.replaceIfUnchanged(replaceCommand.action, snapshot: snapshot,
                    query: queryBinding.wrappedValue, replacement: replacementBinding.wrappedValue, in: textView)
            }
        }

        if context.coordinator.lastFocusToken != focusToken {
            let coordinator = context.coordinator
            coordinator.lastFocusToken = focusToken
            if let focusToken {
                DispatchQueue.main.async {
                    guard coordinator.lastFocusToken == focusToken,
                          coordinator.session.isHosted(by: coordinator) else { return }
                    textView.window?.makeFirstResponder(textView)
                }
            }
        }

        if let anchor = jumpAnchor {
            var initializesCaret = context.coordinator.initializesCaretFromAnchor
            context.coordinator.initializesCaretFromAnchor = false
            context.coordinator.applyAnchorUntilSettled(anchor, in: scrollView) { anchor, scrollView in
                let applied = apply(anchor: anchor, in: scrollView, textView: textView,
                                    focus: focusOnProgrammaticScroll, initializesCaret: initializesCaret)
                if applied { initializesCaret = false }
                return applied
            }
            DispatchQueue.main.async {
                self.jumpAnchor = nil
                self.jumpLine = nil
                self.jumpFraction = nil
            }
        } else if let jumpLine {
            let targetLine = jumpLine
            let coordinator = context.coordinator
            DispatchQueue.main.async {
                let applied = coordinator.performProgrammaticScroll(in: scrollView) {
                    scroll(to: targetLine, in: textView,
                           focus: focusOnProgrammaticScroll, selectLine: focusOnProgrammaticScroll)
                }
                if applied {
                    self.jumpLine = nil
                    self.jumpFraction = nil
                } else {
                    DispatchQueue.main.async {
                        _ = coordinator.performProgrammaticScroll(in: scrollView) {
                            scroll(to: targetLine, in: textView,
                                   focus: focusOnProgrammaticScroll, selectLine: focusOnProgrammaticScroll)
                        }
                        self.jumpLine = nil
                        self.jumpFraction = nil
                    }
                }
            }
        } else if let jumpFraction {
            let targetFraction = jumpFraction
            let coordinator = context.coordinator
            DispatchQueue.main.async {
                let applied = coordinator.performProgrammaticScroll(in: scrollView) {
                    scroll(toFraction: targetFraction, in: scrollView)
                }
                if applied {
                    self.jumpFraction = nil
                } else {
                    DispatchQueue.main.async {
                        _ = coordinator.performProgrammaticScroll(in: scrollView) {
                            scroll(toFraction: targetFraction, in: scrollView)
                        }
                        self.jumpFraction = nil
                    }
                }
            }
        }

        // After the jump handling, so an anchor this pass started is already
        // settling and the selection waits for it.
        if let lineSelection, context.coordinator.lastLineSelectionToken != lineSelection.token {
            context.coordinator.lastLineSelectionToken = lineSelection.token
            context.coordinator.selectSourceLine(lineSelection.line, in: textView)
            DispatchQueue.main.async { self.lineSelection = nil }
        }
    }

    /// Applies a mode-switch viewport anchor: a source-line anchor resolves to
    /// its target line (block start advanced by intra-block progress) and is
    /// placed near the top of the viewport; otherwise the proportional scroll
    /// fraction is the fallback. Both paths force layout and clamp the offset.
    private func apply(
        anchor: ViewportAnchor,
        in scrollView: NSScrollView,
        textView: NSTextView,
        focus: Bool,
        initializesCaret: Bool
    ) -> Bool {
        if let position = anchor.editorPosition, let offset = position.scrollOffset(in: textView) {
            if focus { textView.window?.makeFirstResponder(textView) }
            return scroll(toVerticalOffset: offset, in: scrollView)
        }
        if let targetLine = anchor.targetSourceLine {
            return scroll(to: targetLine, in: textView, focus: focus, selectLine: initializesCaret)
        }
        if focus { textView.window?.makeFirstResponder(textView) }
        return scroll(toFraction: anchor.scrollFraction, in: scrollView)
    }

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator(text: $text, session: session ?? MarkdownEditorSession())
        coordinator.onSelectionChange = onSelectionChange
        coordinator.onEnterPreview = onEnterPreview
        coordinator.onAnchorLineChange = onAnchorLineChange
        coordinator.onTextEdit = onTextEdit
        coordinator.onFindShortcut = onFindShortcut
        coordinator.onFindResult = onFindResult
        coordinator.onInsertImageAttachments = onInsertImageAttachments
        coordinator.usesTypewriterScrolling = usesTypewriterScrolling
        return coordinator
    }

    /// Hands the text view back to the session instead of letting it die with
    /// this scroll view: the undo actions it registered target it, and the next
    /// editor re-hosts it.
    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.cancelHostedRegexWork()
        coordinator.session.unhost(from: scrollView, coordinator: coordinator)
    }

    /// Scrolls the editor to a vertical fraction (0...1) of its content. Used as
    /// the fallback when no source-line anchor is available.
    private func scroll(toFraction fraction: Double, in scrollView: NSScrollView) -> Bool {
        guard let documentView = scrollView.documentView else { return false }
        let clamped = min(max(fraction, 0), 1)
        if clamped == 0 { return scroll(toVerticalOffset: 0, in: scrollView) }
        // Settle layout first so the content height reflects the real wrapped
        // text rather than a freshly created, not-yet-laid-out text view.
        if let textView = documentView as? NSTextView,
           let layoutManager = textView.layoutManager,
           let textContainer = textView.textContainer {
            layoutManager.ensureLayout(for: textContainer)
        }
        let visibleHeight = scrollView.contentView.bounds.height
        guard visibleHeight > 0 else { return false }
        let contentHeight = scrollableContentHeight(for: documentView)
        if contentHeight <= visibleHeight {
            return true
        }
        let maxOffset = max(0, contentHeight - visibleHeight)
        // Route the desired offset through the shared clamp so a document that
        // fits the viewport stays at the top (offset 0) instead of scrolling out
        // of view.
        let targetY = CGFloat(clampedScrollOffset(
            targetY: Double(maxOffset * CGFloat(clamped)),
            contentHeight: Double(contentHeight),
            viewportHeight: Double(visibleHeight)
        ))
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        return true
    }

    private func scroll(to line: Int, in textView: NSTextView, focus: Bool, selectLine: Bool) -> Bool {
        let lineIndex = max(1, line)
        let string = textView.string as NSString
        var currentLine = 1
        var location = 0

        while currentLine < lineIndex, location < string.length {
            let range = string.range(of: "\n", options: [], range: NSRange(location: location, length: string.length - location))
            if range.location == NSNotFound {
                break
            }
            location = range.location + 1
            currentLine += 1
        }

        let targetRange = NSRange(location: min(location, string.length), length: 0)
        // Focus first, then scroll last: any caret-reveal scroll that becoming
        // first responder triggers happens before our explicit clamp-to-top, so
        // the final resting position is the clamped target (0 when the document
        // fits the viewport) rather than wherever the focus scroll landed.
        if focus {
            textView.window?.makeFirstResponder(textView)
        }
        // A newly created source editor starts at the reading location.
        // Rehosting an existing editor retains its selection.
        if selectLine {
            textView.setSelectedRange(targetRange)
        }
        return scrollLineToTop(charRange: targetRange, in: textView)
    }

    /// Scrolls so the given character range sits near the top of the visible
    /// area (matching how the preview places a heading at the top), rather than
    /// `scrollRangeToVisible`, which only scrolls the minimum amount and leaves
    /// a target below the fold sitting at the bottom. Layout is forced first so
    /// the geometry is valid even on a freshly created text view.
    private func scrollLineToTop(charRange: NSRange, in textView: NSTextView) -> Bool {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer,
              let scrollView = textView.enclosingScrollView else {
            textView.scrollRangeToVisible(charRange)
            return true
        }

        if charRange.location == 0 { return scroll(toVerticalOffset: 0, in: scrollView) }
        layoutManager.ensureLayout(for: textContainer)
        let glyphRange = layoutManager.glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        // Leave a small top margin (the container inset) so the line is not
        // flush against the very top edge. The rect is in container coordinates.
        return scroll(toVerticalOffset: rect.minY, in: scrollView)
    }

    private func scroll(toVerticalOffset offset: CGFloat, in scrollView: NSScrollView) -> Bool {
        let visibleHeight = scrollView.contentView.bounds.height
        guard visibleHeight > 0, let documentView = scrollView.documentView else { return false }
        // The top is valid regardless of the document's wrapped height.
        let targetY: CGFloat = offset <= 0 ? 0 : CGFloat(clampedScrollOffset(
            targetY: Double(offset),
            contentHeight: Double(scrollableContentHeight(for: documentView)),
            viewportHeight: Double(visibleHeight)
        ))
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        return true
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        /// The text system this editor hosts and edits through.
        let session: MarkdownEditorSession
        var isApplyingStyle = false
        var usesTypewriterScrolling = false
        var initializesCaretFromAnchor = false
        var onEnterPreview: () -> Void = {}
        var onAnchorLineChange: (_ line: Int, _ drivesPreviewSync: Bool) -> Void = { _, _ in }
        var onTextEdit: (_ caretLine: Int) -> Void = { _ in }
        var onSelectionChange: (String?) -> Void = { _ in }
        private var selectionReportRevision = 0

        @MainActor func reportSelection(in textView: NSTextView) {
            guard !textView.hasMarkedText(), !isApplyingStyle else { return }
            let source = textView.string as NSString
            let fragments = textView.selectedRanges.compactMap { value -> String? in
                let range = value.rangeValue
                guard range.location != NSNotFound, range.length > 0, NSMaxRange(range) <= source.length else { return nil }
                return source.substring(with: range)
            }
            let selection = fragments.isEmpty ? nil : fragments.joined(separator: "\n")
            selectionReportRevision &+= 1
            let revision = selectionReportRevision
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, self.selectionReportRevision == revision,
                      let textView, !textView.hasMarkedText() else { return }
                self.onSelectionChange(selection)
            }
        }
        var onFindShortcut: (_ action: FindCommand.Action) -> Void = { _ in }
        var onFindResult: (_ total: Int, _ index: Int) -> Void = { _, _ in }
        var onInsertImageAttachments: (_ sources: [ImageAttachmentSource], _ range: NSRange, _ source: String) async -> Void = { _, _, _ in }
        var lastFocusToken: UUID?
        /// Tokens of the most recently consumed find/replace commands, so a command
        /// is acted on exactly once even if `updateNSView` re-runs while the same
        /// command value is still held by the binding. See the consumption site.
        var lastFindNavigationToken: UUID?
        var lastReplaceCommandToken: UUID?
        var lastLineSelectionToken: UUID?
        /// A line selection that arrived while an anchor was settling; the
        /// settle's final pass applies it, once the freshly mounted editor is
        /// in place and the anchor has placed its own caret.
        private var pendingLineSelection: (line: Int, textView: NSTextView)?
        private weak var scrollView: NSScrollView?
        private var selectionToReveal: NSRange?
        private var revealStylingReady = false
        private var revealStyleRevision = 0
        private var revealScheduled = false

        /// A retained Read-mode target must survive zero-sized/unattached hosts
        /// and the first asynchronous font reflow. Consume it only once the
        /// current host actually displays it, without replacing its selection.
        @MainActor func requestSelectionReveal(in textView: NSTextView) {
            guard session.revealSelectionOnNextHost else { return }
            selectionToReveal = textView.selectedRange()
            waitForRevealStyling()
        }

        @MainActor private func waitForRevealStyling() {
            guard selectionToReveal != nil else { return }
            revealStylingReady = false
            revealStyleRevision += 1
            let revision = revealStyleRevision
            let styling = self.styling
            Task { [weak self] in
                await styling.flush()
                guard let self, self.revealStyleRevision == revision else { return }
                self.revealStylingReady = true
                self.scheduleSelectionReveal()
            }
        }

        @MainActor func scheduleSelectionReveal() {
            guard selectionToReveal != nil, !revealScheduled else { return }
            revealScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.revealScheduled = false
                self.revealSelectionIfReady()
            }
        }

        @MainActor private func cancelSelectionReveal() {
            guard selectionToReveal != nil else { return }
            selectionToReveal = nil
            // An outgoing coordinator must not consume a newer host's request.
            if session.textView?.enclosingScrollView === scrollView {
                session.revealSelectionOnNextHost = false
            }
        }

        @MainActor private func revealSelectionIfReady() {
            guard let target = selectionToReveal,
                  let scrollView, let textView = session.textView,
                  textView.enclosingScrollView === scrollView else { return }
            guard session.revealSelectionOnNextHost else { cancelSelectionReveal(); return }
            guard textView.selectedRange() == target else { cancelSelectionReveal(); return }
            guard revealStylingReady, !isApplyingStyle,
                  textView.window != nil,
                  scrollView.contentSize.width > 0, scrollView.contentSize.height > 0,
                  let layout = textView.layoutManager, let container = textView.textContainer else { return }
            layout.ensureLayout(for: container)
            let wasProgrammatic = isProgrammaticScroll
            isProgrammaticScroll = true
            textView.setFrameOrigin(.zero)
            textView.scrollRangeToVisible(target)
            isProgrammaticScroll = wasProgrammatic
            let size = scrollView.contentSize
            let height = textView.frame.height
            // SwiftUI can finish laying out the new host after the first scroll.
            // Verify on the next turn; a changed layout gets another pass.
            DispatchQueue.main.async { [weak self, weak scrollView, weak textView] in
                guard let self, let scrollView, let textView,
                      self.selectionToReveal == target,
                      textView.enclosingScrollView === scrollView else { return }
                guard self.session.revealSelectionOnNextHost else { self.cancelSelectionReveal(); return }
                guard textView.selectedRange() == target else { self.cancelSelectionReveal(); return }
                let glyphs = layout.glyphRange(forCharacterRange: target, actualCharacterRange: nil)
                var rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
                if target.length == 0 {
                    rect = textView.firstRect(forCharacterRange: target, actualRange: nil)
                    if let window = textView.window {
                        rect = textView.convert(window.convertFromScreen(rect), from: nil)
                    }
                } else {
                    rect.origin.x += textView.textContainerOrigin.x
                    rect.origin.y += textView.textContainerOrigin.y
                }
                // A caret rect has zero width; its vertical row is the target.
                rect.size.width = max(1, rect.width)
                if self.revealStylingReady, textView.window != nil,
                   scrollView.contentSize == size, textView.frame.height == height,
                   textView.visibleRect.intersects(rect) {
                    self.cancelSelectionReveal()
                    textView.window?.makeFirstResponder(textView)
                    if let line = Self.topVisibleLine(in: scrollView) {
                        self.onAnchorLineChange(line, false)
                    }
                } else if scrollView.contentSize != size || textView.frame.height != height {
                    self.scheduleSelectionReveal()
                }
                // If geometry did not change and the target is still invisible,
                // keep the request for the next real layout/style notification;
                // do not spin an unbounded main-queue retry loop.
            }
        }
        /// True while a programmatic scroll (mode-switch jump, outline jump,
        /// find reveal) is in flight, so its transient positions are never
        /// reported back as the user's anchor.
        private var isProgrammaticScroll = false
        private var lastFindQuery = ""
        private var lastObservedOptions = TextSearch.Options()
        private var lastObservedScope = FindSession.Scope.document
        private var lastObservedRegex = false
        private var lastObservedRegexEpoch: UInt64 = 0
        private var lastObservedFindIdentity: UUID
        private var regexQueryBinding: Binding<String>?
        private var regexTemplateBinding: Binding<String>?
        private var regexNavigationBinding: Binding<FindCommand?>?
        private var regexMayReveal = false
        private var regexShowsReplacement = false
        private var regexSearchTask: Task<Void, Never>?
        private var regexValidationTask: Task<Void, Never>?
        private var regexReplacementTask: Task<Void, Never>?
        private var regexValidationEpoch: UUID?
        private var pendingRegexNavigation = 0
        private var pendingRegexNavigationSelection: [NSValue]?
        private var resumeAfterRegexEdit: (generation: Int, inserted: NSRange, zeroWidth: Bool)?
        private var matches: [NSRange] = []
        private var currentMatchIndex = -1
        private var highlightedRanges: [NSRange] = []
        /// The match currently painted in the "current match" color, so the
        /// highlight can be demoted to the normal color when the current match
        /// moves.
        private var paintedCurrentRange: NSRange?
        private var editViewportRestoreToken = UUID()
        /// Monotonic revision of the (text, query) state that drives find
        /// re-indexing. Bumped by `textDidChange` (document edits) and when the
        /// query binding changes, so `updateFind` can detect "the document or
        /// query changed" with an O(1) comparison instead of whole-document
        /// string equality on every SwiftUI update.
        private var findGeneration = 0
        /// The origin of the mutation that most recently bumped `findGeneration`:
        /// true when a query change did, false when a document edit (or external
        /// text replacement) did. Decides whether the next rebuild may reveal
        /// (move the caret / scroll): a document edit must never yank the caret,
        /// even when a query change was pending when the debounce fired.
        private var lastFindMutationWasQueryChange = true
        /// The generation whose index is currently painted on the text view.
        private var appliedFindGeneration = -1
        private struct FindRebuild {
            let generation: Int
            let query: String
            let preferredIndex: Int
            let shouldReveal: Bool
            let regexSelection: [NSValue]?
            let token = UUID()
        }

        private var pendingFindRebuild: FindRebuild?
        /// The query most recently observed by `updateFind` (schedule-time), used
        /// to detect query changes without relying on the fire-time
        /// `lastFindQuery`.
        private var lastObservedQuery = ""
        /// Debounce window for query/text-driven re-indexing. Internal so tests
        /// can shorten it.
        var findDebounceInterval: TimeInterval = 0.15

        @MainActor init(text: Binding<String>, session: MarkdownEditorSession = MarkdownEditorSession()) {
            _text = text
            self.session = session
            lastObservedFindIdentity = session.find.identity
        }

        /// The document's undo manager, so the text view, the window, and the
        /// Edit menu share one history.
        func undoManager(for view: NSTextView) -> UndoManager? {
            session.undoManager
        }

        /// The session replaced the text outside the editing path (open, reload,
        /// or text that bypassed the editor). That posts no `textDidChange`, so do
        /// what an edit would trigger here.
        @MainActor func textWasReplaced(in textView: NSTextView) {
            cancelSelectionReveal()
            scheduleStyle(in: textView)
            // The replacement can shift every line below it, but TextKit's own
            // display invalidation is glyph-scoped — it never covers the gutter
            // strip. Ask for it explicitly or the numbers stay stale until the
            // next user edit.
            (textView as? MarkdownSourceTextView)?.invalidateGutter()
            // Tell the find index it moved; the next update re-indexes without
            // revealing.
            noteExternalTextChange()
        }

        /// SwiftUI may refresh this representable for unrelated state while an
        /// input method owns marked text in the editor. Replacing `string` in
        /// that window destroys the input method's composition buffer and can
        /// commit a stale candidate at a different selection.
        @MainActor func shouldApplyBoundText(_ boundText: String, to textView: NSTextView) -> Bool {
            // UTF-16 source/undo ranges require literal equality, not Swift's
            // canonical-equivalence comparison of visually identical text.
            !(textView.string as NSString).isEqual(to: boundText) && !isApplyingStyle && !textView.hasMarkedText()
        }

        /// Programmatic text replacement (bound-text sync, a reload after the
        /// file changed on disk) does not post `NSText.didChangeNotification`, so
        /// `textDidChange` never bumps the find generation and the previous index
        /// would stay painted at stale coordinates. Mark it as a document mutation
        /// so the next `updateFind` re-indexes — without revealing, since the
        /// replacement path already clamped the selection.
        @MainActor func noteExternalTextChange() {
            findGeneration += 1
            lastFindMutationWasQueryChange = false
            if session.find.usesRegex {
                cancelRegexWork()
                session.find.invalidateRegexResults()
                lastObservedRegexEpoch = session.find.regexResultsEpoch
            }
        }

        @MainActor func updateFind(query: String, in textView: NSTextView, revealMatches: Bool = true) {
            // Rebuilding highlights can select/reveal a match. Never do that
            // while the input method owns the selection for marked text.
            guard !textView.hasMarkedText() else { return }

            let find = session.find
            let regex = find.usesRegex
            let queryChanged = regex ? !(query as NSString).isEqual(to: lastObservedQuery) : query != lastObservedQuery
            if queryChanged || find.options != lastObservedOptions || find.scope != lastObservedScope
                || regex != lastObservedRegex
                || (regex && (find.identity != lastObservedFindIdentity || find.regexResultsEpoch != lastObservedRegexEpoch)) {
                let wasRegex = lastObservedRegex
                lastObservedOptions = find.options
                lastObservedScope = find.scope
                lastObservedRegex = regex
                lastObservedRegexEpoch = find.regexResultsEpoch
                lastObservedFindIdentity = find.identity
                if regex || wasRegex { cancelRegexWork() }
                if wasRegex && !regex {
                    lastFindQuery = ""
                    matches = []
                    currentMatchIndex = -1
                    applyFindHighlights(in: textView)
                }
                if revealMatches { cancelSelectionReveal() }
                lastObservedQuery = query
                findGeneration += 1
                lastFindMutationWasQueryChange = true
                if wasRegex && !regex { reportFindResult() }
            }

            // Idempotent: only re-index when the (text, query) state moved past
            // what is already applied or already scheduled. `textDidChange` bumps
            // the generation on document edits; a query change bumps it here.
            // Comparing generations is O(1) and never reads the whole document.
            let generation = findGeneration
            guard generation != appliedFindGeneration,
                  generation != pendingFindRebuild?.generation, regexSearchTask == nil else {
                return
            }

            // The query-changed predicate and the reveal intent are computed once
            // here so the preferred index and the reveal decision cannot drift.
            let needsFirstMatch = regex
                ? !(query as NSString).isEqual(to: lastFindQuery)
                : query != lastFindQuery
            let preferredIndex = needsFirstMatch ? 0 : currentMatchIndex
            if regex {
                matches = []
                currentMatchIndex = -1
                applyFindHighlights(in: textView)
                publishRegexStart(generation: generation, hasQuery: !query.isEmpty && find.canReplace)
            }
            scheduleFindRebuild(
                query: query,
                in: textView,
                generation: generation,
                preferredIndex: preferredIndex,
                shouldReveal: revealMatches && lastFindMutationWasQueryChange
            )
        }

        @MainActor func configureRegexFind(
            query: Binding<String>, replacement: Binding<String>, navigation: Binding<FindCommand?>,
            mayReveal: Bool, showsReplacement: Bool
        ) {
            regexQueryBinding = query
            regexTemplateBinding = replacement
            regexNavigationBinding = navigation
            regexMayReveal = mayReveal
            regexShowsReplacement = showsReplacement
            if !showsReplacement {
                regexValidationTask?.cancel()
                regexValidationTask = nil
                regexValidationEpoch = nil
                regexReplacementTask?.cancel()
                regexReplacementTask = nil
            }
        }

        @MainActor func cancelHostedRegexWork() {
            if lastObservedRegex { cancelRegexWork() }
        }

        @MainActor private func cancelRegexWork() {
            regexSearchTask?.cancel()
            regexSearchTask = nil
            regexValidationTask?.cancel()
            regexValidationTask = nil
            regexValidationEpoch = nil
            regexReplacementTask?.cancel()
            regexReplacementTask = nil
            pendingRegexNavigation = 0
            pendingRegexNavigationSelection = nil
            pendingFindRebuild = nil
        }

        @MainActor private func publishRegexStart(generation: Int, hasQuery: Bool) {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.findGeneration == generation, self.appliedFindGeneration != generation,
                      self.session.isHosted(by: self), self.session.find.usesRegex else { return }
                self.session.find.regexStatus = hasQuery ? .searching : .idle
                self.session.find.currentRegexMatch = nil
                self.onFindResult(0, 0)
            }
        }

        @MainActor private func startRegexSearch(
            query: String, in textView: NSTextView, preferredIndex: Int, shouldReveal: Bool, selection: [NSValue]?
        ) {
            let find = session.find
            guard !query.isEmpty, find.canReplace else {
                installFindMatches([], query: query, in: textView, preferredIndex: 0, shouldReveal: false)
                return
            }
            let source = textView.string
            let generation = findGeneration
            let identity = find.identity
            let epoch = find.regexResultsEpoch
            let sessionScope = find.scope
            let scope = find.range
            let caseSensitive = find.options.caseSensitive
            regexSearchTask = Task { [weak self, weak textView] in
                let result = await RegexFindWorker.result {
                    try await RegexFindProcess.matches(of: query, in: source, caseSensitive: caseSensitive, scope: scope)
                }
                guard !Task.isCancelled, let self, let textView,
                      self.findGeneration == generation, self.session.isHosted(by: self) else { return }
                self.regexSearchTask = nil
                guard !textView.hasMarkedText(), find.usesRegex, find.identity == identity,
                      find.regexResultsEpoch == epoch,
                      find.scope == sessionScope, find.options.caseSensitive == caseSensitive,
                      query.utf16.elementsEqual((self.regexQueryBinding?.wrappedValue ?? self.lastObservedQuery).utf16)
                else { return }

                // Use the visible bar's current state and the live selection.
                // An edit, click, or a mode transition must win over auto-reveal.
                let resume = self.resumeAfterRegexEdit?.generation == generation
                let autoReveal = shouldReveal && textView.window?.firstResponder !== textView
                let reveal = (autoReveal || resume) && self.regexMayReveal && find.isSourceFindVisible
                    && selection == textView.selectedRanges
                switch result {
                case .success(let ranges):
                    self.installFindMatches(ranges, query: query, in: textView, preferredIndex: max(0, preferredIndex),
                                            shouldReveal: reveal, immediately: true)
                    find.currentRegexMatch = self.currentFindRange
                    find.regexStatus = .ready
                case .failure(let error):
                    self.installFindMatches([], query: query, in: textView, preferredIndex: 0,
                                            shouldReveal: false, immediately: true)
                    find.regexStatus = Self.regexStatus(for: error)
                }
            }
        }

        @MainActor func updateRegexReplacementValidation() {
            let find = session.find
            guard find.usesRegex, regexShowsReplacement, let pattern = regexQueryBinding?.wrappedValue,
                  !pattern.isEmpty, let template = regexTemplateBinding?.wrappedValue, find.canReplace,
                  regexValidationEpoch != find.regexReplacementEpoch else { return }
            regexValidationTask?.cancel()
            regexReplacementTask?.cancel()
            regexReplacementTask = nil
            let epoch = find.regexReplacementEpoch
            let caseSensitive = find.options.caseSensitive
            regexValidationEpoch = epoch
            regexValidationTask = Task { [weak self] in
                guard let self, self.session.isHosted(by: self), find.regexReplacementEpoch == epoch,
                      !Task.isCancelled else { return }
                find.regexReplacementStatus = .searching
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                let result = await RegexFindWorker.result {
                    try await RegexFindProcess.validateReplacement(template, for: pattern, caseSensitive: caseSensitive)
                }
                guard !Task.isCancelled, self.session.isHosted(by: self), self.regexShowsReplacement, find.usesRegex,
                      find.regexReplacementEpoch == epoch,
                      pattern.utf16.elementsEqual((self.regexQueryBinding?.wrappedValue ?? "").utf16),
                      template.utf16.elementsEqual((self.regexTemplateBinding?.wrappedValue ?? "").utf16) else { return }
                switch result {
                case .success: find.regexReplacementStatus = .ready
                case .failure(let error): find.regexReplacementStatus = Self.regexStatus(for: error)
                }
            }
        }

        @MainActor private func startRegexReplacement(
            _ action: FindReplaceCommand.Action, snapshot: FindReplacementSnapshot, in textView: NSTextView
        ) -> Bool {
            let find = session.find
            guard regexShowsReplacement, regexReplacementTask == nil, appliedFindGeneration == findGeneration,
                  find.regexStatus == .ready, find.regexReplacementStatus == .ready, find.canReplace,
                  (lastFindQuery as NSString).isEqual(to: snapshot.query), !matches.isEmpty else { return false }
            let target: NSRange?
            switch action {
            case .current:
                guard let currentFindRange, snapshot.currentRegexMatch == currentFindRange else { return false }
                target = currentFindRange
            case .all:
                target = nil
            }
            let pattern = snapshot.query
            let template = snapshot.replacement
            let source = snapshot.source
            let scope = find.range
            let caseSensitive = snapshot.options.caseSensitive
            let generation = findGeneration
            find.regexReplacementStatus = .searching
            regexReplacementTask = Task { [weak self, weak textView] in
                let result = await RegexFindWorker.result {
                    try await RegexFindProcess.makeEdit(pattern: pattern, template: template, source: source,
                                                       caseSensitive: caseSensitive, scope: scope, target: target)
                }
                guard !Task.isCancelled, let self, let textView, self.session.isHosted(by: self) else { return }
                self.regexReplacementTask = nil
                guard self.regexShowsReplacement, self.findGeneration == generation,
                      find.regexReplacementEpoch == snapshot.regexReplacementEpoch else { return }
                guard !textView.hasMarkedText(), target == nil || self.currentFindRange == target,
                      snapshot.isCurrent(query: self.regexQueryBinding?.wrappedValue ?? "",
                                         replacement: self.regexTemplateBinding?.wrappedValue ?? "",
                                         textView: textView, find: find) else {
                    find.regexReplacementStatus = .ready
                    find.replacementCount = nil
                    find.replacementCancelled = true
                    return
                }
                switch result {
                case .success(let edit):
                    find.regexReplacementStatus = .ready
                    if let edit {
                        self.applyRegexEdit(edit, target: target, query: pattern, in: textView)
                    } else {
                        find.replacementCount = 0
                    }
                case .failure(let error):
                    find.regexReplacementStatus = Self.regexStatus(for: error)
                }
            }
            return true
        }

        @MainActor private func applyRegexEdit(
            _ edit: RegexFindWorker.Edit, target: NSRange?, query: String, in textView: NSTextView
        ) {
            var scope = session.find.scope
            let inserted = NSRange(location: edit.range.location, length: edit.replacement.utf16.count)
            if case .selection(let old) = scope {
                scope = .selection(NSRange(location: old.location, length: old.length + inserted.length - edit.range.length))
            }
            guard session.applyFindEdit(range: edit.range, replacement: edit.replacement,
                                        scope: scope, actionName: target == nil ? "Replace All" : "Replace") else { return }
            session.find.replacementCount = edit.count
            updateFind(query: query, in: textView, revealMatches: false)
            if let target {
                resumeAfterRegexEdit = (findGeneration, inserted, target.length == 0)
            }
        }

        private static func regexStatus(for error: any Error) -> FindSession.RegexStatus {
            switch error as? RegexSearch.Failure {
            case .invalidPattern: .invalidPattern
            case .invalidReplacement: .invalidReplacement
            case .limitExceeded: .workLimit
            case .searchFailed, nil: .searchFailed
            }
        }

        /// Arms the debounced rebuild for `query` on `generation`. Idempotent by
        /// generation: a re-entrant `updateFind` for an already-armed generation
        /// (e.g. the status-text re-render after a search result) neither cancels
        /// nor re-arms it, so the search cannot starve in a SwiftUI update loop.
        /// Re-arming for a newer generation replaces the token, so the older
        /// scheduled closure detects the mismatch and drops itself.
        @MainActor private func scheduleFindRebuild(
            query: String,
            in textView: NSTextView,
            generation: Int,
            preferredIndex: Int,
            shouldReveal: Bool
        ) {
            let request = FindRebuild(
                generation: generation, query: query, preferredIndex: preferredIndex, shouldReveal: shouldReveal,
                regexSelection: session.find.usesRegex ? textView.selectedRanges : nil
            )
            pendingFindRebuild = request
            DispatchQueue.main.asyncAfter(deadline: .now() + findDebounceInterval) { [weak self, weak textView] in
                guard let self, let textView, self.pendingFindRebuild?.token == request.token else { return }
                self.flushPendingFindRebuild(in: textView)
            }
        }

        /// Starts pending work immediately. Literal matches are ready before
        /// return; regex results arrive asynchronously and gate commands by revision.
        @MainActor func flushPendingFindRebuild(in textView: NSTextView) {
            guard let request = pendingFindRebuild else { return }
            pendingFindRebuild = nil
            guard !textView.hasMarkedText() else { return }
            if session.find.usesRegex {
                startRegexSearch(query: request.query, in: textView, preferredIndex: request.preferredIndex,
                                 shouldReveal: request.shouldReveal, selection: request.regexSelection)
            } else {
                rebuildFindIndex(query: request.query, in: textView, preferredIndex: request.preferredIndex,
                                 shouldReveal: request.shouldReveal)
            }
        }

        @MainActor func navigateFind(forward: Bool, in textView: NSTextView) {
            guard !textView.hasMarkedText() else { return }
            // A pending query-driven rebuild must run first, or navigation would
            // step through the previous query's match list.
            flushPendingFindRebuild(in: textView)
            if session.find.usesRegex, appliedFindGeneration != findGeneration
                || session.find.regexStatus == .idle {
                if regexSearchTask != nil {
                    let selection = textView.selectedRanges
                    if pendingRegexNavigationSelection != selection { pendingRegexNavigation = 0 }
                    pendingRegexNavigation += forward ? 1 : -1
                    pendingRegexNavigationSelection = selection
                }
                return
            }
            guard !matches.isEmpty else {
                reportFindResult()
                return
            }

            let delta = forward ? 1 : -1
            let base = currentMatchIndex < 0 && !forward ? 0 : currentMatchIndex
            currentMatchIndex = wrappedIndex(base + delta, count: matches.count)
            if session.find.usesRegex {
                // A navigation that arrives during updateNSView publishes on the next turn.
                let generation = findGeneration
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.findGeneration == generation, self.session.find.usesRegex else { return }
                    self.session.find.currentRegexMatch = self.currentFindRange
                }
            }
            applyFindHighlights(in: textView)
            revealCurrentMatch(in: textView)
            reportFindResult()
        }

        /// Dispatches a find command produced by the find bar or the ⌘G/⇧⌘G
        /// shortcuts. `.search` (Return in the query field) runs the current
        /// search now — flushing any pending debounced rebuild — but never
        /// advances to the next match; navigation stays on the bar controls and
        /// ⌘G/⇧⌘G. Internal so tests can drive it deterministically.
        @MainActor func handleFindNavigation(_ action: FindCommand.Action, in textView: NSTextView) {
            switch action {
            case .search:
                flushPendingFindRebuild(in: textView)
            case .next:
                navigateFind(forward: true, in: textView)
            case .previous:
                navigateFind(forward: false, in: textView)
            case .show, .showReplace:
                break // bar presentation is handled at the ContentView level
            }
        }

        @discardableResult
        @MainActor func replaceIfUnchanged(_ action: FindReplaceCommand.Action, snapshot: FindReplacementSnapshot,
                                           query: String, replacement: String, in textView: NSTextView) -> Bool {
            guard snapshot.identity == session.find.identity else { return false }
            guard !textView.hasMarkedText(), snapshot.isCurrent(query: query, replacement: replacement, textView: textView, find: session.find) else {
                session.find.replacementCount = nil
                session.find.replacementCancelled = true
                return false
            }
            session.find.replacementCancelled = false
            if snapshot.usesRegex {
                return startRegexReplacement(action, snapshot: snapshot, in: textView)
            }
            replace(action, replacement: replacement, in: textView)
            return true
        }

        @MainActor func replace(
            _ action: FindReplaceCommand.Action,
            replacement: String,
            in textView: NSTextView
        ) {
            // Replace must act on the current query's matches, never the previous
            // query's list, so a pending query-driven rebuild is flushed first.
            guard !textView.hasMarkedText(), session.find.canReplace else { return }
            updateFind(query: lastObservedQuery, in: textView, revealMatches: false)
            flushPendingFindRebuild(in: textView)
            guard !lastFindQuery.isEmpty, !matches.isEmpty else {
                session.find.replacementCount = 0
                reportFindResult()
                return
            }

            switch action {
            case .current:
                replaceCurrent(with: replacement, in: textView)
            case .all:
                replaceAll(with: replacement, in: textView)
            }
        }

        @MainActor private func replaceCurrent(with replacement: String, in textView: NSTextView) {
            guard currentMatchIndex >= 0, currentMatchIndex < matches.count else { return }
            applyReplacements([matches[currentMatchIndex]], with: replacement, in: textView)
        }

        @MainActor private func replaceAll(with replacement: String, in textView: NSTextView) {
            applyReplacements(matches, with: replacement, in: textView)
        }

        @MainActor private func applyReplacements(_ targets: [NSRange], with replacement: String, in textView: NSTextView) {
            guard let first = targets.first, let last = targets.last else { return }
            let range = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
            let original = (textView.string as NSString).substring(with: range)
            let updated = Self.assembleLiteralReplacement(original, matches: targets, replacement: replacement)
            if original.utf16.elementsEqual(updated.utf16) {
                session.find.replacementCount = 0
                return
            }
            var scope = session.find.scope
            if case .selection(let old) = scope {
                scope = .selection(NSRange(location: old.location, length: old.length + updated.utf16.count - range.length))
            }
            // Production always uses the retained session text system. The
            // detached coordinator fixtures also exercise the native path below.
            if session.textView === textView {
                guard session.applyFindEdit(range: range, replacement: updated, scope: scope) else { return }
            } else {
                textView.breakUndoCoalescing()
                textView.insertText(updated, replacementRange: range)
                textView.breakUndoCoalescing()
                session.find.scope = scope
            }
            session.find.replacementCount = targets.count
            rebuildFindIndex(query: lastFindQuery, in: textView, preferredIndex: max(currentMatchIndex, 0), shouldReveal: true)
        }

        /// `original` spans the first through last match. The sorted,
        /// nonoverlapping ranges still use the document's UTF-16 coordinates.
        nonisolated static func assembleLiteralReplacement(
            _ original: String, matches: [NSRange], replacement: String
        ) -> String {
            guard matches.count > 1, let first = matches.first else { return replacement }
            // Copy each gap once instead of repeatedly shifting the suffix.
            let source = Array(original.utf16)
            let insertion = Array(replacement.utf16)
            var output: [UInt16] = []
            output.reserveCapacity(source.count)
            var cursor = 0
            for match in matches {
                let start = match.location - first.location
                output.append(contentsOf: source[cursor..<start])
                output.append(contentsOf: insertion)
                cursor = start + match.length
            }
            return String(decoding: output, as: UTF16.self)
        }

        @MainActor private func rebuildFindIndex(
            query: String,
            in textView: NSTextView,
            preferredIndex: Int,
            shouldReveal: Bool
        ) {
            let ranges = session.find.canReplace
                ? TextSearch.matches(of: query, in: textView.string, options: session.find.options, scope: session.find.range)
                : []
            installFindMatches(ranges, query: query, in: textView, preferredIndex: preferredIndex, shouldReveal: shouldReveal)
        }

        @MainActor private func installFindMatches(
            _ ranges: [NSRange], query: String, in textView: NSTextView, preferredIndex: Int,
            shouldReveal: Bool, immediately: Bool = false
        ) {
            lastFindQuery = query
            matches = ranges
            if matches.isEmpty {
                currentMatchIndex = -1
            } else {
                currentMatchIndex = wrappedIndex(preferredIndex, count: matches.count)
                // A document-edit rebuild must not yank the caret, but a match the
                // user just created at the caret should still become current: the
                // orange highlight and the "i of n" status follow what they are
                // writing. Prefer a match ending exactly at the caret (type-ahead)
                // over one that merely contains it. Matches are non-overlapping,
                // so at most one candidate of each kind exists.
                if !shouldReveal {
                    let caret = textView.selectedRange().location
                    if let promoted = matches.firstIndex(where: { $0.location + $0.length == caret })
                        ?? matches.firstIndex(where: { $0.location <= caret && caret <= $0.location + $0.length }) {
                        currentMatchIndex = promoted
                    }
                }
            }

            var reveal = shouldReveal
            if !matches.isEmpty, immediately {
                if let resume = resumeAfterRegexEdit, resume.generation == findGeneration {
                    let end = NSMaxRange(resume.inserted)
                    let eligible: (NSRange) -> Bool = { range in
                        !resume.zeroWidth || range.location < resume.inserted.location || range.location > end
                    }
                    currentMatchIndex = matches.firstIndex { $0.location >= end && eligible($0) }
                        ?? matches.firstIndex(where: eligible) ?? -1
                }
                if pendingRegexNavigation != 0, pendingRegexNavigationSelection == textView.selectedRanges,
                   regexNavigationBinding?.wrappedValue != nil {
                    let base = currentMatchIndex < 0 && pendingRegexNavigation < 0 ? 0 : currentMatchIndex
                    currentMatchIndex = wrappedIndex(base + pendingRegexNavigation, count: matches.count)
                    reveal = true
                }
            }
            pendingRegexNavigation = 0
            pendingRegexNavigationSelection = nil
            resumeAfterRegexEdit = nil
            applyFindHighlights(in: textView)
            if reveal { revealCurrentMatch(in: textView) }
            appliedFindGeneration = findGeneration
            reportFindResult(immediately: immediately)
        }

        @MainActor private func applyFindHighlights(in textView: NSTextView) {
            guard let layoutManager = textView.layoutManager else { return }
            let normalColor = NSColor.systemYellow.withAlphaComponent(0.45)
            let currentColor = NSColor.systemOrange.withAlphaComponent(0.6)

            // Repaint only the ranges whose match membership changed. When the set
            // is identical (navigation, or a rebuild that produced the same
            // matches), no temporary attribute churn happens at all — only the
            // current-match color below is touched. This keeps layout invalidation
            // proportional to the change instead of to the whole match set.
            // Zero-width hits have no glyph range. Dense regex results keep the
            // exact index but paint only the current hit to bound TextKit work.
            let currentRange = currentFindRange.flatMap { $0.length > 0 ? $0 : nil }
            let painted = session.find.usesRegex
                ? (matches.count <= 1_000 ? matches.filter { $0.length > 0 } : [currentRange].compactMap { $0 })
                : matches
            if highlightedRanges != painted {
                let diff = FindHighlightDiff.diff(from: highlightedRanges, to: painted)
                for range in diff.removed {
                    let length = (textView.textStorage?.length ?? 0) - range.location
                    if length > 0 {
                        layoutManager.removeTemporaryAttribute(.backgroundColor,
                            forCharacterRange: NSRange(location: range.location, length: min(length, range.length)))
                    }
                }
                for range in diff.added {
                    layoutManager.addTemporaryAttribute(
                        .backgroundColor,
                        value: normalColor,
                        forCharacterRange: range
                    )
                }
                highlightedRanges = painted
            }

            if let oldCurrent = paintedCurrentRange,
               oldCurrent != currentRange,
               let index = painted.firstIndex(of: oldCurrent) {
                // Demote only while the range is still a match in the CURRENT
                // coordinate space. A range that is no longer a match was already
                // removed by the membership diff above; removing it again here
                // would operate on a stale (pre-edit) range and could wipe a
                // freshly-painted neighboring match.
                layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: oldCurrent)
                layoutManager.addTemporaryAttribute(
                    .backgroundColor,
                    value: normalColor,
                    forCharacterRange: painted[index]
                )
            }
            if let currentRange {
                layoutManager.addTemporaryAttribute(
                    .backgroundColor,
                    value: currentColor,
                    forCharacterRange: currentRange
                )
            }
            paintedCurrentRange = currentRange
        }

        private var currentFindRange: NSRange? {
            matches.indices.contains(currentMatchIndex) ? matches[currentMatchIndex] : nil
        }

        @MainActor private func revealCurrentMatch(in textView: NSTextView) {
            guard let range = currentFindRange else { return }
            // Reveal with a collapsed caret at the END of the match rather than a
            // full-range selection, so an immediate Backspace deletes only the
            // character before the caret — never the whole matched word. The
            // current-match highlight still identifies the active match visually,
            // and Reveal does not move first responder: the find query field keeps
            // focus until the user clicks back into the editor.
            textView.setSelectedRange(FindReveal.caretRange(for: range))
            // Find reveals are programmatic scrolls: suppress anchor reporting
            // until they settle so they cannot become a stale mode-switch anchor.
            if let scrollView = textView.enclosingScrollView {
                _ = performProgrammaticScroll(in: scrollView) {
                    textView.scrollRangeToVisible(range)
                    return true
                }
            } else {
                textView.scrollRangeToVisible(range)
            }
        }

        private func wrappedIndex(_ index: Int, count: Int) -> Int {
            ((index % count) + count) % count
        }

        @MainActor private func reportFindResult(immediately: Bool = false) {
            let total: Int
            let index: Int
            if matches.isEmpty {
                total = 0
                index = 0
            } else {
                total = matches.count
                index = currentMatchIndex + 1
            }

            if immediately {
                onFindResult(total, index)
            } else {
                let generation = findGeneration
                let isRegex = session.find.usesRegex
                DispatchQueue.main.async { [weak self] in
                    guard let self, !isRegex || self.findGeneration == generation else { return }
                    self.onFindResult(total, index)
                }
            }
        }

        /// Registers for the clip view's bounds-change notifications so the top
        /// visible source line is reported on every scroll.
        @MainActor func observe(scrollView: NSScrollView) {
            self.scrollView = scrollView
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(boundsDidChange),
                name: NSView.boundsDidChangeNotification,
                object: scrollView.contentView
            )
        }

        @MainActor @objc private func boundsDidChange() {
            guard !isProgrammaticScroll,
                  let scrollView,
                  let line = Self.topVisibleLine(in: scrollView) else { return }
            let isUserScroll = Self.isUserScrollEvent(NSApp.currentEvent)
            if isUserScroll {
                editViewportRestoreToken = UUID()
                cancelSelectionReveal()
            }
            onAnchorLineChange(line, isUserScroll)
        }

        private static func isUserScrollEvent(_ event: NSEvent?) -> Bool {
            switch event?.type {
            case .scrollWheel, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
                return true
            default:
                return false
            }
        }

        /// The mode-switch anchor currently being settled, used to dedupe
        /// repeated `updateNSView` passes and cancel a superseded settle loop.
        private var settlingAnchor: ViewportAnchor?

        /// Applies a mode-switch anchor, then re-applies it across runloop
        /// turns until the editor's measured content height stops changing.
        /// A freshly mounted text view is laid out by SwiftUI *after* the
        /// first apply, so a single pass can compute the target from garbage
        /// geometry and leave the editor overscrolled with an empty visible
        /// range; converging on stable geometry keeps the final offset
        /// clamped against the real content height. Anchor reporting stays
        /// suppressed throughout; the settled position is reported once.
        @MainActor func applyAnchorUntilSettled(
            _ anchor: ViewportAnchor,
            in scrollView: NSScrollView,
            apply: @escaping (ViewportAnchor, NSScrollView) -> Bool
        ) {
            guard settlingAnchor != anchor else { return }
            settlingAnchor = anchor
            isProgrammaticScroll = true
            var attempts = 0
            var lastContentHeight = CGFloat(-1)
            let seeksTop: Bool
            if let position = anchor.editorPosition {
                seeksTop = position.characterIndex == 0 && position.verticalOffset <= 0
            } else if let line = anchor.targetSourceLine {
                seeksTop = line == 1
            } else {
                seeksTop = anchor.scrollFraction <= 0
            }

            func step() {
                guard self.settlingAnchor == anchor, self.session.isHosted(by: self),
                      scrollView.documentView === self.session.textView else { return }
                attempts += 1

                // While the freshly mounted scroll view is being sized, a
                // transient negative clip origin can get baked into the
                // document view's frame origin, silently shifting all content
                // out of the scrollable region. Re-base it before scrolling.
                if let documentView = scrollView.documentView, documentView.frame.origin.y != 0 {
                    documentView.setFrameOrigin(NSPoint(x: documentView.frame.origin.x, y: 0))
                }

                var appliedNow = false
                if scrollView.contentView.bounds.height > 0 {
                    appliedNow = apply(anchor, scrollView)
                }
                let contentHeight = scrollView.documentView
                    .map { seeksTop ? $0.bounds.height : scrollableContentHeight(for: $0) } ?? 0
                // Stable only when the scroll applied against unchanged
                // geometry *and* the viewport actually shows content — an
                // empty visible rect means the offset points into the void.
                let showsContent = !(scrollView.documentView?.visibleRect.isEmpty ?? true)
                let isStable = appliedNow && showsContent && abs(contentHeight - lastContentHeight) < 1
                lastContentHeight = contentHeight

                if (isStable && attempts >= 2) || attempts >= 12 {
                    self.settlingAnchor = nil
                    self.isProgrammaticScroll = false
                    if let line = Self.topVisibleLine(in: scrollView) {
                        // The once-per-mode-switch settle: drive the preview so
                        // the two panes open in alignment in Side by Side.
                        self.onAnchorLineChange(line, true)
                    }
                    if let pending = self.pendingLineSelection {
                        self.pendingLineSelection = nil
                        self.selectSourceLine(pending.line, in: pending.textView)
                    }
                } else {
                    DispatchQueue.main.async(execute: step)
                }
            }
            step()
        }

        /// Runs `body` (a programmatic scroll) with transient anchor reporting
        /// suppressed, then — once the scroll has settled on the next runloop
        /// turn — reports the final visible line as the new cached anchor.
        @MainActor func performProgrammaticScroll(
            in scrollView: NSScrollView,
            _ body: () -> Bool
        ) -> Bool {
            isProgrammaticScroll = true
            let applied = body()
            DispatchQueue.main.async { [weak self, weak scrollView] in
                guard let self else { return }
                self.isProgrammaticScroll = false
                guard let scrollView,
                      let line = Self.topVisibleLine(in: scrollView) else { return }
                // A programmatic follow's settle report, not a user scroll.
                self.onAnchorLineChange(line, false)
            }
            return applied
        }

        /// Reads the live viewport as a mode-switch anchor: the top visible
        /// source line, the proportional scroll fraction, and the editor's
        /// stable top content inset. Computed on demand so a switch right
        /// after a scroll never sees a stale debounced value.
        @MainActor static func viewportAnchor(in scrollView: NSScrollView) -> ViewportAnchor? {
            let offset = Double(scrollView.contentView.bounds.origin.y)
            let atTop = offset <= 0
            guard let textView = scrollView.documentView as? NSTextView,
                  let line = topVisibleLine(in: scrollView) else { return nil }

            let visibleHeight = Double(scrollView.contentView.bounds.height)
            let maxOffset = atTop ? 0 : Double(scrollableContentHeight(for: textView)) - visibleHeight
            let fraction = maxOffset > 0 ? offset / maxOffset : 0

            return ViewportAnchor(
                sourceLine: line,
                intraBlockProgress: 0,
                viewportTopInset: Double(textView.textContainerInset.height),
                scrollFraction: fraction,
                editorPosition: ViewportAnchor.EditorPosition(of: textView)
            )
        }

        /// Computes the 1-based source line at the top of the visible rect using
        /// the layout manager (bounding rect → glyph range → character → line).
        /// The 1-based source line containing the character at `index`, counting
        /// newlines before it — the same numbering `topVisibleLine` reports.
        static func lineNumber(forCharacterIndex index: Int, in string: NSString) -> Int {
            let clamped = max(0, min(index, string.length))
            var line = 1
            var location = 0
            while location < clamped {
                let range = string.range(
                    of: "\n",
                    options: [],
                    range: NSRange(location: location, length: clamped - location)
                )
                if range.location == NSNotFound { break }
                line += 1
                location = range.location + 1
            }
            return line
        }

        @MainActor static func topVisibleLine(in scrollView: NSScrollView, layoutWholeDocument: Bool = true) -> Int? {
            guard let textView = scrollView.documentView as? NSTextView,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return nil }

            // `glyphRange(forBoundingRect:)` expects the rect in container
            // coordinates, which differ from the text view's by the container
            // origin (the text container inset).
            var rect = textView.visibleRect
            let origin = textView.textContainerOrigin
            rect.origin.x -= origin.x
            rect.origin.y -= origin.y
            if layoutWholeDocument, scrollView.contentView.bounds.minY > 0 {
                // Styling restores the viewport through a bounds change. Lay
                // out the resized content before AppKit clamps that offset.
                layoutManager.ensureLayout(for: textContainer)
            } else {
                layoutManager.ensureLayout(forBoundingRect: rect, in: textContainer)
            }
            let glyphRange = layoutManager.glyphRange(forBoundingRect: rect, in: textContainer)
            let charIndex = layoutManager.characterIndexForGlyph(at: glyphRange.location)

            let string = textView.string as NSString
            let clampedIndex = min(charIndex, string.length)
            // Line number = newlines before the index + 1, matching scroll(to:).
            var line = 1
            var location = 0
            while location < clampedIndex {
                let range = string.range(
                    of: "\n",
                    options: [],
                    range: NSRange(location: location, length: clampedIndex - location)
                )
                if range.location == NSNotFound { break }
                line += 1
                location = range.location + 1
            }
            return line
        }

        /// Smoothly scrolls the editor so a fractional source `line` sits at the
        /// top of the viewport, for continuous Side by Side follow. Unlike a
        /// mode-switch jump it runs no settle loop and does not steal focus;
        /// anchor reporting is suppressed only briefly so this follow scroll
        /// cannot echo back and drive the preview into an oscillation.
        @MainActor func followScroll(toFractionalLine line: Double, in scrollView: NSScrollView) {
            guard let targetY = Self.clipTargetY(forFractionalLine: line, in: scrollView) else { return }
            isProgrammaticScroll = true
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            DispatchQueue.main.async { [weak self] in
                self?.isProgrammaticScroll = false
            }
        }

        /// The editor's top-of-viewport position as a fractional source line: the
        /// integer top visible line plus how far the viewport top has scrolled
        /// through that line's vertical extent (0...1). Continuous across a line's
        /// wrapped fragments, so a follower can track it smoothly instead of in
        /// line-sized steps.
        @MainActor static func topVisibleFractionalLine(in scrollView: NSScrollView) -> Double? {
            guard let textView = scrollView.documentView as? NSTextView,
                  let line = topVisibleLine(in: scrollView) else { return nil }
            var rect = textView.visibleRect
            let origin = textView.textContainerOrigin
            rect.origin.y -= origin.y
            let topY = rect.origin.y
            guard let lineRect = lineBoundingRect(line: line, in: textView), lineRect.height > 0 else {
                return Double(line)
            }
            let progress = min(max(Double((topY - lineRect.minY) / lineRect.height), 0), 1)
            return Double(line) + progress
        }

        /// The clip-view Y offset that places a fractional source `line` at the
        /// top of the viewport (with the standard top inset), clamped to the
        /// scrollable range. Mirrors `scrollLineToTop`'s placement. `nil` when the
        /// geometry is not measurable yet.
        @MainActor static func clipTargetY(forFractionalLine value: Double, in scrollView: NSScrollView) -> CGFloat? {
            guard let textView = scrollView.documentView as? NSTextView,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return nil }
            let line = max(1, Int(value.rounded(.down)))
            let progress = CGFloat(min(max(value - Double(line), 0), 1))
            layoutManager.ensureLayout(for: textContainer)
            guard let rect = lineBoundingRect(line: line, in: textView) else { return nil }
            let visibleHeight = scrollView.contentView.bounds.height
            guard visibleHeight > 0 else { return nil }
            let documentHeight = scrollableContentHeight(for: textView)
            // The line rect is in container coordinates; placing its top at the
            // clip origin leaves the container inset as the top margin (same rule
            // as `scrollLineToTop`). Advance by the intra-line progress.
            let containerTargetY = rect.minY + progress * rect.height
            let clamped = clampedScrollOffset(
                targetY: Double(containerTargetY),
                contentHeight: Double(documentHeight),
                viewportHeight: Double(visibleHeight)
            )
            return CGFloat(clamped)
        }

        /// The bounding rect (in text-container coordinates) of the glyphs for a
        /// 1-based source `line`, falling back to the line fragment rect for an
        /// empty line so blank lines still yield a usable height.
        @MainActor static func lineBoundingRect(line: Int, in textView: NSTextView) -> NSRect? {
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return nil }
            let nsString = textView.string as NSString
            let charRange = characterRange(ofLine: line, in: nsString)
            let glyphRange = layoutManager.glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
            var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            if rect.height <= 0.5, layoutManager.numberOfGlyphs > 0 {
                let charIndex = max(0, min(charRange.location, nsString.length - 1))
                let glyphIndex = min(
                    layoutManager.glyphIndexForCharacter(at: charIndex),
                    layoutManager.numberOfGlyphs - 1
                )
                rect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            }
            return rect
        }

        /// The character range (excluding the terminator) of a 1-based source
        /// `line`, counting `\n` as the separator — matching `scroll(to:)` and the
        /// renderer's source-line numbering.
        static func characterRange(ofLine line: Int, in string: NSString) -> NSRange {
            let target = max(1, line)
            var currentLine = 1
            var location = 0
            while currentLine < target, location < string.length {
                let range = string.range(
                    of: "\n",
                    options: [],
                    range: NSRange(location: location, length: string.length - location)
                )
                if range.location == NSNotFound {
                    location = string.length
                    break
                }
                location = range.location + 1
                currentLine += 1
            }
            let lineStart = min(location, string.length)
            let nl = string.range(
                of: "\n",
                options: [],
                range: NSRange(location: lineStart, length: string.length - lineStart)
            )
            let lineEnd = (nl.location == NSNotFound) ? string.length : nl.location
            return NSRange(location: lineStart, length: max(0, lineEnd - lineStart))
        }

        /// Maps visible line-fragment start offsets to the source line each one
        /// begins, for the gutter to draw. The result is parallel to
        /// `fragmentStarts`: an entry is `nil` when that fragment continues a
        /// soft-wrapped line, which is the same source line and must not be
        /// numbered twice.
        ///
        /// Numbering follows the renderer's convention
        /// (`String.normalizedMarkdownLines`): LF, CRLF, and a bare CR each count
        /// as one line break, so the editor gutter and the preview's block
        /// numbers agree on every document — including bare-CR files, which the
        /// `\n`-only helpers above would number differently.
        ///
        /// Fragments arrive in document order, so the breaks are counted once
        /// across the gaps between consecutive starts: one pass over the document
        /// per redraw, rather than one scan per fragment.
        static func gutterRows(forFragmentStarts fragmentStarts: [Int], in string: NSString) -> [Int?] {
            var rows: [Int?] = []
            rows.reserveCapacity(fragmentStarts.count)
            var line = 1
            var scanned = 0
            var lineStart = 0

            for start in fragmentStarts {
                let clamped = max(0, min(start, string.length))
                // Never scan backwards. A caller handing fragments out of order
                // gets a continuation rather than a corrupted running count.
                guard clamped >= scanned else {
                    rows.append(nil)
                    continue
                }

                var location = scanned
                while location < clamped {
                    let character = string.character(at: location)
                    if character == 0x0A { // LF
                        location += 1
                        line += 1
                        lineStart = location
                    } else if character == 0x0D { // CR, or the CR of a CRLF pair
                        // Peek one past the gap so a CRLF straddling the boundary
                        // counts as a single break instead of two.
                        let isCRLF = location + 1 < string.length
                            && string.character(at: location + 1) == 0x0A
                        location += isCRLF ? 2 : 1
                        line += 1
                        lineStart = location
                    } else {
                        location += 1
                    }
                }
                scanned = max(location, clamped)

                rows.append(clamped == lineStart ? line : nil)
            }

            return rows
        }

        /// Selects 1-based source `line` with its line break, focuses the
        /// editor, and scrolls the line's start into view if it is off screen.
        /// While a mode-switch anchor is settling, the selection waits for it.
        /// A line past the end of the document (a stale preview) is ignored.
        @MainActor func selectSourceLine(_ line: Int, in textView: NSTextView) {
            if settlingAnchor != nil {
                pendingLineSelection = (line, textView)
                return
            }
            guard let range = Self.sourceLineRange(forLine: line, in: textView.string as NSString) else { return }
            textView.window?.makeFirstResponder(textView)
            textView.setSelectedRange(range)
            if let scrollView {
                _ = performProgrammaticScroll(in: scrollView) {
                    textView.scrollRangeToVisible(NSRange(location: range.location, length: 0))
                    return true
                }
            } else {
                textView.scrollRangeToVisible(NSRange(location: range.location, length: 0))
            }
        }

        /// The range of 1-based source `line`, with its line break, numbered as
        /// the gutter numbers lines (LF, CRLF and a bare CR each end a line), so
        /// it is exactly the line a gutter number labels. Nil past the last line.
        static func sourceLineRange(forLine line: Int, in string: NSString) -> NSRange? {
            guard line >= 1 else { return nil }
            var current = 1
            var location = 0
            while current < line {
                guard let next = lineBreakEnd(from: location, in: string) else { return nil }
                location = next
                current += 1
            }
            return NSRange(location: location, length: (lineBreakEnd(from: location, in: string) ?? string.length) - location)
        }

        /// The source line containing the character at `index`, numbered as
        /// `sourceLineRange(forLine:in:)` numbers it. An index between the CR
        /// and LF of a pair belongs to the line the pair ends.
        static func sourceLineRange(containing index: Int, in string: NSString) -> NSRange {
            var start = max(0, min(index, string.length))
            if start > 0, start < string.length,
               string.character(at: start - 1) == 0x0D, string.character(at: start) == 0x0A {
                start -= 1
            }
            while start > 0 {
                let previous = string.character(at: start - 1)
                if previous == 0x0A || previous == 0x0D { break }
                start -= 1
            }
            return NSRange(location: start, length: (lineBreakEnd(from: start, in: string) ?? string.length) - start)
        }

        /// The index just past the first line break at or after `location`, or
        /// nil when the rest of the string has none.
        private static func lineBreakEnd(from location: Int, in string: NSString) -> Int? {
            var index = location
            while index < string.length {
                let character = string.character(at: index)
                if character == 0x0A { return index + 1 }
                if character == 0x0D {
                    let isCRLF = index + 1 < string.length && string.character(at: index + 1) == 0x0A
                    return index + (isCRLF ? 2 : 1)
                }
                index += 1
            }
            return nil
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
            regexSearchTask?.cancel()
            regexValidationTask?.cancel()
            regexReplacementTask?.cancel()
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            // Input methods use Return to commit Latin letters and Esc/Tab to
            // control composition. Never consume any command while marked.
            guard !textView.hasMarkedText() else { return false }
            if let sourceView = textView as? MarkdownSourceTextView,
               sourceView.handleMarkdownCommand(commandSelector) { return true }
            // Esc maps to cancelOperation: in the standard key bindings.
            // Intercept it here so the owner can route it (dismiss find /
            // switch to preview) instead of triggering the text view's
            // default completion behaviour.
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                onEnterPreview()
                return true
            }
            return false
        }

        @MainActor func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView,
                  !textView.hasMarkedText() else { return }

            MarkdownTextStyler.synchronizeTypingAttributes(in: textView)
            reportSelection(in: textView)

            // A click or keyboard selection move after an edit supersedes the
            // old viewport. Otherwise a delayed restore from that edit can yank
            // the viewport back after the caret has deliberately moved.
            if !isApplyingStyle {
                editViewportRestoreToken = UUID()
                if let target = selectionToReveal, textView.selectedRange() != target {
                    cancelSelectionReveal()
                }
            }
        }

        private var styling: MarkdownStylingController { session.styling }

        @MainActor func centerTypewriterCaret(in textView: NSTextView) {
            let selection = textView.selectedRange()
            guard usesTypewriterScrolling, session.isHosted(by: self), settlingAnchor == nil,
                  !session.revealSelectionOnNextHost, !textView.hasMarkedText(),
                  textView.selectedRanges.count == 1, selection.length == 0,
                  selection.location != NSNotFound, let window = textView.window,
                  window.firstResponder === textView,
                  let scrollView, scrollView.documentView === textView else { return }

            let clipView = scrollView.contentView
            guard clipView.bounds.height > 0 else { return }
            // Supersede any viewport restore queued by the regular edit path.
            editViewportRestoreToken = UUID()
            let originalOffset = clipView.bounds.minY
            let wasProgrammatic = isProgrammaticScroll
            isProgrammaticScroll = true
            defer {
                isProgrammaticScroll = wasProgrammatic
                if abs(clipView.bounds.minY - originalOffset) > 0.5,
                   let line = Self.topVisibleLine(in: scrollView, layoutWholeDocument: false) {
                    onAnchorLineChange(line, false)
                }
            }
            // NSTextInputClient can clip the caret rect to the viewport. Once
            // revealed, its native geometry locates the active wrapped row and
            // the insertion point after a trailing newline.
            textView.scrollRangeToVisible(selection)
            let screenRect = textView.firstRect(forCharacterRange: selection, actualRange: nil)
            let caret = clipView.convert(window.convertFromScreen(screenRect), from: nil)
            guard caret.height > 0, caret.midY.isFinite else { return }
            var proposed = clipView.bounds
            proposed.origin.y = caret.midY - proposed.height / 2
            let target = clipView.constrainBoundsRect(proposed).origin
            guard abs(clipView.bounds.minY - target.y) > 0.5 else { return }
            clipView.scroll(to: target)
            scrollView.reflectScrolledClipView(clipView)
        }

        @MainActor func scheduleStyle(in textView: NSTextView) {
            styling.schedule(in: textView, sourceRevision: { [weak session] in
                session?.structuredSourceRevision
            }, willApply: { [weak self] in
                self?.isApplyingStyle = true
            }, didApply: { [weak self] in
                self?.isApplyingStyle = false
            })
            waitForRevealStyling()
        }

        @MainActor func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            cancelSelectionReveal()
            // The gutter's numbers depend on line breaks, and marked text returns
            // below without restyling — so composition could otherwise change the
            // text under a gutter that is never asked to redraw. Text redraws are
            // glyph-scoped and never reach the strip, so ask explicitly.
            (textView as? MarkdownSourceTextView)?.invalidateGutter()
            // Marked text is the input method's private, provisional buffer. It
            // must not enter the document binding, Markdown restyling, preview
            // rendering, autosave, or selection restoration before commit.
            guard !textView.hasMarkedText() else {
                editViewportRestoreToken = UUID()
                return
            }
            // A committed text edit makes the previous find index stale. Bump the
            // generation so the next `updateFind` schedules a rebuild, and record
            // the mutation origin so that rebuild does not reveal (a document edit
            // must never move the caret).
            noteExternalTextChange()
            // The document's own edit (a preview checkbox toggle) is not typing:
            // it must not pull Side by Side's follow to the caret line or re-pin
            // the editor's viewport.
            if session.isApplyingDocumentEdit {
                text = textView.string
                scheduleStyle(in: textView)
                return
            }
            let visibleOrigin = scrollView?.contentView.bounds.origin
            // The caret reflects the post-edit position (textDidChange fires after
            // the change), so its source line is where the user is writing — the
            // line Side by Side should keep visible in the preview.
            let caretLine = Self.lineNumber(
                forCharacterIndex: textView.selectedRange().location,
                in: textView.string as NSString
            )
            onTextEdit(caretLine)
            text = textView.string

            reportSelection(in: textView)
            scheduleStyle(in: textView)
            preserveVisibleOriginAfterEdit(visibleOrigin)
        }

        @MainActor private func preserveVisibleOriginAfterEdit(_ origin: CGPoint?) {
            guard let origin else { return }
            let token = UUID()
            editViewportRestoreToken = token
            restoreVisibleOrigin(origin)

            for delay in [0.05, 0.16, 0.35, 0.65, 1.0, 1.5, 2.2] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, self.editViewportRestoreToken == token else { return }
                    self.restoreVisibleOrigin(origin)
                }
            }
        }

        @MainActor private func restoreVisibleOrigin(_ origin: CGPoint?) {
            guard let origin, let scrollView else { return }
            let clipView = scrollView.contentView
            let current = clipView.bounds.origin
            guard abs(current.y - origin.y) > 1 || abs(current.x - origin.x) > 1 else { return }
            isProgrammaticScroll = true
            clipView.scroll(to: origin)
            scrollView.reflectScrolledClipView(clipView)
            DispatchQueue.main.async { [weak self] in
                self?.isProgrammaticScroll = false
            }
        }
    }
}

@MainActor
private func scrollableContentHeight(for documentView: NSView) -> CGFloat {
    guard let textView = documentView as? NSTextView,
          let layoutManager = textView.layoutManager,
          let textContainer = textView.textContainer else {
        return documentView.bounds.height
    }

    layoutManager.ensureLayout(for: textContainer)
    let usedRect = layoutManager.usedRect(for: textContainer)
    let measuredHeight = ceil(usedRect.maxY + textView.textContainerInset.height * 2)
    guard measuredHeight.isFinite, measuredHeight > 0 else {
        return textView.bounds.height
    }
    return measuredHeight
}

final class MarkdownSourceTextView: NSTextView {
    /// The native text/focus can exist before the retained source target is
    /// ready. Assistive technology needs the same readiness boundary as format
    /// commands. AppKit has no method-based accessor for this standard AX state,
    /// so bridge only this attribute; keep all other native text behavior.
    override func accessibilityAttributeNames() -> [NSAccessibility.Attribute] {
        let names = super.accessibilityAttributeNames()
        let busy = NSAccessibility.Attribute(rawValue: "AXElementBusy")
        return names.contains(busy) ? names : names + [busy]
    }

    override func accessibilityAttributeValue(_ attribute: NSAccessibility.Attribute) -> Any? {
        if attribute.rawValue == "AXElementBusy" {
            // Older SDKs leave this legacy callback nonisolated. This native
            // NSTextView UI entrypoint runs on the main thread; make that boundary
            // explicit before reading the UI-owned delegate and session state.
            return MainActor.assumeIsolated { () -> Bool in
                (self.delegate as? MarkdownEditorSession)?.revealSelectionOnNextHost == true
            }
        }
        return super.accessibilityAttributeValue(attribute)
    }

    override func accessibilityIsAttributeSettable(_ attribute: NSAccessibility.Attribute) -> Bool {
        attribute.rawValue == "AXElementBusy" ? false : super.accessibilityIsAttributeSettable(attribute)
    }

    override func accessibilitySetValue(_ value: Any?, forAttribute attribute: NSAccessibility.Attribute) {
        guard attribute.rawValue != "AXElementBusy" else { return }
        super.accessibilitySetValue(value, forAttribute: attribute)
    }

    var typography: TypographySettings = .init() {
        didSet {
            guard typography != oldValue else { return }
            updateHorizontalInset(for: frame.width)
            invalidateGutter()
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        let previousWidth = frame.width
        if newSize.width < previousWidth { updateHorizontalInset(for: newSize.width) }
        super.setFrameSize(newSize)
        if newSize.width > previousWidth { updateHorizontalInset(for: newSize.width) }
    }

    private func updateHorizontalInset(for width: CGFloat) {
        guard width > 0 else { return }
        let preferred = max(58, ceil(gutterFontSize * Self.gutterWidthFactor + Self.gutterTrailingInset))
        // Leave room for text even in the narrowest pane at maximum zoom.
        let inset = min(preferred, floor(width / 4))
        if textContainerInset.width != inset { textContainerInset.width = inset }
    }
    lazy var markdownPasteController = MarkdownPasteController(editor: self)
    private var isPasting = false
    private var isSoftReturnEvent = false
    /// Non-nil during a tracked key event. An insert distinguishes an IME
    /// commit from cancellation, which can also change text and selection.
    private var typewriterKeyInsertedText: Bool?
    /// Isolated command input keeps editor tests off the user's shared clipboard.
    var linkClipboardText: () -> String? = { NSPasteboard.general.string(forType: .string) }

    // AppKit's default key bindings can map both Return and Shift-Return to
    // insertNewline:. Preserve the originating event while the input context
    // interprets it; command dispatch still waits for the IME to release it.
    override func keyDown(with event: NSEvent) {
        let previous = isSoftReturnEvent
        isSoftReturnEvent = Self.isSoftReturn(event)
        defer { isSoftReturnEvent = previous }
        guard let session = delegate as? MarkdownEditorSession, session.usesTypewriterScrolling else {
            super.keyDown(with: event)
            return
        }
        let oldSelection = selectedRanges
        let oldAffinity = selectionAffinity
        let oldRevision = session.structuredSourceRevision
        let wasComposing = hasMarkedText()
        let previousInsert = typewriterKeyInsertedText
        typewriterKeyInsertedText = false
        defer { typewriterKeyInsertedText = previousInsert }
        super.keyDown(with: event)
        guard !hasMarkedText(), !wasComposing || typewriterKeyInsertedText == true,
              oldSelection != selectedRanges || oldAffinity != selectionAffinity
                  || oldRevision != session.structuredSourceRevision else { return }
        session.centerTypewriterCaret(in: self)
    }

    override func interpretKeyEvents(_ eventArray: [NSEvent]) {
        let previous = isSoftReturnEvent
        isSoftReturnEvent = previous || eventArray.contains(where: Self.isSoftReturn)
        defer { isSoftReturnEvent = previous }
        super.interpretKeyEvents(eventArray)
    }

    private static func isSoftReturn(_ event: NSEvent) -> Bool {
        [36, 76].contains(event.keyCode) && event.modifierFlags.contains(.shift)
            && event.modifierFlags.intersection([.command, .control, .option]).isEmpty
    }

    @discardableResult
    func performMarkdownAction(_ action: MarkdownEditing.Action) -> Bool {
        guard !hasMarkedText() else { return false }
        // Native shortcuts/context-menu actions can bypass DocumentStore.
        // Consume them during the reveal instead of bubbling into a menu or
        // modifying a focused but not-yet-visible retained source selection.
        let explicitTable: MarkdownTableEditing.Action?
        if case .tableEdit(let value) = action { explicitTable = value } else { explicitTable = nil }
        if (delegate as? MarkdownEditorSession)?.revealSelectionOnNextHost == true,
           explicitTable != nil || action == .indent || action == .outdent ||
            MarkdownFormatCommand.items.contains(where: { $0.action == action }) { return true }
        let session = delegate as? MarkdownEditorSession
        let queuedTarget = session?.structuredEditUndo.requiresApplicationEvent == true ?
            session?.structuredCommands.captureTarget(in: self, excludingUnstartedPastes: true) : nil
        let selection = queuedTarget?.selection ?? selectedRange()
        let tableSource = queuedTarget?.source ?? string
        guard isEditable, !hasMarkedText(), selectedRanges.count == 1 else { return false }
        let tableResult: Result<MarkdownEditing.Edit, MarkdownTableEditing.Rejection>?
        if let explicitTable {
            tableResult = MarkdownTableEditing.result(tableSource, selection: selection, action: explicitTable)
        } else if action == .indent || action == .outdent {
            tableResult = MarkdownTableEditing.navigationResult(tableSource, selection: selection, backwards: action == .outdent)
        } else { tableResult = nil }
        if let tableResult {
            switch tableResult {
            case .success(let edit):
                (delegate as? MarkdownEditorSession)?.onTableEditingResult?(nil)
                let mutates = edit.range.length != 0 || !edit.replacement.isEmpty
                let changesContext = mutates || edit.selection != selection
                if let session, let queuedTarget, changesContext || session.structuredCommands.hasPendingTableActions {
                    if changesContext { session.structuredCommands.cancelUnstartedPasteConversions() }
                    let command = StructuredCommandEdit(range: edit.range, replacement: edit.replacement, selection: edit.selection)
                    if session.structuredCommands.submit(edit: command, target: queuedTarget) != nil {
                        if changesContext { session.acceptedStructuredTableTransition() }
                    }
                } else {
                    if mutates || edit.selection != selectedRange() { session?.acceptedStructuredTableTransition() }
                    applyTableEdit(edit)
                }
                return true
            case .failure(let rejection):
                (delegate as? MarkdownEditorSession)?.onTableEditingResult?(rejection)
                // A recognized table must consume a refused Tab; otherwise
                // NSTextView inserts whitespace into the selected source cell.
                return explicitTable == nil
            }
        }
        guard isEditable, !hasMarkedText(), selectedRanges.count == 1,
              let edit = MarkdownEditing.edit(string, selection: selectedRange(), action: action,
                  clipboard: action == .link ? linkClipboardText() : nil,
                  autoClosingPositions: trackedCloser(at: selectedRange().location)) else { return false }
        applyMarkdownEdit(edit)
        return true
    }

    /// Native insertion keeps binding/style/autosave notifications intact. A
    /// single inverse also restores the cell selection, which native text-only
    /// undo cannot promise after a navigation-selected range.
    private func applyTableEdit(_ edit: MarkdownEditing.Edit) {
        if edit.range.length == 0, edit.replacement.isEmpty {
            if selectedRange() != edit.selection { setSelectedRange(edit.selection) }
            scrollRangeToVisible(edit.selection)
            return
        }
        applyTableReplacement(range: edit.range, replacement: edit.replacement, selection: edit.selection)
    }

    private func applyTableReplacement(range: NSRange, replacement: String, selection: NSRange) {
        insertStructuredText(replacement, range: range, selection: selection)
    }

    private func applyMarkdownEdit(_ edit: MarkdownEditing.Edit) {
        if edit.range.length == 0, edit.replacement.isEmpty,
           edit.selection.location == edit.range.location + 1 {
            textStorage?.removeAttribute(.markdownAutoClosing,
                                         range: NSRange(location: edit.range.location, length: 1))
        }
        if edit.range.length != 0 || !edit.replacement.isEmpty {
            breakUndoCoalescing()
            insertText(edit.replacement, replacementRange: edit.range)
            breakUndoCoalescing()
        }
        if let position = edit.autoClosingPosition {
            textStorage?.addAttribute(.markdownAutoClosing, value: true,
                                      range: NSRange(location: position, length: 1))
        }
        setSelectedRange(edit.selection)
        scrollRangeToVisible(edit.selection)
    }

    func handleMarkdownCommand(_ selector: Selector) -> Bool {
        let action: MarkdownEditing.Action
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): action = isSoftReturnEvent ? .softNewline : .newline
        case #selector(NSResponder.insertLineBreak(_:)): action = .softNewline
        case #selector(NSResponder.insertTab(_:)): action = .indent
        case #selector(NSResponder.insertBacktab(_:)): action = .outdent
        case #selector(NSResponder.deleteBackward(_:)): action = .deleteBackward
        default: return false
        }
        return performMarkdownAction(action)
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        let wasComposing = hasMarkedText()
        // Explicit replacements are edits, paste/drop payloads, or input-method
        // commits. Pair only ordinary single-character typing; never re-enter
        // this path while applying a MarkdownEditing result.
        let input = (insertString as? String) ?? (insertString as? NSAttributedString)?.string
        if replacementRange.location == NSNotFound, !hasMarkedText(), !isPasting,
           isEditable, selectedRanges.count == 1, let input,
           let edit = MarkdownEditing.edit(string, selection: selectedRange(), action: .type(input),
                                           autoClosingPositions: trackedCloser(at: selectedRange().location)) {
            applyMarkdownEdit(edit)
        } else {
            super.insertText(insertString, replacementRange: replacementRange)
        }
        guard !hasMarkedText() else { return }
        if typewriterKeyInsertedText != nil {
            typewriterKeyInsertedText = true
        } else if wasComposing {
            // Some input methods deliver the committed text through the
            // input context outside the text view's keyDown call.
            (delegate as? MarkdownEditorSession)?.centerTypewriterCaret(in: self)
        }
    }

    private func trackedCloser(at position: Int) -> Set<Int> {
        guard let textStorage, position >= 0, position < textStorage.length,
              textStorage.attribute(.markdownAutoClosing, at: position, effectiveRange: nil) != nil else { return [] }
        return [position]
    }

    var onFindAction: ((FindCommand.Action) -> Void)?
    /// Captures source/range for asynchronous attachment work and guarded native
    /// undo adoption. Set by MarkdownEditorView; never inserts a stale result.
    var onInsertImageAttachments: (([ImageAttachmentSource], NSRange, String) async -> Void)?

    /// Whether the source line-number gutter is drawn. Setting it only
    /// invalidates the gutter strip — the text container's geometry is never
    /// touched, so the document cannot re-wrap or shift when it changes.
    var showsLineNumbers = false {
        didSet {
            guard showsLineNumbers != oldValue else { return }
            invalidateGutter()
        }
    }

    /// Right margin between a gutter number and the text container's left edge.
    private static let gutterTrailingInset: CGFloat = 8
    private static let gutterWidthFactor: CGFloat = 3.2
    /// Match the editor zoom; the inset grows above its 58pt minimum when
    /// five-digit numbers need more room at large sizes.
    private var gutterFontSize: CGFloat { typography.effectiveFontSize * 0.875 }

    /// Invalidates just the gutter strip. Text redraws are glyph-scoped and start
    /// at the container origin, so they never cover the strip; anything that
    /// changes the gutter outside the styling pass (which already invalidates the
    /// whole view) has to ask for it explicitly.
    func invalidateGutter() {
        guard showsLineNumbers, textContainerInset.width > 0 else { return }
        setNeedsDisplay(NSRect(
            x: 0,
            y: bounds.minY,
            width: textContainerInset.width,
            height: bounds.height
        ))
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard showsLineNumbers else { return }
        // `NSTextView` clips its drawing to the text container, so the container
        // inset the gutter lives in is outside the clip it leaves behind — and
        // anything painted there is discarded. Re-clip to the rect we were asked
        // to draw (the inset included) and, since its own drawing can also leave a
        // different context current, put ours back first.
        if let context = NSGraphicsContext.current {
            context.cgContext.resetClip()
            context.cgContext.clip(to: dirtyRect)
        }
        drawLineNumbers(clippedTo: dirtyRect)
    }

    /// Draws the source line number for each line fragment whose first visual row
    /// begins a source line, right-aligned in the inset left of the text.
    private func drawLineNumbers(clippedTo dirtyRect: NSRect) {
        let stripWidth = textContainerInset.width
        guard stripWidth > 0,
              let layoutManager,
              let textContainer else { return }
        let origin = textContainerOrigin

        // The strip lies outside the text container, so a fragment query against
        // it would intersect no glyphs. Query the dirty rect's vertical interval
        // extended across the container's full width (the same origin conversion
        // `topVisibleLine` performs), then clip painting to the strip.
        var probe = dirtyRect
        probe.origin.x -= origin.x
        probe.origin.y -= origin.y
        probe.size.width = textContainer.size.width

        layoutManager.ensureLayout(for: textContainer)
        let glyphRange = layoutManager.glyphRange(forBoundingRect: probe, in: textContainer)

        var fragmentStarts: [Int] = []
        var fragmentRects: [NSRect] = []
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { _, usedRect, _, fragmentGlyphRange, _ in
            let charRange = layoutManager.characterRange(
                forGlyphRange: fragmentGlyphRange,
                actualGlyphRange: nil
            )
            fragmentStarts.append(charRange.location)
            fragmentRects.append(usedRect)
        }

        // A document ending in a newline has a final empty line with no glyphs:
        // TextKit exposes it as the extra line fragment. It is numbered like any
        // other line, so the gutter's last number always equals the line count
        // the status bar, find, and the outline report.
        if layoutManager.extraLineFragmentTextContainer != nil {
            let extra = layoutManager.extraLineFragmentUsedRect
            if probe.intersects(extra) {
                fragmentStarts.append((string as NSString).length)
                fragmentRects.append(extra)
            }
        }

        let rows = MarkdownEditorView.Coordinator.gutterRows(
            forFragmentStarts: fragmentStarts,
            in: string as NSString
        )
        let fittedFontSize = min(gutterFontSize, max(1, (stripWidth - Self.gutterTrailingInset) / Self.gutterWidthFactor))
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: fittedFontSize, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ]

        for (index, row) in rows.enumerated() {
            guard let line = row else { continue }
            var rect = fragmentRects[index]
            rect.origin.x += origin.x
            rect.origin.y += origin.y
            guard rect.intersects(dirtyRect) else { continue }

            let label = "\(line)" as NSString
            let size = label.size(withAttributes: attributes)
            let x = stripWidth - Self.gutterTrailingInset - size.width
            let y = rect.minY + max(0, (rect.height - size.height) / 2)
            label.draw(at: NSPoint(x: max(0, x), y: y), withAttributes: attributes)
        }
    }

    // MARK: - Gutter clicks

    /// A click on the line-number gutter selects the source line beside it, with
    /// its line break. Shift extends the current selection to that line, and a
    /// drag extends the selection line by line, as other editors' gutters do.
    /// With numbers hidden, or while an input method holds marked text, the
    /// inset is ordinary text-view margin.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard showsLineNumbers, !hasMarkedText(), point.x < textContainerOrigin.x,
              let clicked = gutterLineRange(atY: point.y) else {
            super.mouseDown(with: event)
            return
        }
        window?.makeFirstResponder(self)
        let anchor = event.modifierFlags.contains(.shift) ? selectedRange() : clicked
        setSelectedRange(NSUnionRange(anchor, clicked))
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]),
              next.type == .leftMouseDragged {
            autoscroll(with: next)
            if let line = gutterLineRange(atY: convert(next.locationInWindow, from: nil).y) {
                setSelectedRange(NSUnionRange(anchor, line))
            }
        }
    }

    /// The source line whose rows include `y` (view coordinates), with its line
    /// break, numbered as the gutter numbers it. Above the text this is the
    /// first line; below it, the last.
    func gutterLineRange(atY y: CGFloat) -> NSRange? {
        guard let layoutManager, let textContainer else { return nil }
        let string = self.string as NSString
        let containerY = y - textContainerOrigin.y
        layoutManager.ensureLayout(for: textContainer)
        // A document ending in a line break has an empty last line with no
        // glyphs, laid out as the extra line fragment.
        if layoutManager.extraLineFragmentTextContainer != nil,
           containerY >= layoutManager.extraLineFragmentRect.minY {
            return MarkdownEditorView.Coordinator.sourceLineRange(containing: string.length, in: string)
        }
        guard layoutManager.numberOfGlyphs > 0 else { return NSRange(location: 0, length: 0) }
        let glyph = layoutManager.glyphIndex(for: NSPoint(x: 0, y: containerY), in: textContainer)
        let character = layoutManager.characterIndexForGlyph(at: glyph)
        return MarkdownEditorView.Coordinator.sourceLineRange(containing: character, in: string)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, ModeKeyboardShortcut(event: event) == MarkdownPasteCommand.plainShortcut {
            pasteAsPlainText(nil)
            return true
        }
        guard !hasMarkedText() else { return super.performKeyEquivalent(with: event) }
        if window?.firstResponder === self, let shortcut = ModeKeyboardShortcut(event: event),
           let item = MarkdownFormatCommand.items.first(where: { $0.shortcut == shortcut }) {
            return performMarkdownAction(item.action)
        }
        if let action = findAction(for: event) {
            onFindAction?(action)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { markdownPasteController.cancel() }
        return resigned
    }

    override func pasteAsPlainText(_ sender: Any?) { markdownPasteController.perform(.plainText) }
    @objc func pasteAsMarkdown(_ sender: Any?) { markdownPasteController.perform(.markdown) }
    @objc func pasteAsTable(_ sender: Any?) { markdownPasteController.perform(.table) }

    // MARK: - Image paste / drop

    /// Intercepts a paste that carries image file URLs or raw image data, routing
    /// it through the attachment flow. Anything else falls back to normal text
    /// paste. An image payload is never allowed to fall through, so a cancelled
    /// save or write failure inserts nothing instead of dropping a path or raw
    /// bytes into the Markdown source.
    override func paste(_ sender: Any?) {
        isPasting = true
        defer { isPasting = false }
        let sources = imageSources(fromPasteboard: NSPasteboard.general)
        guard !sources.isEmpty else {
            let selection = selectedRange()
            // A selected clause inside provisional IME text isn't a link label.
            if !hasMarkedText(), selection.length > 0,
               let pasted = NSPasteboard.general.string(forType: .string),
               MarkdownEditing.clipboardURL(pasted) != nil,
               let edit = MarkdownEditing.edit(string, selection: selection, action: .link,
                                               clipboard: pasted) {
                applyMarkdownEdit(edit)
                return
            }
            super.paste(sender)
            return
        }
        let range = selectedRange(), source = string
        Task { [weak self] in
            guard let self, self.selectedRange() == range,
                  (self.string as NSString).isEqual(to: source) else { return }
            await self.onInsertImageAttachments?(sources, range, source)
        }
    }

    /// Enables the Paste command when the clipboard holds image data or image file
    /// URLs. A plain-text `NSTextView` (`isRichText == false`) otherwise reports
    /// paste as invalid for an image-only clipboard — there is no string type — so
    /// `Cmd+V` would be a no-op and `paste(_:)` above would never run.
    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if [#selector(pasteAsPlainText(_:)), #selector(pasteAsMarkdown(_:)), #selector(pasteAsTable(_:))].contains(menuItem.action) {
            guard markdownPasteController.canPerform else { return false }
            let types = Set(NSPasteboard.general.types ?? [])
            return menuItem.action == #selector(pasteAsMarkdown(_:)) ? !types.isDisjoint(with: [.string, .html, .rtf]) : types.contains(.string)
        }
        if menuItem.action == #selector(NSText.paste(_:)) {
            let pasteboard = NSPasteboard.general
            let options: [NSPasteboard.ReadingOptionKey: Any] = [
                .urlReadingFileURLsOnly: true,
                .urlReadingContentsConformToTypes: [UTType.image.identifier]
            ]
            if pasteboard.canReadObject(forClasses: [NSURL.self], options: options) ||
               pasteboard.canReadObject(forClasses: [NSImage.self], options: nil) {
                return true
            }
        }
        return super.validateMenuItem(menuItem)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if !imageFileSources(fromDrag: sender.draggingPasteboard).isEmpty {
            return .copy
        }
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if !imageFileSources(fromDrag: sender.draggingPasteboard).isEmpty {
            return .copy
        }
        return super.draggingUpdated(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if !imageFileSources(fromDrag: sender.draggingPasteboard).isEmpty {
            return true
        }
        return super.prepareForDragOperation(sender)
    }

    /// Handles a drop of one or more image files: resolves the drop insertion
    /// point immediately, then defers the attachment write so a modal save panel
    /// (for an untitled document) never opens while the drag session is settling.
    /// References are inserted in drop order at the drop point.
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let sources = imageFileSources(fromDrag: sender.draggingPasteboard)
        guard !sources.isEmpty else {
            return super.performDragOperation(sender)
        }

        let dropPoint = convert(sender.draggingLocation, from: nil)
        let insertionIndex = characterIndexForInsertion(at: dropPoint)
        let source = string, selection = selectedRange()
        let range = NSRange(location: min(insertionIndex, (source as NSString).length), length: 0)
        Task { [weak self] in
            guard let self, self.selectedRange() == selection,
                  (self.string as NSString).isEqual(to: source) else { return }
            self.window?.makeFirstResponder(self)
            await self.onInsertImageAttachments?(sources, range, source)
        }
        return true
    }

    /// Image sources on the pasteboard, preferring image file URLs over raw
    /// bitmap data (a screenshot). Returns an empty array when neither is present.
    private func imageSources(fromPasteboard pasteboard: NSPasteboard) -> [ImageAttachmentSource] {
        if let urls = imageFileURLs(from: pasteboard), !urls.isEmpty {
            return urls.map { .file($0) }
        }
        let preferred: [NSPasteboard.PasteboardType] = [.png, .tiff]
        let otherImages = (pasteboard.types ?? []).filter {
            !preferred.contains($0) && UTType($0.rawValue)?.conforms(to: .image) == true
        }
        for type in preferred + otherImages {
            if let data = pasteboard.data(forType: type) { return [.imageData(data)] }
        }
        return []
    }

    private func imageFileSources(fromDrag pasteboard: NSPasteboard) -> [ImageAttachmentSource] {
        (imageFileURLs(from: pasteboard) ?? []).map { .file($0) }
    }

    /// Image-typed file URLs on `pasteboard`, in order, or `nil` when there are none.
    private func imageFileURLs(from pasteboard: NSPasteboard) -> [URL]? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.image.identifier]
        ]
        return pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]
    }

    override func performFindPanelAction(_ sender: Any?) {
        onFindAction?(.fromFindMenuItem(sender))
    }

    override func performTextFinderAction(_ sender: Any?) {
        onFindAction?(.fromFindMenuItem(sender))
    }

    private func findAction(for event: NSEvent) -> FindCommand.Action? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command),
              !flags.contains(.control),
              let key = event.charactersIgnoringModifiers?.lowercased() else {
            return nil
        }

        switch key {
        case "f":
            return flags.contains(.option) ? .showReplace : .show
        case "g":
            return flags.contains(.shift) ? .previous : .next
        default:
            return nil
        }
    }
}
