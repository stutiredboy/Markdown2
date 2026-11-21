import AppKit
import Combine
import MD2Core
import SwiftUI

struct RemoteImagePermissionIcon {
    let isAllowed: Bool

    var symbolName: String { isAllowed ? "network" : "network.slash" }
    var tint: NSColor { isAllowed ? .systemGreen : .systemGray }
}

/// Displays effective remote-image permission and the available native controls.
struct RemoteResourceNotice: View {
    @ObservedObject var document: DocumentStore
    @ObservedObject var settings: AppSettings
    @ObservedObject var contentState: DocumentWindowContentState
    var preservePreviewPosition: () -> Void
    @State private var sheet = RemoteResourceSheet()

    private var allowsImages: Bool { document.remoteResourcePolicy == .allowRemoteImages }
    private var folder: FolderRemoteImages? { contentState.folderRemoteImages }

    private var status: String {
        guard folder != nil else {
            return settings.text(allowsImages ? .remoteImagesAllowed : .remoteImagesBlocked)
        }
        return switch document.remoteImageOverride {
        case .allow: settings.text(.remoteImagesAllowedByDocument)
        case .block: settings.text(.remoteImagesBlockedByDocument)
        case .inherit: settings.text(allowsImages ? .remoteImagesAllowedByFolder : .remoteImagesBlocked)
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            ViewThatFits(in: .horizontal) {
                if let folder, allowsImages, document.remoteImageOverride == .inherit {
                    let name = (folder.rootPath as NSString).lastPathComponent
                    noticeLabel("\(status) · \(name)").help(folder.rootPath)
                }
                noticeLabel(status)
                noticeLabel(settings.text(.remoteImages))
            }
            Spacer(minLength: 8)
            if let folder {
                folderPermissions(folder)
            } else {
                // Keep the same control after allow/revoke so the window can
                // restore its previous keyboard focus when the sheet closes.
                Button(settings.text(allowsImages ? .remoteImagesRevoke : .remoteImagesAllow)) {
                    if allowsImages {
                        preservePreviewPosition()
                        document.setRemoteImagesAllowed(false)
                    } else {
                        requestDocumentPermission()
                    }
                }
                .accessibilityIdentifier(allowsImages ? "remote-images-revoke" : "remote-images-allow")
                .help(allowsImages ? settings.text(.remoteImagesAllowedExplanation) : "")
                .fixedSize()
            }
            Button(settings.text(.remoteImagesDetails)) { showDetails() }
                .accessibilityIdentifier("remote-images-details")
                .accessibilityLabel(settings.text(.remoteImagesDetailsTitle))
                .disabled(!document.canInspectRemoteResources)
                .help(document.canInspectRemoteResources ? "" : settings.text(.remoteImagesPreparing))
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
        .background(RemoteResourceAnchor(sheet: sheet).accessibilityHidden(true))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(settings.text(.remoteImages))
        .accessibilityValue(status)
        .onReceive(document.$remoteResourceContextToken.dropFirst()) { _ in
            sheet.dismissDetails()
        }
        .onChange(of: document.remoteResourceContextToken) { _, _ in
            sheet.dismiss()
        }
        .onChange(of: folder.map(ObjectIdentifier.init)) { _, _ in sheet.dismiss() }
        .onChange(of: status) { _, _ in sheet.dismissDetails() }
        .onChange(of: document.sourceLineRevision) { _, _ in sheet.dismissDetails() }
        .onChange(of: document.canInspectRemoteResources) { _, available in
            if !available { sheet.dismissDetails() }
        }
        .onChange(of: settings.effectiveLanguage) { _, _ in sheet.dismissDetails() }
        .onDisappear { sheet.dismiss() }
    }

    private func folderPermissions(_ folder: FolderRemoteImages) -> some View {
        let action = folder.action
        return Menu(settings.text(.remoteImagesPermissions)) {
            if document.remoteImageOverride != .allow {
                Button(settings.text(.remoteImagesAllow)) { requestDocumentPermission() }
                    .accessibilityIdentifier("remote-images-allow")
            }
            if allowsImages {
                Button(settings.text(.remoteImagesBlockDocument)) {
                    guard contentState.folderRemoteImages === folder else { return }
                    preservePreviewPosition()
                    document.setRemoteImageOverride(.block)
                }
                .accessibilityIdentifier("remote-images-block-document")
            }
            if document.remoteImageOverride != .inherit {
                Button(settings.text(.remoteImagesUseFolderPermission)) {
                    guard contentState.folderRemoteImages === folder else { return }
                    if allowsImages != folder.isAllowed { preservePreviewPosition() }
                    document.setRemoteImageOverride(.inherit)
                }
                .accessibilityIdentifier("remote-images-restore-inheritance")
            }
            Divider()
            Button(settings.text(action.title)) {
                guard contentState.folderRemoteImages === folder, folder.action == action else { return }
                switch action {
                case .revoke:
                    if document.remoteImageOverride == .inherit, allowsImages { preservePreviewPosition() }
                    folder.onPermissionChange(false)
                case .allow:
                    requestFolderPermission(folder)
                }
            }
            .accessibilityIdentifier(action.identifier)
        }
        .accessibilityIdentifier("remote-images-permissions")
        .help(folder.rootPath)
        .fixedSize()
    }

    private func noticeLabel(_ title: String) -> some View {
        let icon = RemoteImagePermissionIcon(isAllowed: allowsImages)
        return Label {
            Text(title)
        } icon: {
            Image(systemName: icon.symbolName)
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(Color(nsColor: icon.tint))
                .accessibilityHidden(true)
        }
        .font(.callout)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel(status)
        .accessibilityIdentifier("remote-images-status")
    }

    private func requestDocumentPermission() {
        let context = document.remoteResourceContextToken
        let folder = folder
        sheet.presentPermission(settings: settings) {
            // A reload or replacement can complete before the sheet's
            // dismissal callback. Never apply the old consent to new content.
            guard document.remoteResourceContextToken == context,
                  contentState.folderRemoteImages === folder else { return }
            if !allowsImages { preservePreviewPosition() }
            if folder == nil { document.setRemoteImagesAllowed(true) }
            else { document.setRemoteImageOverride(.allow) }
        }
    }

    private func requestFolderPermission(_ folder: FolderRemoteImages) {
        let context = document.remoteResourceContextToken
        sheet.presentFolderPermission(folder, text: settings.text) {
            guard document.remoteResourceContextToken == context,
                  contentState.folderRemoteImages === folder else { return false }
            if document.remoteImageOverride == .inherit, !allowsImages { preservePreviewPosition() }
            return true
        }
    }

    private func showDetails() {
        guard document.canInspectRemoteResources else { return }
        let context = document.remoteResourceContextToken
        let revision = document.sourceLineRevision
        // Return from the button's AX action before laying out the AppKit sheet.
        DispatchQueue.main.async {
            guard document.canInspectRemoteResources, document.remoteResourceContextToken == context,
                  document.sourceLineRevision == revision else { return }
            sheet.presentDetails(settings: settings, status: status) {
                let report = await document.inspectRemoteResources()
                guard document.remoteResourceContextToken == context, document.sourceLineRevision == revision else { return nil }
                return report
            }
        }
    }
}

/// Tie the sheets to the view's document even when another window has
/// become key between the user action and presentation.
private struct RemoteResourceAnchor: NSViewRepresentable {
    let sheet: RemoteResourceSheet

