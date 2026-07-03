import AppKit

/// Records and lists recently opened/saved documents in a UserDefaults-backed
/// list the app owns. The system recents service is deliberately not used:
/// macOS refuses its persistence for unsigned/ad-hoc builds (how this app is
/// distributed), and in-session noting would duplicate the app's own Dock
/// recents section. The system "Recent items" count preference is still
/// respected via `NSDocumentController.maximumRecentDocumentCount`. Injectable
/// so ordering/pruning logic is testable against a fake.
@MainActor
protocol RecentDocumentsRecording: AnyObject {
    /// Adds `url` to the list (or moves it to the front).
    func note(_ url: URL)
    /// Most recent first.
    var recentDocumentURLs: [URL] { get }
    /// Empties the list.
    func clear()
}

@MainActor
final class SystemRecentDocumentsRecorder: RecentDocumentsRecording {
    private static let defaultsKey = "MD2.RecentDocuments"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func note(_ url: URL) {
        let path = url.standardizedFileURL.path
        var paths = storedPaths.filter { $0 != path }
        paths.insert(path, at: 0)
        let cap = max(1, NSDocumentController.shared.maximumRecentDocumentCount)
        if paths.count > cap {
            paths = Array(paths.prefix(cap))
        }
        defaults.set(paths, forKey: Self.defaultsKey)
    }

    var recentDocumentURLs: [URL] {
        storedPaths.map { URL(fileURLWithPath: $0) }
    }

    func clear() {
        defaults.removeObject(forKey: Self.defaultsKey)
    }

    private var storedPaths: [String] {
        defaults.stringArray(forKey: Self.defaultsKey) ?? []
    }
}

struct RecentDocumentEntry: Equatable {
    let title: String
    let url: URL
}

enum RecentDocumentsList {
    /// The Open Recent menu model for a recorder's URL list: deduplicated by
    /// standardized path (most recent occurrence wins), titled by file display
    /// name, and — only where names collide — disambiguated with the parent
    /// folder as "name — folder".
    static func menuEntries(for urls: [URL]) -> [RecentDocumentEntry] {
        var seenPaths = Set<String>()
        var deduped: [URL] = []
        for url in urls {
            let path = url.standardizedFileURL.path
            guard !seenPaths.contains(path) else { continue }
            seenPaths.insert(path)
            deduped.append(url)
        }

        var nameCounts: [String: Int] = [:]
        for url in deduped {
            nameCounts[url.lastPathComponent, default: 0] += 1
        }

        return deduped.map { url in
            let name = url.lastPathComponent
            let title = (nameCounts[name] ?? 0) > 1
                ? "\(name) — \(url.deletingLastPathComponent().lastPathComponent)"
                : name
            return RecentDocumentEntry(title: title, url: url)
        }
    }

    /// Rebuilds the recorder's list without `url`, preserving the order of the
    /// remaining entries.
    @MainActor
    static func removeEntry(_ url: URL, from recorder: RecentDocumentsRecording) {
        let removedPath = url.standardizedFileURL.path
        let remaining = recorder.recentDocumentURLs.filter {
            $0.standardizedFileURL.path != removedPath
        }
        recorder.clear()
        for entry in remaining.reversed() {
            recorder.note(entry)
        }
    }
}
