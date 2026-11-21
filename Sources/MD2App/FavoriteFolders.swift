import Combine
import Foundation

@MainActor
protocol FavoriteFoldersRecording: AnyObject {
    var favoriteFolderPaths: [String] { get set }
    var remoteImageGrantIDs: [String: String] { get set }
}

@MainActor
final class UserDefaultsFavoriteFoldersRecorder: FavoriteFoldersRecording {
    private static let defaultsKey = "MD2.FavoriteFolders"
    private static let remoteImagesKey = "MD2.FavoriteFolders.RemoteImageGrants"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var favoriteFolderPaths: [String] {
        get { defaults.stringArray(forKey: Self.defaultsKey) ?? [] }
        set {
            if newValue.isEmpty {
                defaults.removeObject(forKey: Self.defaultsKey)
            } else {
                defaults.set(newValue, forKey: Self.defaultsKey)
            }
        }
    }

    var remoteImageGrantIDs: [String: String] {
        get { defaults.dictionary(forKey: Self.remoteImagesKey) as? [String: String] ?? [:] }
        set {
            if newValue.isEmpty { defaults.removeObject(forKey: Self.remoteImagesKey) }
            else { defaults.set(newValue, forKey: Self.remoteImagesKey) }
        }
    }
}

struct FavoriteFolderEntry: Equatable, Identifiable, Sendable {
    let url: URL
    let title: String

    var id: String { url.absoluteString }
    var path: String { url.path }
}

/// Each addition takes an authorized root. Presentation and removal also work
/// for offline folders because neither operation needs filesystem access.
@MainActor
final class FavoriteFoldersModel: ObservableObject {
    @Published private(set) var entries: [FavoriteFolderEntry]
    @Published var currentRoot: FolderIndex.Root?
    private let recorder: FavoriteFoldersRecording

    init(recorder: FavoriteFoldersRecording) {
        self.recorder = recorder
        entries = Self.menuEntries(for: recorder.favoriteFolderPaths)
    }

    func contains(_ root: FolderIndex.Root) -> Bool {
        entries.contains { $0.url == root.url }
    }

    func allowsRemoteImages(in root: FolderIndex.Root) -> Bool {
        guard contains(root), let grantID = root.favoriteRemoteImageGrantID,
              recorder.remoteImageGrantIDs[root.url.absoluteString] == grantID else { return false }
        return FolderIndex.isCurrent(root)
    }

    /// Returns false when approval cannot be stored for this favorite. The
    /// caller can still keep a grant in memory for the current folder session.
    @discardableResult
    func setRemoteImagesAllowed(_ allowed: Bool, in root: FolderIndex.Root) -> Bool {
        var grants = recorder.remoteImageGrantIDs
        let key = root.url.absoluteString
        if allowed {
            guard contains(root), let grantID = root.favoriteRemoteImageGrantID,
                  FolderIndex.isCurrent(root) else { return false }
            grants[key] = grantID
        } else {
            grants.removeValue(forKey: key)
        }
        recorder.remoteImageGrantIDs = grants
        return true
    }

    func add(_ root: FolderIndex.Root) {
        guard !contains(root) else { return }
        update(entries.map(\.path) + [root.url.path])
    }

    func remove(_ root: FolderIndex.Root) {
        remove(url: root.url)
    }

    func remove(_ entry: FavoriteFolderEntry) {
        remove(url: entry.url)
    }

    func clear() {
        update([])
    }

    private func remove(url: URL) {
        update(entries.filter { $0.url != url }.map(\.path))
    }

    private func update(_ paths: [String]) {
        let updated = Self.menuEntries(for: paths)
        let favorites = Set(entries.map(\.id)).intersection(updated.map(\.id))
        let grants = recorder.remoteImageGrantIDs
        let retained = grants.filter { favorites.contains($0.key) }
        if retained != grants { recorder.remoteImageGrantIDs = retained }
        recorder.favoriteFolderPaths = paths
        if entries != updated { entries = updated }
    }

    private static func menuEntries(for paths: [String]) -> [FavoriteFolderEntry] {
        var seen = Set<URL>()
        let folders = paths.compactMap { path -> URL? in
            guard let url = FolderIndex.canonicalDirectoryURL(for: path), seen.insert(url).inserted else { return nil }
            return url
        }
        let nameCounts = Dictionary(grouping: folders, by: \.lastPathComponent)
        let entries = folders.map { url in
            let name = url.lastPathComponent
            let parent = url.deletingLastPathComponent().lastPathComponent
            let title = nameCounts[name, default: []].count > 1 ? "\(name) — \(parent)" : name
            return FavoriteFolderEntry(url: url, title: title)
        }
        let titleCounts = Dictionary(grouping: entries, by: \.title)
        return entries.map { entry in
            guard titleCounts[entry.title, default: []].count > 1 else { return entry }
            let url = entry.url
            return FavoriteFolderEntry(url: url, title: "\(url.lastPathComponent) — \(url.deletingLastPathComponent().path)")
        }
    }
}
