import AppKit
import MD2Core
import SwiftUI

/// Native, discoverable session control. Permission comes only from the owning
/// document window, and changing it does not edit the source.
struct RemoteResourceNotice: View {
    @ObservedObject var document: DocumentStore
    @ObservedObject var settings: AppSettings
    var setImagesAllowed: (Bool) -> Void
    @State private var permissionPrompt = PermissionPrompt()

    private var allowsImages: Bool { document.remoteResourcePolicy == .allowRemoteImages }
    private var status: String { settings.text(allowsImages ? .remoteImagesAllowed : .remoteImagesBlocked) }

    var body: some View {
        HStack(spacing: 10) {
            ViewThatFits(in: .horizontal) {
                noticeLabel(status)
                noticeLabel(settings.text(.remoteImages))
            }
            Spacer(minLength: 8)
            // Keep the same control after allow/revoke so the window can
            // restore its previous keyboard focus when the sheet closes.
            Button(settings.text(allowsImages ? .remoteImagesRevoke : .remoteImagesAllow)) {
                if allowsImages { setImagesAllowed(false) }
                else { requestPermission() }
            }
            .accessibilityIdentifier(allowsImages ? "remote-images-revoke" : "remote-images-allow")
            .help(allowsImages ? settings.text(.remoteImagesAllowedExplanation) : "")
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
        .background(PermissionAnchor(prompt: permissionPrompt).accessibilityHidden(true))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(settings.text(.remoteImages))
        .accessibilityValue(status)
        .onChange(of: document.remoteResourceContextToken) { _, _ in
            permissionPrompt.dismiss()
        }
        .onDisappear { permissionPrompt.dismiss() }
    }

    private func noticeLabel(_ title: String) -> some View {
        Label(title, systemImage: allowsImages ? "network" : "network.slash")
            .font(.callout)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel(status)
    }

    private func requestPermission() {
        let context = document.remoteResourceContextToken
        permissionPrompt.present(settings: settings) {
            // A reload or replacement can complete before the sheet's
            // dismissal callback. Never apply the old consent to new content.
            guard document.remoteResourceContextToken == context else { return }
            setImagesAllowed(true)
        }
    }
}

/// Tie the confirmation to the view's document even when another window has
/// become key between the user action and presentation.
private struct PermissionAnchor: NSViewRepresentable {
    let prompt: PermissionPrompt

    func makeNSView(context: Context) -> NSView {
        let anchor = NSView()
        prompt.anchor = anchor
        return anchor
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

@MainActor
private final class PermissionPrompt {
    weak var anchor: NSView?
    private var alert: NSAlert?

    func present(settings: AppSettings, onConfirm: @escaping () -> Void) {
        guard alert == nil, let window = anchor?.window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = settings.text(.remoteImages)
        alert.informativeText = settings.text(.remoteImagesExplanation) + "\n\n" + settings.text(.remoteImagesPrivacy)
        let cancel = alert.addButton(withTitle: settings.text(.cancel))
        cancel.setAccessibilityIdentifier("remote-images-cancel")
        let confirm = alert.addButton(withTitle: settings.text(.remoteImagesAllowConfirm))
        confirm.setAccessibilityIdentifier("remote-images-confirm")
        confirm.keyEquivalent = ""
        alert.window.initialFirstResponder = cancel

        self.alert = alert
        alert.beginSheetModal(for: window) { [weak self, weak alert] response in
            guard let self, let alert, self.alert === alert else { return }
            self.alert = nil
            if response == .alertSecondButtonReturn { onConfirm() }
        }
    }

    func dismiss() {
        guard let alert else { return }
        self.alert = nil
        let sheet = alert.window
        sheet.sheetParent?.endSheet(sheet, returnCode: .cancel)
    }
}
