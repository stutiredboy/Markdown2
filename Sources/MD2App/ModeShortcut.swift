import AppKit
import Foundation
import SwiftUI

struct ModeShortcutModifiers: OptionSet, Codable, Hashable {
    let rawValue: Int

    static let command = ModeShortcutModifiers(rawValue: 1 << 0)
    static let option = ModeShortcutModifiers(rawValue: 1 << 1)
    static let control = ModeShortcutModifiers(rawValue: 1 << 2)
    static let shift = ModeShortcutModifiers(rawValue: 1 << 3)

    init(rawValue: Int) {
        self.rawValue = rawValue
    }

    init(_ flags: NSEvent.ModifierFlags) {
        var modifiers: ModeShortcutModifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        self = modifiers
    }

    var eventModifiers: EventModifiers {
        var modifiers = EventModifiers()
        if contains(.command) { modifiers.insert(.command) }
        if contains(.option) { modifiers.insert(.option) }
        if contains(.control) { modifiers.insert(.control) }
        if contains(.shift) { modifiers.insert(.shift) }
        return modifiers
    }

    var displayParts: [String] {
        var parts: [String] = []
        if contains(.command) { parts.append("Command") }
        if contains(.option) { parts.append("Option") }
        if contains(.control) { parts.append("Control") }
        if contains(.shift) { parts.append("Shift") }
        return parts
    }
}

struct ModeKeyboardShortcut: Codable, Hashable {
    var key: String
    var modifiers: ModeShortcutModifiers

    init(key: String, modifiers: ModeShortcutModifiers) {
        self.key = Self.normalizedKey(key) ?? key.lowercased()
        self.modifiers = modifiers
    }

    init?(event: NSEvent) {
        guard event.type == .keyDown,
              let rawKey = Self.normalizedKey(event.charactersIgnoringModifiers ?? event.characters ?? "") else {
            return nil
        }
        key = rawKey
        modifiers = ModeShortcutModifiers(event.modifierFlags)
    }

    static func command(_ key: String) -> ModeKeyboardShortcut {
        ModeKeyboardShortcut(key: key, modifiers: [.command])
    }

    var displayString: String {
        (modifiers.displayParts + [keyDisplayName]).joined(separator: "-")
    }

    var keyEquivalent: KeyEquivalent {
        switch key {
        case "space":
            .space
        case "tab":
            .tab
        case "escape":
            .escape
        case "return":
            .return
        case "delete":
            .delete
        default:
            KeyEquivalent(Character(key))
        }
    }

    var isWellFormed: Bool {
        !modifiers.isEmpty && Self.normalizedKey(key) != nil
    }

    private var keyDisplayName: String {
        switch key {
        case "space": "Space"
        case "tab": "Tab"
        case "escape": "Escape"
        case "return": "Return"
        case "delete": "Delete"
        default: key.uppercased()
        }
    }

    private static func normalizedKey(_ raw: String) -> String? {
        guard !raw.isEmpty else { return nil }
        switch raw {
        case " ":
            return "space"
        case "\t":
            return "tab"
        case "\u{1B}":
            return "escape"
        case "\r", "\n":
            return "return"
        case "\u{7F}":
            return "delete"
        default:
            let lowercased = raw.lowercased()
            if ["space", "tab", "escape", "return", "delete"].contains(lowercased) {
                return lowercased
            }
            guard lowercased.count == 1 else { return nil }
            return lowercased
        }
    }
}

struct ModeShortcutAssignment: Identifiable, Hashable {
    var mode: EditorMode
    var shortcut: ModeKeyboardShortcut

    var id: EditorMode {
        mode
    }
}

struct ModeShortcutConfiguration: Codable, Equatable {
    var edit: ModeKeyboardShortcut
    var preview: ModeKeyboardShortcut
    var sideBySide: ModeKeyboardShortcut

    static let `default` = ModeShortcutConfiguration(
        edit: .command("1"),
        preview: .command("2"),
        sideBySide: .command("3")
    )

