import Combine

/// The document bar and Files header share the current folder permission.
@MainActor
final class FolderRemoteImages: ObservableObject {
    enum Action {
        case allow
        case revoke

        init(isAllowed: Bool) {
            self = isAllowed ? .revoke : .allow
        }

        var title: L10nKey {
            self == .allow ? .remoteImagesFolderAllow : .remoteImagesFolderRevoke
        }

        var identifier: String {
            self == .allow ? "remote-images-folder-allow" : "remote-images-folder-revoke"
        }
    }

    let rootPath: String
    let canRememberPermission: Bool
    @Published var isAllowed: Bool
    @Published var isFavorite: Bool
    var onPermissionChange: (Bool) -> Void = { _ in }

    init(rootPath: String, isAllowed: Bool, isFavorite: Bool, canRememberPermission: Bool = true) {
        self.rootPath = rootPath
        self.isAllowed = isAllowed
        self.isFavorite = isFavorite
        self.canRememberPermission = canRememberPermission
    }

    var action: Action { Action(isAllowed: isAllowed) }

    var persistenceDescription: L10nKey {
        if isFavorite { return .remoteImagesFolderFavorite }
        return canRememberPermission ? .remoteImagesFolderCanFavorite : .remoteImagesFolderSession
    }
}
