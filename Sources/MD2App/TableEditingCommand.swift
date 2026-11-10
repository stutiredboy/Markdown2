import SwiftUI

/// Observe the current-document boundary directly. A settings-only Commands
/// tree does not refresh when the first document opens or Settings becomes key.
struct TableEditingCommand: View {
    let title: String
    @ObservedObject var state: AttachmentCommandState
    let action: () -> Void

    var body: some View {
        Button(title, action: action).disabled(state.document == nil)
    }
}
