import AppKit
import SwiftUI

/// A native boundary identifies the pane without replacing SwiftUI's text
/// fields, input-method handling, bindings, or focus behavior.
struct NativeFindBar<Bar: View>: NSViewControllerRepresentable {
    let pane: SplitPane
    let bar: Bar

    init(pane: SplitPane, @ViewBuilder content: () -> Bar) {
        self.pane = pane
        self.bar = content()
    }

    func makeNSViewController(context: Context) -> NativeFindBarController<Bar> {
        let controller = NativeFindBarController(rootView: bar)
        controller.findPane = pane
        return controller
    }

    func updateNSViewController(_ controller: NativeFindBarController<Bar>, context: Context) {
        controller.findPane = pane
        controller.rootView = bar
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsViewController controller: NativeFindBarController<Bar>, context: Context) -> CGSize? {
        controller.barSize(for: proposal.width)
    }
}

@MainActor
protocol NativeFindPaneOwner: AnyObject {
    var findPane: SplitPane { get }
}

final class NativeFindBarController<Bar: View>: NSHostingController<Bar>, NativeFindPaneOwner {
    var findPane: SplitPane = .editor

    func barSize(for proposedWidth: CGFloat?) -> CGSize {
        // A missing/infinite proposal asks for an ideal size, not an infinite
        // view. Use the existing narrow editor width for that measurement;
        // real finite widths pass through, and SwiftUI measures every row.
        let width = proposedWidth.flatMap { $0.isFinite ? $0 : nil }
            ?? DocumentLayoutMetrics.splitEditorMinWidth
        let measured = sizeThatFits(in: CGSize(width: width, height: .infinity))
        return CGSize(width: width, height: measured.height)
    }
}

enum NativeFindFocus {
    /// Read the active control at command dispatch time, before a delayed
    /// SwiftUI onEditingChanged notification or scroll report can misroute it.
    @MainActor static func pane(in window: NSWindow?) -> SplitPane? {
        guard let window, let responder = window.firstResponder, let root = window.contentView else { return nil }
        var pending = [root]
        while let view = pending.popLast() {
            if let field = view as? NSTextField, field.window === window,
               field === responder || field.currentEditor() === responder {
                // NSViewController participates in its view's responder chain;
                // the explicit bar controller supplies identity, not a private
                // SwiftUI view class, a label, or the control's screen position.
                var ancestor: NSResponder? = field
                while let current = ancestor, current !== window {
                    if let owner = current as? NativeFindPaneOwner { return owner.findPane }
                    ancestor = current.nextResponder
                }
            }
            pending.append(contentsOf: view.subviews)
        }
        return nil
    }
}