    subscript(mode: EditorMode) -> ModeKeyboardShortcut {
        get {
            switch mode {
            case .write:
                edit
            case .read:
                preview
            case .split:
                sideBySide
            }
        }
        set {
            switch mode {
            case .write:
                edit = newValue
            case .read:
                preview = newValue
            case .split:
                sideBySide = newValue
            }
        }
    }

    var assignments: [ModeShortcutAssignment] {
        [
            ModeShortcutAssignment(mode: .write, shortcut: edit),
            ModeShortcutAssignment(mode: .read, shortcut: preview),
            ModeShortcutAssignment(mode: .split, shortcut: sideBySide)
        ]
    }
}

enum ModeShortcutValidationError: Equatable {
    case malformed
    case duplicate(existingMode: EditorMode)
    case appCommand(commandName: String)
    case systemReserved(reason: String)
}

enum ModeShortcutValidator {
    static func validate(
        _ shortcut: ModeKeyboardShortcut,
        for mode: EditorMode,
        in configuration: ModeShortcutConfiguration
    ) -> ModeShortcutValidationError? {
        guard shortcut.isWellFormed else {
            return .malformed
        }

        for assignment in configuration.assignments where assignment.mode != mode {
            if assignment.shortcut == shortcut {
                return .duplicate(existingMode: assignment.mode)
            }
        }

        if let commandName = appCommandConflicts[shortcut] {
            return .appCommand(commandName: commandName)
        }

        if let reason = systemReservedReason(for: shortcut) {
            return .systemReserved(reason: reason)
        }

        return nil
    }

    static func isValidConfiguration(_ configuration: ModeShortcutConfiguration) -> Bool {
        configuration.assignments.allSatisfy { assignment in
            validate(assignment.shortcut, for: assignment.mode, in: configuration) == nil
        }
    }

    private static let appCommandConflicts: [ModeKeyboardShortcut: String] = [
        .command("n"): "New",
        .command("o"): "Open",
        .command("s"): "Save",
        .command("w"): "Close",
        .command("p"): "Print",
        .command("f"): "Find",
        ModeKeyboardShortcut(key: "f", modifiers: [.command, .option]): "Find and Replace",
        .command("g"): "Find Next",
        ModeKeyboardShortcut(key: "g", modifiers: [.command, .shift]): "Find Previous",
        .command(","): "Settings",
        .command("a"): "Select All",
        .command("c"): "Copy",
        .command("v"): "Paste",
        .command("x"): "Cut",
        .command("z"): "Undo",
        ModeKeyboardShortcut(key: "z", modifiers: [.command, .shift]): "Redo"
    ]

    private static func systemReservedReason(for shortcut: ModeKeyboardShortcut) -> String? {
        let command = shortcut.modifiers == [.command]
        let commandShift = shortcut.modifiers == [.command, .shift]
        let commandOption = shortcut.modifiers == [.command, .option]
        let controlOnly = shortcut.modifiers == [.control]

        if shortcut.key == "escape", shortcut.modifiers.isEmpty {
            return "Escape"
        }
        if command, shortcut.key == "space" {
            return "Spotlight"
        }
        if command, shortcut.key == "tab" {
            return "App Switcher"
        }
        if command, shortcut.key == "`" {
            return "Window Cycle"
        }
        if command, shortcut.key == "h" {
            return "Hide Application"
        }
        if command, shortcut.key == "m" {
            return "Minimize Window"
        }
        if command, shortcut.key == "q" {
            return "Quit Application"
        }
        if commandOption, shortcut.key == "escape" {
            return "Force Quit"
        }
        if commandShift, ["3", "4", "5"].contains(shortcut.key) {
            return "Screenshot"
        }
        if controlOnly, shortcut.key.count == 1, ("1"..."9").contains(shortcut.key) {
            return "Spaces"
        }
        return nil
    }
}
