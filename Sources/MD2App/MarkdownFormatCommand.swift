import MD2Core
import Foundation

/// One definition drives menu shortcuts, editor interception, and conflict
/// validation, so a formatting shortcut cannot silently become a mode switch.
struct MarkdownFormatCommand: Equatable {
    let action: MarkdownEditing.Action
    let token = UUID()

    struct Item {
        let title: L10nKey
        let action: MarkdownEditing.Action
        let shortcut: ModeKeyboardShortcut
        let conflictName: String
    }

    static let formatItems: [Item] = [
        Item(title: .formatBold, action: .bold, shortcut: .command("b"), conflictName: "Bold"),
        Item(title: .formatItalic, action: .italic, shortcut: .command("i"), conflictName: "Italic"),
        Item(title: .formatLink, action: .link, shortcut: .command("k"), conflictName: "Link"),
        Item(title: .formatCodeBlock, action: .codeBlock,
             shortcut: ModeKeyboardShortcut(key: "c", modifiers: [.command, .option]), conflictName: "Code Block"),
        Item(title: .formatTable, action: .table,
             shortcut: ModeKeyboardShortcut(key: "t", modifiers: [.command, .option]), conflictName: "Table")
    ]
    static let paragraphItems: [Item] = [
        Item(title: .formatBody, action: .heading(0), shortcut: .command("0"), conflictName: "Body"),
        Item(title: .formatHeading1, action: .heading(1), shortcut: headingShortcut(1), conflictName: "Heading 1"),
        Item(title: .formatHeading2, action: .heading(2), shortcut: headingShortcut(2), conflictName: "Heading 2"),
        Item(title: .formatHeading3, action: .heading(3), shortcut: headingShortcut(3), conflictName: "Heading 3"),
        Item(title: .formatHeading4, action: .heading(4), shortcut: headingShortcut(4), conflictName: "Heading 4"),
        Item(title: .formatHeading5, action: .heading(5), shortcut: headingShortcut(5), conflictName: "Heading 5"),
        Item(title: .formatHeading6, action: .heading(6), shortcut: headingShortcut(6), conflictName: "Heading 6")
    ]
    static var items: [Item] { formatItems + paragraphItems }

    private static func headingShortcut(_ level: Int) -> ModeKeyboardShortcut {
        ModeKeyboardShortcut(key: String(level), modifiers: [.command, .option])
    }
}