    func makeNSView(context: Context) -> NSView {
        let anchor = NSView()
        sheet.anchor = anchor
        return anchor
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

@MainActor
final class RemoteResourceSheet {
    weak var anchor: NSView?
    private var alert: NSAlert?
    private weak var detailsTextView: NSTextView?
    private var inspection: Task<Void, Never>?

    func presentPermission(settings: AppSettings, onConfirm: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = settings.text(.remoteImages)
        alert.informativeText = settings.text(.remoteImagesExplanation) + "\n\n" + settings.text(.remoteImagesPrivacy)
        configurePermissionActions(alert, text: settings.text, identifier: "remote-images")

        present(alert) { response in
            if response == .alertSecondButtonReturn { onConfirm() }
        }
    }

    func presentFolderPermission(
        _ folder: FolderRemoteImages, text: (L10nKey) -> String, isCurrent: @escaping () -> Bool
    ) {
        let isFavorite = folder.isFavorite
        let alert = NSAlert()
        alert.messageText = text(.remoteImagesFolderConfirmTitle)
        alert.informativeText = [
            folder.rootPath,
            text(.remoteImagesFolderExplanation),
            text(folder.persistenceDescription),
            text(.remoteImagesPrivacy)
        ].joined(separator: "\n\n")
        configurePermissionActions(alert, text: text, identifier: "folder-remote-images")

        present(alert) { [weak folder] response in
            guard response == .alertSecondButtonReturn, let folder, !folder.isAllowed,
                  folder.isFavorite == isFavorite, isCurrent() else { return }
            folder.onPermissionChange(true)
        }
    }

    private func configurePermissionActions(_ alert: NSAlert, text: (L10nKey) -> String, identifier: String) {
        let cancel = alert.addButton(withTitle: text(.cancel))
        cancel.setAccessibilityIdentifier("\(identifier)-cancel")
        let confirm = alert.addButton(withTitle: text(.remoteImagesAllowConfirm))
        confirm.setAccessibilityIdentifier("\(identifier)-confirm")
        confirm.keyEquivalent = ""
        alert.window.initialFirstResponder = cancel
    }

    func presentDetails(settings: AppSettings, status: String, inspect: @escaping @MainActor () async -> RemoteResourceReport?) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = settings.text(.remoteImagesDetailsTitle)
        alert.informativeText = [status, settings.text(.remoteImagesDetailsScope),
                                 settings.text(.remoteImagesDetailsOtherBlocked), settings.text(.remoteImagesDetailsUnknown)]
            .joined(separator: "\n\n")
        let close = alert.addButton(withTitle: settings.text(.close))
        close.setAccessibilityIdentifier("remote-images-details-close")
        close.keyEquivalent = "\u{1b}"

        let scroll = NSTextView.scrollableTextView()
        guard let origins = scroll.documentView as? NSTextView else { return }
        scroll.frame.size = NSSize(width: 460, height: 160)
        scroll.borderType = .bezelBorder
        origins.font = .systemFont(ofSize: NSFont.systemFontSize)
        origins.textContainerInset = NSSize(width: 8, height: 8)
        origins.isEditable = false
        origins.isSelectable = true
        origins.isRichText = false
        origins.isAutomaticLinkDetectionEnabled = false
        origins.isAutomaticDataDetectionEnabled = false
        origins.setAccessibilityIdentifier("remote-images-origins")
        origins.setAccessibilityLabel(settings.text(.remoteImagesOrigins))
        origins.string = settings.text(.remoteImagesDetailsInspecting)
        alert.accessoryView = scroll
        alert.window.initialFirstResponder = close

        guard present(alert) else { return }
        detailsTextView = origins
        inspection = Task { [weak self, weak alert] in
            let report = await inspect()
            guard !Task.isCancelled, let self, let alert, self.alert === alert else { return }
            self.inspection = nil
            guard let report else {
                self.dismiss()
                return
            }
            var rows = report.origins.map {
                String(format: settings.text(.remoteImagesOriginCount), $0.displayName, Int64($0.referenceCount))
            }
            if rows.isEmpty, !report.isPartial { rows.append(settings.text(.remoteImagesNoReferences)) }
            if report.isPartial { rows.insert(settings.text(.remoteImagesDetailsPartial) + "\n", at: 0) }
            origins.string = rows.joined(separator: "\n")
        }
    }

    @discardableResult
    private func present(_ alert: NSAlert, onDismiss: @escaping (NSApplication.ModalResponse) -> Void = { _ in }) -> Bool {
        guard self.alert == nil, let window = anchor?.window, window.attachedSheet == nil else { return false }
        self.alert = alert
        alert.beginSheetModal(for: window) { [weak self, weak alert] response in
            guard let self, let alert, self.alert === alert else { return }
            self.clear()
            onDismiss(response)
        }
        return true
    }

    func dismissDetails() {
        if detailsTextView != nil { dismiss() }
    }

    func dismiss() {
        guard let alert else { return }
        clear()
        let sheet = alert.window
        sheet.sheetParent?.endSheet(sheet, returnCode: .cancel)
    }

    private func clear() {
        alert = nil
        inspection?.cancel()
        inspection = nil
        // AppKit can keep the sheet visible during its dismissal animation.
        detailsTextView?.string = ""
        detailsTextView = nil
    }
}
