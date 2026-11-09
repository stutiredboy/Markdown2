import AppKit
import Foundation
import MD2Core

/// A find action relayed from a menu command to whichever document surface is
/// currently active. Each instance carries a fresh `token` so that repeating the
/// same action (e.g. pressing ⌘G twice) still registers as a change for
/// SwiftUI's `onChange` observation.
struct FindCommand: Equatable {
    enum Action {
        case show
        case showReplace
        case next
        case previous
        /// Return in the query field: run/confirm the search for the current
        /// query without advancing to the next match. Produced only by the find
        /// bar's Return; the menu never emits it.
        case search
    }

    let action: Action
    let token = UUID()

    init(_ action: Action) {
        self.action = action
    }
}

struct FindReplaceCommand: Equatable {
    enum Action {
        case current
        case all
    }

    let action: Action
    let token = UUID()
    let snapshot: FindReplacementSnapshot?

    init(_ action: Action, snapshot: FindReplacementSnapshot? = nil) {
        self.action = action
        self.snapshot = snapshot
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.token == rhs.token }
}

/// A presentation-mode action relayed from app commands to the active document
/// view. Each instance carries a fresh token so repeating the same command still
/// reaches SwiftUI's `onChange` observation.
struct ModeCommand: Equatable {
    let mode: EditorMode
    let token = UUID()

    init(_ mode: EditorMode) {
        self.mode = mode
    }
}

extension FindCommand.Action {
    /// Maps a standard Find menu item (whose tag carries an `NSTextFinder.Action`)
    /// to a find action. Shared by the editor and preview surfaces so both route
    /// the system Find menu identically. Unknown items fall back to `.show`.
    static func fromFindMenuItem(_ sender: Any?) -> FindCommand.Action {
        guard let menuItem = sender as? NSMenuItem,
              let textFinderAction = NSTextFinder.Action(rawValue: menuItem.tag) else {
            return .show
        }

        switch textFinderAction {
        case .nextMatch:
            return .next
        case .previousMatch:
            return .previous
        case .showReplaceInterface:
            return .showReplace
        default:
            return .show
        }
    }
}

/// A request to select one 1-based source line in the editor, sent when a
/// preview gutter number is clicked. The `token` makes a second click on the
/// same line a new request, so it reselects the line after the caret moved.
struct LineSelectionRequest: Equatable {
    let line: Int
    let token = UUID()

    init(line: Int) {
        self.line = line
    }
}

/// A deferred native edit is valid only for the exact source, query, replacement,
/// caret/selection and options the user invoked it on. UTF-16 literal equality
/// matters even when two strings look canonically identical.
@MainActor
struct FindReplacementSnapshot {
    let source: String
    let query: String
    let replacement: String
    let selections: [NSRange]
    let options: TextSearch.Options
    let scope: FindSession.Scope
    let identity: UUID

    init(query: String, replacement: String, textView: NSTextView, find: FindSession) {
        self.source = textView.string
        self.query = query
        self.replacement = replacement
        selections = textView.selectedRanges.map(\.rangeValue)
        options = find.options
        scope = find.scope
        identity = find.identity
    }

    func isCurrent(query: String, replacement: String, textView: NSTextView, find: FindSession) -> Bool {
        identity == find.identity && options == find.options && scope == find.scope
            && selections == textView.selectedRanges.map(\.rangeValue)
            && (self.query as NSString).isEqual(to: query)
            && (self.replacement as NSString).isEqual(to: replacement)
            && (source as NSString).isEqual(to: textView.string)
    }
}
