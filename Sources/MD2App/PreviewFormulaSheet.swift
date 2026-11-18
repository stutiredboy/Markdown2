import AppKit
import MD2Core

/// A native draft owns its input method and Undo until the user applies it.
@MainActor
final class PreviewFormulaSheet: NSObject, NSTextViewDelegate {
    enum Outcome { case applied, stale, openSource }
    typealias Submit = @MainActor (String, () -> Bool) async -> DocumentStore.PreviewFormulaResult

    private var alert: NSAlert?
    private weak var input: FormulaTextView?
    private weak var applyButton: NSButton?
    private var pending: Task<Void, Never>?
    private var submit: Submit?
    private var checkingMessage = ""
    private var unsupportedMessage = ""

    func edit(_ source: String, in window: NSWindow, settings: AppSettings,
              onApply: @escaping Submit,
              onDismiss: @escaping (Outcome) -> Void) {
        guard alert == nil, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = settings.text(.formulaEditorTitle)
        alert.informativeText = settings.text(.formulaEditorInstructions)

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 430, height: 84))
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        let input = FormulaTextView(frame: NSRect(origin: .zero, size: scroll.contentSize))
        input.delegate = self
        input.string = source
        input.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        input.isRichText = false
        input.allowsUndo = true
        input.isAutomaticQuoteSubstitutionEnabled = false
        input.isAutomaticDashSubstitutionEnabled = false
        input.isAutomaticTextReplacementEnabled = false
        input.textContainerInset = NSSize(width: 6, height: 6)
        input.textContainer?.widthTracksTextView = true
        input.isVerticallyResizable = true
        input.autoresizingMask = [.width]
        input.setAccessibilityLabel(settings.text(.formulaEditorInput))
        input.setAccessibilityIdentifier("formula-source-input")
        input.setSelectedRange(NSRange(location: source.utf16.count, length: 0))
        input.onCompositionChange = { [weak self] in self?.updateApplyButton() }
        scroll.documentView = input
        alert.accessoryView = scroll

        let apply = alert.addButton(withTitle: settings.text(.formulaApply))
        apply.setAccessibilityIdentifier("formula-apply")
        apply.target = self
        apply.action = #selector(confirmEdit)
        addCancel(to: alert, settings: settings)
        let open = alert.addButton(withTitle: settings.text(.formulaOpenSource))
        open.setAccessibilityIdentifier("formula-open-source")
        alert.window.defaultButtonCell = nil
        // Plain Return belongs to the text input and its IME candidate panel.
        apply.keyEquivalent = "\r"
        apply.keyEquivalentModifierMask = [.command]
        alert.window.initialFirstResponder = input
        self.input = input
        applyButton = apply
        submit = onApply
        checkingMessage = settings.text(.formulaCheckingDraft)
        unsupportedMessage = settings.text(.formulaReplacementRequiresSource)
        updateApplyButton()

        present(alert, in: window) { response in
            switch response {
            case .OK: onDismiss(.applied)
            case .abort: onDismiss(.stale)
            case .alertThirdButtonReturn: onDismiss(.openSource)
            default: break
            }
        }
    }

    func offerSource(in window: NSWindow, settings: AppSettings, onOpen: @escaping () -> Void) {
        guard alert == nil, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = settings.text(.formulaSourceTitle)
        alert.informativeText = settings.text(.formulaSourceDetail)
        let open = alert.addButton(withTitle: settings.text(.formulaOpenSource))
        open.setAccessibilityIdentifier("formula-open-source")
        addCancel(to: alert, settings: settings)
        alert.window.initialFirstResponder = open
        present(alert, in: window) { response in
            if response == .alertFirstButtonReturn { onOpen() }
        }
    }

    private func addCancel(to alert: NSAlert, settings: AppSettings) {
        let cancel = alert.addButton(withTitle: settings.text(.cancel))
        cancel.setAccessibilityIdentifier("formula-cancel")
        cancel.keyEquivalent = "\u{1b}"
    }

    private func present(_ alert: NSAlert, in window: NSWindow,
                         onDismiss: @escaping (NSApplication.ModalResponse) -> Void) {
        self.alert = alert
        alert.beginSheetModal(for: window) { [weak self, weak alert] response in
            guard let self, let alert, self.alert === alert else { return }
            self.clear()
            onDismiss(response)
        }
    }

    func dismiss() {
        guard let alert else { return }
        clear()
        alert.window.sheetParent?.endSheet(alert.window, returnCode: .cancel)
    }

    private func clear() {
        pending?.cancel()
        pending = nil
        submit = nil
        alert = nil
        input = nil
        applyButton = nil
    }

    private var validDraft: String? {
        guard let input, !input.hasMarkedText() else { return nil }
        return DisplayFormulaEdit.validatedReplacement(input.string)
    }

    private func updateApplyButton() {
        applyButton?.isEnabled = pending == nil && validDraft != nil
    }

    @objc private func confirmEdit() {
        guard pending == nil, let draft = validDraft, let submit, let alert else { return }
        applyButton?.isEnabled = false
        input?.isEditable = false
        alert.informativeText = checkingMessage
        alert.layout()
        pending = Task { [weak self, weak alert] in
            let result = await submit(draft) {
                // Keep cancellation available during the worker render. Once
                // the native transaction is queued, prevent cancel semantics
                // from racing an edit that has already started.
                guard let self, let alert, self.alert === alert, !Task.isCancelled else { return false }
                alert.buttons.forEach { $0.isEnabled = false }
                alert.buttons[1].keyEquivalent = ""
                return true
            }
            guard let self, let alert, self.alert === alert, let window = alert.window.sheetParent else { return }
            pending = nil
            switch result {
            case .applied: window.endSheet(alert.window, returnCode: .OK)
            case .unchanged: window.endSheet(alert.window, returnCode: .cancel)
            case .stale: window.endSheet(alert.window, returnCode: .abort)
            case .requiresSource:
                alert.informativeText = unsupportedMessage
                alert.layout()
                input?.isEditable = true
                updateApplyButton()
                if let input { alert.window.makeFirstResponder(input) }
                NSAccessibility.post(element: alert.window, notification: .announcementRequested,
                                     userInfo: [.announcement: unsupportedMessage, .priority: NSAccessibilityPriorityLevel.high.rawValue])
            }
        }
    }

    func textDidChange(_ notification: Notification) {
        updateApplyButton()
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard !textView.hasMarkedText(), let window = textView.window else { return false }
        switch commandSelector {
        case #selector(NSResponder.insertTab(_:)): window.selectNextKeyView(textView)
        case #selector(NSResponder.insertBacktab(_:)): window.selectPreviousKeyView(textView)
        default: return false
        }
        return true
    }
}

private final class FormulaTextView: NSTextView {
    var onCompositionChange: (() -> Void)?

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        onCompositionChange?()
    }

    override func unmarkText() {
        super.unmarkText()
        onCompositionChange?()
    }
}
