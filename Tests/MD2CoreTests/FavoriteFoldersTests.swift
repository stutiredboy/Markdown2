import Combine
import Darwin
import Foundation
import Testing
@testable import MD2App

@MainActor
private final class InMemoryFavoriteFoldersRecorder: FavoriteFoldersRecording {
    var favoriteFolderPaths: [String] = []
}

@MainActor
struct FavoriteFoldersTests {
    @Test func authorizedFoldersKeepInsertionOrderAndDeduplicateCanonicalPaths() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstURL = try makeFolder("first/Research", in: directory)
        let secondURL = try makeFolder("second/Research", in: directory)
        let thirdURL = try makeFolder("研发 100%?#", in: directory)
        let first = try FolderIndex.authorize(firstURL)
        let second = try FolderIndex.authorize(secondURL)
        let third = try FolderIndex.authorize(thirdURL)
        let link = directory.appending(path: "linked-parent", directoryHint: .isDirectory)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: firstURL.deletingLastPathComponent())
        let equivalent = try FolderIndex.authorize(link.appending(path: "Research", directoryHint: .isDirectory))

        let recorder = InMemoryFavoriteFoldersRecorder()
        let model = FavoriteFoldersModel(recorder: recorder)
        var changes = 0
        let subscription = model.objectWillChange.sink { changes += 1 }
        defer { subscription.cancel() }
        model.add(first)
        model.add(second)
        model.add(third)
        model.add(equivalent)

        #expect(model.contains(equivalent))
        #expect(model.entries.map(\.title) == ["Research — first", "Research — second", "研发 100%?#"])
        #expect(model.entries.map(\.url) == [first.url, second.url, third.url])
        #expect(recorder.favoriteFolderPaths == [first.url.path, second.url.path, third.url.path])
        #expect(changes == 3)

        model.remove(second)
        #expect(!model.contains(second))
        #expect(model.entries.map(\.title) == ["Research", "研发 100%?#"])
        let storedFirst = try #require(model.entries.first)
        try FileManager.default.removeItem(at: firstURL)
        model.remove(storedFirst)
        #expect(model.entries.map(\.url) == [third.url])
        #expect(recorder.favoriteFolderPaths == [third.url.path])

        model.clear()
        #expect(model.entries.isEmpty)
        #expect(recorder.favoriteFolderPaths.isEmpty)
        #expect(changes == 6)
    }

    @Test func defaultsRestoreOfflineFoldersAndClearInAnIsolatedSuite() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let name = "\u{301}Caf\u{e9}\n100%2F?#"
        let path = directory.path + "/" + name
        let folder = try #require(FolderIndex.canonicalDirectoryURL(for: path))
        try #require(mkdir(path, 0o700) == 0)
        defer { _ = rmdir(path) }
        let canonical = try #require(realpath(path, nil))
        defer { free(canonical) }
        let canonicalPath = String(cString: canonical)
        let root = try FolderIndex.authorize(folder)
        #expect(root.url.path.utf8.elementsEqual(canonicalPath.utf8))
        #expect(try FolderIndex.authorizeFavorite(root.url) == root)
        let suite = "md2-favorite-folders-tests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let model = FavoriteFoldersModel(recorder: UserDefaultsFavoriteFoldersRecorder(defaults: defaults))
        model.currentRoot = root
        model.add(root)
        try #require(rmdir(path) == 0)

        let freshDefaults = try #require(UserDefaults(suiteName: suite))
        let restored = FavoriteFoldersModel(recorder: UserDefaultsFavoriteFoldersRecorder(defaults: freshDefaults))
        #expect(restored.entries.map(\.url) == [root.url])
        let entry = try #require(restored.entries.first)
        #expect(entry.path.utf8.elementsEqual(canonicalPath.utf8))
        #expect(entry.title.utf8.elementsEqual((canonicalPath as NSString).lastPathComponent.utf8))
        #expect(restored.currentRoot == nil)
        restored.clear()
        #expect(UserDefaultsFavoriteFoldersRecorder(defaults: defaults).favoriteFolderPaths.isEmpty)
    }

    @Test func menuRejectsMalformedPathsAndDisambiguatesMatchingParentNames() {
        let recorder = InMemoryFavoriteFoldersRecorder()
        recorder.favoriteFolderPaths = [
            "/", "relative", "/first/../second", "/first//second", "/invalid\u{0}path",
            "/a/shared/Notes", "/b/shared/Notes", "/a/shared/Notes", "/\u{301}leading"
        ]
        let model = FavoriteFoldersModel(recorder: recorder)
        #expect(model.entries.map(\.path) == ["/", "/a/shared/Notes", "/b/shared/Notes", "/\u{301}leading"])
        #expect(model.entries.map(\.title) == ["/", "Notes — /a/shared", "Notes — /b/shared", "\u{301}leading"])
    }

    @Test func byteDistinctPathsStaySeparateForVolumesThatDistinguishUnicodeForms() throws {
        let recorder = InMemoryFavoriteFoldersRecorder()
        let composed = "/saved/Caf\u{e9}"
        let decomposed = "/saved/Cafe\u{301}"
        recorder.favoriteFolderPaths = [composed, decomposed]
        let model = FavoriteFoldersModel(recorder: recorder)

        #expect(Set(model.entries.map(\.id)).count == 2)
        model.remove(try #require(model.entries.first))
        let remaining = try #require(model.entries.first)
        #expect(remaining.path.utf8.elementsEqual(decomposed.utf8))
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "md2-favorites-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private func makeFolder(_ name: String, in directory: URL) throws -> URL {
        let folder = directory.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}
