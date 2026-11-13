import MD2Core
import SwiftUI

/// Native, discoverable session control. Permission never comes from the rendered
/// page and button actions do not edit the source or commandeer editor focus.
struct RemoteResourceNotice: View {
    @ObservedObject var document: DocumentStore
    @ObservedObject var settings: AppSettings
    var setImagesAllowed: (Bool) -> Void
    @State private var showsPermissionExplanation = false

    private var allowsImages: Bool { document.remoteResourcePolicy == .allowRemoteImages }
    private var status: String { settings.text(allowsImages ? .remoteImagesAllowed : .remoteImagesBlocked) }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            noticeRow(compact: false)
            noticeRow(compact: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(settings.text(.remoteImages))
        .accessibilityValue(status)
        .popover(isPresented: $showsPermissionExplanation, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 14) {
                Text(settings.text(.remoteImages)).font(.headline)
                Text(settings.text(.remoteImagesExplanation))
                Text(settings.text(.remoteImagesPrivacy))
                HStack {
                    Button(settings.text(.cancel)) { showsPermissionExplanation = false }
                    Spacer()
                    Button(settings.text(.remoteImagesAllowConfirm)) {
                        showsPermissionExplanation = false
                        setImagesAllowed(true)
                    }
                    .accessibilityIdentifier("remote-images-confirm")
                }
            }
            .padding(18)
            .frame(width: 330)
        }
        .onChange(of: document.remoteResourceContextToken) { _, _ in
            showsPermissionExplanation = false
        }
    }

    private func noticeRow(compact: Bool) -> some View {
        HStack(spacing: 10) {
            Label(compact ? settings.text(.remoteImages) : status,
                  systemImage: allowsImages ? "network" : "network.slash")
                .font(.callout)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel(status)
            Spacer(minLength: 8)
            if allowsImages {
                Button(settings.text(.remoteImagesRevoke)) {
                    setImagesAllowed(false)
                }
                .accessibilityIdentifier("remote-images-revoke")
                .help(settings.text(.remoteImagesAllowedExplanation))
                .fixedSize()
            } else {
                Button(settings.text(.remoteImagesAllow)) { showsPermissionExplanation = true }
                    .accessibilityIdentifier("remote-images-allow")
                    .fixedSize()
            }
        }
    }
}
