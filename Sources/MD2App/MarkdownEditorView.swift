import AppKit
import MD2Core
import SwiftUI
import UniformTypeIdentifiers

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
    /// A next/previous navigation request; consumed once applied.
    @Binding var findNavigation: FindCommand?
    /// Replacement text for edit-mode replace actions.
    @Binding var findReplacement: String
    /// A replace-current/all request; consumed once applied.
    @Binding var replaceCommand: FindReplaceCommand?
    /// Changes whenever the editor surface should become first responder.
    let focusToken: UUID
    /// Programmatic line/anchor jumps usually focus the editor in single-pane
    /// mode. In Side by Side, the editor can be only the scroll follower, so it
    /// must not steal focus from the preview pane.
    var focusOnProgrammaticScroll: Bool = true
    /// Called when the text view receives a standard Find key/menu action before
    /// SwiftUI commands can route it through `DocumentStore`.
    var onFindShortcut: (_ action: FindCommand.Action) -> Void = { _ in }
    /// Reports match count and the 1-based index of the current match.
    var onFindResult: (_ total: Int, _ index: Int) -> Void = { _, _ in }
    /// Turns pasted/dropped image sources into stored attachments and returns the
    /// Markdown text to insert (one `![alt](path)` per image, newline-joined), or
    /// `nil` when nothing should be inserted (unsupported payload, cancelled save,
    /// or a write failure). The editor inserts the returned text on the native
    /// edit path so dirty marking, styling, autosave, selection, and undo apply.
    var onInsertImageAttachments: (_ sources: [ImageAttachmentSource]) -> String? = { _ in nil }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true

        // Build the TextKit 1 stack manually so the editor uses a custom layout
        // manager that paints continuous code-block backgrounds.
        let textStorage = NSTextStorage()
        let layoutManager = CodeBlockLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(
            containerSize: NSSize(width: scrollView.contentSize.width, height: .greatestFiniteMagnitude)
        )
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)

        let textView = MarkdownSourceTextView(frame: .zero, textContainer: textContainer)
        textView.onFindAction = { action in
            context.coordinator.onFindShortcut(action)
        }
        textView.onInsertImageAttachments = onInsertImageAttachments
        // Accept image file drops on top of whatever the text view already takes
        // (string drags for in-editor text move), so the drop handler can turn
        // dropped images into attachments without disabling text drag-and-drop.
        textView.registerForDraggedTypes(textView.registeredDraggedTypes + [.fileURL])
        textView.delegate = context.coordinator
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
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: .greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false

        MarkdownTextStyler.apply(to: textView)

        scrollView.documentView = textView

        // Observe scrolling so the top visible line can anchor a mode switch.
        let clipView = scrollView.contentView
        clipView.postsBoundsChangedNotifications = true
        context.coordinator.observe(scrollView: scrollView)

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
            textView.window?.makeFirstResponder(textView)
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.onEnterPreview = onEnterPreview
        context.coordinator.onAnchorLineChange = onAnchorLineChange
        context.coordinator.onTextEdit = onTextEdit
        context.coordinator.onFindShortcut = onFindShortcut
        context.coordinator.onFindResult = onFindResult
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
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if let sourceTextView = textView as? MarkdownSourceTextView {
            sourceTextView.onFindAction = { action in
                context.coordinator.onFindShortcut(action)
            }
            sourceTextView.onInsertImageAttachments = onInsertImageAttachments
        }

        if context.coordinator.shouldApplyBoundText(text, to: textView) {
            let selectedRanges = textView.selectedRanges
            textView.string = text
            MarkdownTextStyler.apply(to: textView)
            // External content (e.g. a reload after the file changed on disk)
            // can be shorter than the old selection; restoring an out-of-range
            // selection raises. Clamp each range to the new length.
            let length = (text as NSString).length
            let clamped = selectedRanges.map { value -> NSValue in
                let range = value.rangeValue
                let location = min(range.location, length)
                return NSValue(range: NSRange(location: location, length: min(range.length, length - location)))
            }
            textView.selectedRanges = clamped.isEmpty
                ? [NSValue(range: NSRange(location: length, length: 0))]
                : clamped
        }

        context.coordinator.updateFind(query: findQuery, in: textView)

        // Consume navigation/replace commands by their token, not by clearing the
        // binding here. Mutating an observed binding inside `updateNSView` does not
        // reliably take effect before the next update, so a `self.findNavigation =
        // nil` here can be re-read as non-nil on the immediately following pass that
        // the command's own side effects (a match-count change) trigger — replaying
        // the action forever. Tracking the last-consumed token in the coordinator
        // (the same pattern as `lastFocusToken`) runs each command exactly once.
        if let findNavigation, context.coordinator.lastFindNavigationToken != findNavigation.token {
            context.coordinator.lastFindNavigationToken = findNavigation.token
            context.coordinator.navigateFind(forward: findNavigation.action != .previous, in: textView)
        }

        if let replaceCommand, context.coordinator.lastReplaceCommandToken != replaceCommand.token {
            context.coordinator.lastReplaceCommandToken = replaceCommand.token
            context.coordinator.replace(
                replaceCommand.action,
                replacement: findReplacement,
                in: textView
            )
        }

        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
            }
        }

        if let anchor = jumpAnchor {
            context.coordinator.applyAnchorUntilSettled(anchor, in: scrollView) { anchor, scrollView in
                apply(anchor: anchor, in: scrollView, textView: textView, focus: focusOnProgrammaticScroll)
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
                    scroll(to: targetLine, in: textView, focus: focusOnProgrammaticScroll)
                }
                if applied {
                    self.jumpLine = nil
                    self.jumpFraction = nil
                } else {
                    DispatchQueue.main.async {
                        _ = coordinator.performProgrammaticScroll(in: scrollView) {
                            scroll(to: targetLine, in: textView, focus: focusOnProgrammaticScroll)
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
    }

    /// Applies a mode-switch viewport anchor: a source-line anchor resolves to
    /// its target line (block start advanced by intra-block progress) and is
    /// placed near the top of the viewport; otherwise the proportional scroll
    /// fraction is the fallback. Both paths force layout and clamp the offset.
    private func apply(
        anchor: ViewportAnchor,
        in scrollView: NSScrollView,
        textView: NSTextView,
        focus: Bool
    ) -> Bool {
        if let targetLine = anchor.targetSourceLine {
            return scroll(to: targetLine, in: textView, focus: focus)
        }
        return scroll(toFraction: anchor.scrollFraction, in: scrollView)
    }

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator(text: $text)
        coordinator.onEnterPreview = onEnterPreview
        coordinator.onAnchorLineChange = onAnchorLineChange
        coordinator.onTextEdit = onTextEdit
        coordinator.onFindShortcut = onFindShortcut
        coordinator.onFindResult = onFindResult
        return coordinator
    }

    /// Scrolls the editor to a vertical fraction (0...1) of its content. Used as
    /// the fallback when no source-line anchor is available.
    private func scroll(toFraction fraction: Double, in scrollView: NSScrollView) -> Bool {
        guard let documentView = scrollView.documentView else { return false }
        // Settle layout first so the content height reflects the real wrapped
        // text rather than a freshly created, not-yet-laid-out text view.
        if let textView = documentView as? NSTextView,
           let layoutManager = textView.layoutManager,
           let textContainer = textView.textContainer {
            layoutManager.ensureLayout(for: textContainer)
        }
        let clamped = min(max(fraction, 0), 1)
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

    private func scroll(to line: Int, in textView: NSTextView, focus: Bool = true) -> Bool {
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

        layoutManager.ensureLayout(for: textContainer)
        let glyphRange = layoutManager.glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        // Convert from text-container coordinates to the text view (document)
        // coordinate space the clip view scrolls in.
        let origin = textView.textContainerOrigin
        rect.origin.y += origin.y

        let documentHeight = scrollableContentHeight(for: textView)
        let visibleHeight = scrollView.contentView.bounds.height
        guard visibleHeight > 0 else { return false }
        if documentHeight <= visibleHeight {
            return true
        }
        // Leave a small top margin (the container inset) so the line is not
        // flush against the very top edge. The shared clamp keeps the offset in
        // the scrollable range and returns 0 when the document fits the viewport,
        // so a short document stays pinned to the top.
        let targetY = CGFloat(clampedScrollOffset(
            targetY: Double(rect.minY - origin.y),
            contentHeight: Double(documentHeight),
            viewportHeight: Double(visibleHeight)
        ))
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        return true
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        var isApplyingStyle = false
        var onEnterPreview: () -> Void = {}
        var onAnchorLineChange: (_ line: Int, _ drivesPreviewSync: Bool) -> Void = { _, _ in }
        var onTextEdit: (_ caretLine: Int) -> Void = { _ in }
        var onFindShortcut: (_ action: FindCommand.Action) -> Void = { _ in }
        var onFindResult: (_ total: Int, _ index: Int) -> Void = { _, _ in }
        var lastFocusToken: UUID?
        /// Tokens of the most recently consumed find/replace commands, so a command
        /// is acted on exactly once even if `updateNSView` re-runs while the same
        /// command value is still held by the binding. See the consumption site.
        var lastFindNavigationToken: UUID?
        var lastReplaceCommandToken: UUID?
        private weak var scrollView: NSScrollView?
        /// True while a programmatic scroll (mode-switch jump, outline jump,
        /// find reveal) is in flight, so its transient positions are never
        /// reported back as the user's anchor.
        private var isProgrammaticScroll = false
        private var lastFindQuery = ""
        private var lastIndexedText = ""
        private var matches: [NSRange] = []
        private var currentMatchIndex = -1
        private var highlightedRanges: [NSRange] = []
        private var editViewportRestoreToken = UUID()

        init(text: Binding<String>) {
            _text = text
        }

        /// SwiftUI may refresh this representable for unrelated state while an
        /// input method owns marked text in the editor. Replacing `string` in
        /// that window destroys the input method's composition buffer and can
        /// commit a stale candidate at a different selection.
        @MainActor func shouldApplyBoundText(_ boundText: String, to textView: NSTextView) -> Bool {
            textView.string != boundText && !isApplyingStyle && !textView.hasMarkedText()
        }

        @MainActor func updateFind(query: String, in textView: NSTextView) {
            // Rebuilding highlights can select/reveal a match. Never do that
            // while the input method owns the selection for marked text.
            guard !textView.hasMarkedText() else { return }
            let textChanged = textView.string != lastIndexedText
            let queryChanged = query != lastFindQuery
            guard textChanged || queryChanged else {
                return
            }

            rebuildFindIndex(
                query: query,
                in: textView,
                preferredIndex: queryChanged ? 0 : currentMatchIndex
            )
        }

        @MainActor func navigateFind(forward: Bool, in textView: NSTextView) {
            guard !matches.isEmpty else {
                reportFindResult()
                return
            }

            let delta = forward ? 1 : -1
            currentMatchIndex = wrappedIndex(currentMatchIndex + delta, count: matches.count)
            applyFindHighlights(in: textView)
            revealCurrentMatch(in: textView)
            reportFindResult()
        }

        @MainActor func replace(
            _ action: FindReplaceCommand.Action,
            replacement: String,
            in textView: NSTextView
        ) {
            guard !lastFindQuery.isEmpty, !matches.isEmpty else {
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
            let range = matches[currentMatchIndex]
            textView.insertText(replacement, replacementRange: range)
            rebuildFindIndex(
                query: lastFindQuery,
                in: textView,
                preferredIndex: min(currentMatchIndex, max(0, matches.count - 1))
            )
        }

        @MainActor private func replaceAll(with replacement: String, in textView: NSTextView) {
            let fullRange = NSRange(location: 0, length: (textView.string as NSString).length)
            let mutable = NSMutableString(string: textView.string)
            for range in matches.reversed() {
                mutable.replaceCharacters(in: range, with: replacement)
            }

            guard textView.shouldChangeText(in: fullRange, replacementString: mutable as String) else {
                return
            }

            textView.textStorage?.replaceCharacters(in: fullRange, with: mutable as String)
            textView.didChangeText()
            rebuildFindIndex(query: lastFindQuery, in: textView, preferredIndex: 0)
        }

        @MainActor private func rebuildFindIndex(
            query: String,
            in textView: NSTextView,
            preferredIndex: Int
        ) {
            clearFindHighlights(in: textView)
            lastFindQuery = query
            lastIndexedText = textView.string
            matches = TextSearch.matches(of: query, in: textView.string)

            if matches.isEmpty {
                currentMatchIndex = -1
            } else {
                currentMatchIndex = wrappedIndex(preferredIndex, count: matches.count)
            }

            applyFindHighlights(in: textView)
            revealCurrentMatch(in: textView)
            reportFindResult()
        }

        @MainActor private func applyFindHighlights(in textView: NSTextView) {
            guard let layoutManager = textView.layoutManager else { return }
            highlightedRanges = matches
            let normalColor = NSColor.systemYellow.withAlphaComponent(0.45)
            let currentColor = NSColor.systemOrange.withAlphaComponent(0.6)

            for (index, range) in matches.enumerated() {
                layoutManager.addTemporaryAttribute(
                    .backgroundColor,
                    value: index == currentMatchIndex ? currentColor : normalColor,
                    forCharacterRange: range
                )
            }
        }

        @MainActor private func clearFindHighlights(in textView: NSTextView) {
            guard let layoutManager = textView.layoutManager else { return }
            for range in highlightedRanges {
                layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
            }
            highlightedRanges = []
        }

        @MainActor private func revealCurrentMatch(in textView: NSTextView) {
            guard currentMatchIndex >= 0, currentMatchIndex < matches.count else { return }
            let range = matches[currentMatchIndex]
            textView.setSelectedRange(range)
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

        @MainActor private func reportFindResult() {
            let total: Int
            let index: Int
            if matches.isEmpty {
                total = 0
                index = 0
            } else {
                total = matches.count
                index = currentMatchIndex + 1
            }

            DispatchQueue.main.async { [weak self] in
                self?.onFindResult(total, index)
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

            func step() {
                guard self.settlingAnchor == anchor else { return }
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
                    .map { scrollableContentHeight(for: $0) } ?? 0
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
            guard let textView = scrollView.documentView as? NSTextView,
                  let line = topVisibleLine(in: scrollView) else { return nil }

            let visibleHeight = Double(scrollView.contentView.bounds.height)
            let contentHeight = Double(scrollableContentHeight(for: textView))
            let offset = Double(scrollView.contentView.bounds.origin.y)
            let maxOffset = contentHeight - visibleHeight
            let fraction = maxOffset > 0 ? offset / maxOffset : 0

            return ViewportAnchor(
                sourceLine: line,
                intraBlockProgress: 0,
                viewportTopInset: Double(textView.textContainerInset.height),
                scrollFraction: fraction
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

        @MainActor static func topVisibleLine(in scrollView: NSScrollView) -> Int? {
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
            layoutManager.ensureLayout(for: textContainer)
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

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
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

            // A click or keyboard selection move after an edit supersedes the
            // old viewport. Otherwise a delayed restore from that edit can yank
            // the viewport back after the caret has deliberately moved.
            if !isApplyingStyle {
                editViewportRestoreToken = UUID()
            }
        }

        @MainActor func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            // Marked text is the input method's private, provisional buffer. It
            // must not enter the document binding, Markdown restyling, preview
            // rendering, autosave, or selection restoration before commit.
            guard !textView.hasMarkedText() else {
                editViewportRestoreToken = UUID()
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

            let selectedRanges = textView.selectedRanges
            isApplyingStyle = true
            MarkdownTextStyler.apply(to: textView)
            isApplyingStyle = false
            textView.selectedRanges = selectedRanges
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

private final class MarkdownSourceTextView: NSTextView {
    var onFindAction: ((FindCommand.Action) -> Void)?
    /// Turns pasted/dropped image sources into stored attachments and returns the
    /// Markdown to insert, or `nil` to insert nothing. Set by `MarkdownEditorView`.
    var onInsertImageAttachments: (([ImageAttachmentSource]) -> String?)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let action = findAction(for: event) {
            onFindAction?(action)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: - Image paste / drop

    /// Intercepts a paste that carries image file URLs or raw image data, routing
    /// it through the attachment flow. Anything else falls back to normal text
    /// paste. An image payload is never allowed to fall through, so a cancelled
    /// save or write failure inserts nothing instead of dropping a path or raw
    /// bytes into the Markdown source.
    override func paste(_ sender: Any?) {
        let sources = imageSources(fromPasteboard: NSPasteboard.general)
        guard !sources.isEmpty else {
            super.paste(sender)
            return
        }
        if let snippet = onInsertImageAttachments?(sources), !snippet.isEmpty {
            insertText(snippet, replacementRange: selectedRange())
        }
    }

    /// Enables the Paste command when the clipboard holds image data or image file
    /// URLs. A plain-text `NSTextView` (`isRichText == false`) otherwise reports
    /// paste as invalid for an image-only clipboard — there is no string type — so
    /// `Cmd+V` would be a no-op and `paste(_:)` above would never run.
    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(NSText.paste(_:)),
           !imageSources(fromPasteboard: .general).isEmpty {
            return true
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
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self)
            guard let snippet = self.onInsertImageAttachments?(sources), !snippet.isEmpty else {
                return
            }
            let length = (self.string as NSString).length
            let range = NSRange(location: min(insertionIndex, length), length: 0)
            self.insertText(snippet, replacementRange: range)
        }
        return true
    }

    /// Image sources on the pasteboard, preferring image file URLs over raw
    /// bitmap data (a screenshot). Returns an empty array when neither is present.
    private func imageSources(fromPasteboard pasteboard: NSPasteboard) -> [ImageAttachmentSource] {
        if let urls = imageFileURLs(from: pasteboard), !urls.isEmpty {
            return urls.map { .file($0) }
        }
        if pasteboard.canReadObject(forClasses: [NSImage.self], options: nil),
           let images = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage] {
            return images.compactMap { $0.tiffRepresentation.map(ImageAttachmentSource.imageData) }
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
