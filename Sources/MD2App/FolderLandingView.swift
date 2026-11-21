import AppKit
import SwiftUI

struct FolderLandingView: View {
    let sidebar: FolderSidebarState
    @ObservedObject var settings: AppSettings

    var body: some View {
        HStack(spacing: 0) {
            FolderSidebarHost(sidebar: sidebar)
                .frame(width: DocumentLayoutMetrics.outlineSidebarWidth)
                .frame(maxHeight: .infinity)
                .background(.regularMaterial)

            Divider()

            Text(settings.text(.folderLandingPrompt))
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
                .accessibilityIdentifier("folder-landing-prompt")
        }
        .frame(minWidth: DocumentLayoutMetrics.nonSplitMinWidth, minHeight: 540)
    }
}
