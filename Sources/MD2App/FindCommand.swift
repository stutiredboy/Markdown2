import AppKit
import Foundation

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

    init(_ action: Action) {
        self.action = action
    }
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
