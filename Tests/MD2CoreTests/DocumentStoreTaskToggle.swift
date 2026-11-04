@testable import MD2App

extension DocumentStore {
    /// A checkbox click from a preview that is up to date with the text.
    @discardableResult
    func toggleTask(atLine line: Int, to checked: Bool) -> Bool {
        toggleTask(atLine: line, to: checked, renderedAt: sourceLineRevision)
    }
}
