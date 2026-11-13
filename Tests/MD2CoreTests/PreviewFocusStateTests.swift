import Foundation
import Testing
@testable import MD2App

@MainActor
struct PreviewFocusStateTests {
    @Test func aConsumedRequestDoesNotBecomeNewWhenAHostIsReplaced() {
        let state = PreviewFocusState()
        let oldHostRequest = UUID()
        #expect(state.consume(oldHostRequest))
        #expect(!state.consume(oldHostRequest))
        let explicitRequest = UUID()
        #expect(state.consume(explicitRequest))
        #expect(state.lastConsumedToken == explicitRequest)
        #expect(!state.consume(explicitRequest))
    }

    @Test func twoDocumentViewsDoNotShareConsumedFocusRequests() {
        let first = PreviewFocusState(), second = PreviewFocusState()
        let token = UUID()
        #expect(first.consume(token))
        #expect(second.consume(token))
        #expect(!first.hasPendingRestoration)
        #expect(!second.hasPendingRestoration)
    }
}
