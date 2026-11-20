import Combine
import Foundation

@MainActor
protocol FavoriteFoldersRecording: AnyObject {
    var favoriteFolderPaths: [String] { get set }
}

@MainActor
final class UserDefaultsFavoriteFoldersRecorder: FavoriteFoldersRecording {
    private static let defaultsKey = "MD2.FavoriteFolders"
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
        recorder.favoriteFolderPaths = paths
        let updated = Self.menuEntries(for: paths)
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
