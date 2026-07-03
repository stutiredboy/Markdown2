import Testing
@testable import MD2App

struct EscRoutingTests {
    @Test func visibleFindBarIsDismissedInEveryMode() {
        #expect(EscRouting.action(findBarVisible: true, mode: .write) == .dismissFind)
        #expect(EscRouting.action(findBarVisible: true, mode: .read) == .dismissFind)
        #expect(EscRouting.action(findBarVisible: true, mode: .split) == .dismissFind)
    }

    @Test func withoutFindBarSinglePaneWriteSwitchesToPreview() {
        #expect(EscRouting.action(findBarVisible: false, mode: .write) == .switchToPreview)
    }

    @Test func withoutFindBarReadAndSplitIgnoreEsc() {
        #expect(EscRouting.action(findBarVisible: false, mode: .read) == .none)
        #expect(EscRouting.action(findBarVisible: false, mode: .split) == .none)
    }
}
