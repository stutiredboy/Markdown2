import Testing
@testable import MD2App

struct MarkdownFormatCommandTests {
    @Test func formattingShortcutsAreUniqueAndReserved() {
        let items = MarkdownFormatCommand.items
        #expect(Set(items.map(\.shortcut)).count == items.count)
        for item in items {
            #expect(ModeShortcutValidator.validate(item.shortcut, for: .write, in: .default) ==
                    .appCommand(commandName: item.conflictName))
        }
        #expect(ModeShortcutValidator.isValidConfiguration(.default))
        #expect(!items.contains { ["1", "2", "3"].contains($0.shortcut.key) && $0.shortcut.modifiers == [.command] })
    }

    @Test func repeatedMenuActionsHaveDifferentTokens() {
        #expect(MarkdownFormatCommand(action: .bold) != MarkdownFormatCommand(action: .bold))
    }
}
