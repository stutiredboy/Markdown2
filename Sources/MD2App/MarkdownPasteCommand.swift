import AppKit
import Combine
import MD2Core
import SwiftUI

struct MarkdownPasteCommand {
    static let plainShortcut = ModeKeyboardShortcut(key: "v", modifiers: [.command, .option, .shift])
}

/// SwiftUI commands observe AppKit focus and pasteboard type changes. This
/// instance belongs to the app, so opening the first document updates menus.
@MainActor
final class MarkdownPasteCommandState: ObservableObject {
    @Published private(set) var canPlainText = false
    @Published private(set) var canMarkdown = false
    @Published private(set) var canTable = false
    var responder: () -> NSResponder? = { NSApp?.keyWindow?.firstResponder }
    var types: () -> Set<NSPasteboard.PasteboardType> = { Set(NSPasteboard.general.types ?? []) }
    private var observations: [AnyCancellable] = []

    init(observe: Bool = true) {
        guard observe else { return }
        // didUpdate covers field-editor focus and menu tracking, which don't
        // necessarily change the key/main window. No clipboard data is read.
        let names = [NSApplication.didUpdateNotification, NSWindow.didBecomeKeyNotification,
                     NSWindow.didResignKeyNotification, NSWindow.willCloseNotification,
                     NSTextView.didChangeSelectionNotification]
        observations = names.map { name in
            NotificationCenter.default.publisher(for: name).sink { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        refresh()
    }
    func refresh() {
        let input = responder(), available = types()
        let plain: Bool, rich: Bool
        if let source = input as? MarkdownSourceTextView {
            plain = source.markdownPasteController.canPerform
            rich = plain
        } else if let native = input as? NSTextView {
            plain = native.isEditable && !native.hasMarkedText()
            rich = false
        } else { plain = false; rich = false }
        let nextPlain = plain && available.contains(.string)
        let nextMarkdown = rich && !available.isDisjoint(with: [.string, .html, .rtf])
        let nextTable = rich && available.contains(.string)
        if canPlainText != nextPlain { canPlainText = nextPlain }
        if canMarkdown != nextMarkdown { canMarkdown = nextMarkdown }
        if canTable != nextTable { canTable = nextTable }
    }
    func perform(_ kind: MarkdownPaste.Kind) {
        refresh()
        guard let input = responder() else { return }
        // Never ask AppKit to continue searching past the focused native field
        // into a source editor elsewhere in the responder chain.
        if let source = input as? MarkdownSourceTextView {
            switch kind {
            case .plainText: if canPlainText { source.pasteAsPlainText(nil) }
            case .markdown: if canMarkdown { source.pasteAsMarkdown(nil) }
            case .table: if canTable { source.pasteAsTable(nil) }
            }
        } else if kind == .plainText, canPlainText, let native = input as? NSTextView {
            native.pasteAsPlainText(nil)
        }
    }
}

struct MarkdownPasteCommandButtons: View {
    @ObservedObject var state: MarkdownPasteCommandState
    @ObservedObject var settings: AppSettings
    var body: some View {
        Button(settings.text(.pasteAsPlainText)) { state.perform(.plainText) }
            .keyboardShortcut("v", modifiers: [.command, .option, .shift])
            .disabled(!state.canPlainText)
        Button(settings.text(.pasteAsMarkdown)) { state.perform(.markdown) }
            .disabled(!state.canMarkdown)
        Button(settings.text(.pasteAsTable)) { state.perform(.table) }
            .disabled(!state.canTable)
    }
}
