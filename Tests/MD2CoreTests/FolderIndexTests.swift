import Darwin
import Foundation
import Testing
@testable import MD2App

private struct FolderIndexFixture {
    let directory: URL
    let root: URL
    let outside: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "md2-folder-index-\(UUID())", directoryHint: .isDirectory)
            .resolvingSymlinksInPath()
        root = directory.appending(path: "root", directoryHint: .isDirectory)
        outside = directory.appending(path: "outside", directoryHint: .isDirectory)
        for folder in [root, outside] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    @discardableResult
    func file(_ path: String, under folder: URL? = nil, text: String = "# Test\n") throws -> URL {
        let url = (folder ?? root).appending(path: path, directoryHint: .notDirectory)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    func setFinderFlags(_ flags: UInt8, at url: URL) throws {
        var finderInfo = [UInt8](repeating: 0, count: 32)
        finderInfo[8] = flags
        let result = finderInfo.withUnsafeBytes {
            setxattr(url.path, "com.apple.FinderInfo", $0.baseAddress!, $0.count, 0, XATTR_NOFOLLOW)
        }
        guard result == 0 else { throw POSIXError(.EIO) }
    }
}

struct FolderIndexTests {
    @Test func treeAndQuickOpenShareOnlyEligibleMarkdownFiles() throws {
        let fixture = try FolderIndexFixture()
        defer { fixture.remove() }
        try fixture.file("Note 10.md")
        try fixture.file("Note 2.MD")
        let unusual = try fixture.file("Notes/中文 100%?#.MARKDOWN", text: "Literal path")
        try fixture.file(".ignored.md")
        try fixture.file(".git/ignored.md")
        try fixture.file("node_modules/ignored.md")
        try fixture.file("Workspace.xcodeproj/ignored.md")
        try fixture.file("App.app/Contents/ignored.md")
        try fixture.file("Notes/nested/.gitkeep")
        try fixture.file("text.txt")
        let invisible = try fixture.file("invisible.md")
        try fixture.setFinderFlags(0x40, at: invisible)
        let alias = try fixture.file("alias.md")
        try fixture.setFinderFlags(0x80, at: alias)
        let hiddenDirFile = try fixture.file("Hidden/ignored.md")
        #expect(chflags(hiddenDirFile.deletingLastPathComponent().path, UInt32(UF_HIDDEN)) == 0)
        let outside = try fixture.file("outside.md", under: fixture.outside)
        try FileManager.default.linkItem(at: outside, to: fixture.root.appending(path: "hardlink.md"))
        try FileManager.default.createSymbolicLink(at: fixture.root.appending(path: "internal.md"), withDestinationURL: unusual)
        try FileManager.default.createSymbolicLink(at: fixture.root.appending(path: "outside.md"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: fixture.root.appending(path: "cycle"), withDestinationURL: fixture.root)
        try FileManager.default.createSymbolicLink(at: fixture.root.appending(path: "outside-folder"), withDestinationURL: fixture.outside)
        #expect(mkfifo(fixture.root.appending(path: "socket.md").path, 0o600) == 0)

        let root = try FolderIndex.authorize(fixture.root)
        let snapshot = try FolderIndex.scan(root)
        #expect(snapshot.nodes.map(\.name) == ["Notes", "Note 2.MD", "Note 10.md"])
        #expect(snapshot.files.map(\.relativePath) == ["Notes/中文 100%?#.MARKDOWN", "Note 2.MD", "Note 10.md"])
        #expect(snapshot.nodes.first?.children?.map(\.name) == ["中文 100%?#.MARKDOWN"])
        #expect(!snapshot.isLimited && !snapshot.hasUnreadableItems)

        let selected = try #require(snapshot.files.first)
        let opened = try FolderIndex.open(selected, in: root)
        #expect(opened.url.resolvingSymlinksInPath() == unusual.resolvingSymlinksInPath())
        #expect(opened.url.query == nil && opened.url.fragment == nil)
        #expect(DocumentLinkTarget(opened.url).fileURL == opened.url)
        #expect(opened.data == Data("Literal path".utf8))
        #expect(opened.fingerprint.contentHash == DocumentFileFingerprint.hash(of: opened.data))
        try opened.validate()
    }

    @Test func exhaustedDepthEntryAndFileLimitsAreObservable() throws {
        let fixture = try FolderIndexFixture()
        defer { fixture.remove() }
        try fixture.file("one.md")
        try fixture.file("two.md")
        let root = try FolderIndex.authorize(fixture.root)

        let exactlyFits = try FolderIndex.scan(root, limits: .init(entries: 2, files: 2, depth: 0))
        #expect(exactlyFits.files.count == 2 && !exactlyFits.isLimited)
        let fileLimited = try FolderIndex.scan(root, limits: .init(entries: 20, files: 1, depth: 10))
        #expect(fileLimited.files.count == 1 && fileLimited.isLimited)

        try fixture.file("irrelevant.txt")
        let totalLimited = try FolderIndex.scan(root, limits: .init(entries: 2, files: 3, depth: 10))
        #expect(totalLimited.files.count <= 2 && totalLimited.isLimited)
        try fixture.file("level1/level2/note.md")
        let depthLimited = try FolderIndex.scan(root, limits: .init(entries: 20, files: 3, depth: 1))
        #expect(depthLimited.files.count == 2 && depthLimited.isLimited)
        let depthFits = try FolderIndex.scan(root, limits: .init(entries: 20, files: 3, depth: 2))
        #expect(depthFits.files.count == 3 && !depthFits.isLimited)
    }

    @Test func pathReplacementFailsClosedBeforeReadAndAgainAtAdoption() throws {
        let fixture = try FolderIndexFixture()
        defer { fixture.remove() }
        let real = try fixture.file("notes/test.md", text: "original")
        let victim = try fixture.file("test.md", under: fixture.outside, text: "outside")
        let root = try FolderIndex.authorize(fixture.root)
        let selected = try #require(FolderIndex.scan(root).files.first)
        let opened = try FolderIndex.open(selected, in: root)

        let parent = real.deletingLastPathComponent()
        let moved = fixture.root.appending(path: "renamed", directoryHint: .isDirectory)
        try FileManager.default.moveItem(at: parent, to: moved)
        try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: fixture.outside)
        #expect(throws: FolderIndex.Failure.fileUnavailable) { try FolderIndex.open(selected, in: root) }
        #expect(throws: FolderIndex.Failure.fileUnavailable) { try opened.validate() }
        #expect(try String(contentsOf: victim, encoding: .utf8) == "outside")
        #expect(try FolderIndex.scan(root).files.map(\.relativePath) == ["renamed/test.md"])

        let newFile = fixture.root.appending(path: "renamed/test.md")
        let fresh = try #require(FolderIndex.scan(root).files.first)
        let next = try FolderIndex.open(fresh, in: root)
        try Data("changed!".utf8).write(to: newFile)
        #expect(throws: FolderIndex.Failure.fileUnavailable) { try next.validate() }
        #expect(try FolderIndex.open(fresh, in: root).data == Data("changed!".utf8))

        try FileManager.default.linkItem(at: newFile, to: fixture.outside.appending(path: "hardlink.md"))
        #expect(throws: FolderIndex.Failure.fileUnavailable) { try FolderIndex.open(fresh, in: root) }
    }

    @Test func replacedRootRequiresNewApprovalAndSnapshotsCannotCrossRoots() throws {
        let fixture = try FolderIndexFixture()
        defer { fixture.remove() }
        try fixture.file("one.md")
        try fixture.file("one.md", under: fixture.outside)
        let root = try FolderIndex.authorize(fixture.root)
        let outside = try FolderIndex.authorize(fixture.outside)
        let symlink = fixture.directory.appending(path: "root-link", directoryHint: .isDirectory)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: fixture.root)
        #expect(throws: FolderIndex.Failure.rootUnavailable) { try FolderIndex.authorize(symlink) }
        let ancestor = fixture.directory.appending(path: "container-link", directoryHint: .isDirectory)
        try FileManager.default.createSymbolicLink(at: ancestor, withDestinationURL: fixture.directory)
        #expect(try FolderIndex.authorize(ancestor.appending(path: "root", directoryHint: .isDirectory)) == root)
        let selected = try #require(FolderIndex.scan(root).files.first)
        #expect(throws: FolderIndex.Failure.fileUnavailable) { try FolderIndex.open(selected, in: outside) }

        try FileManager.default.moveItem(at: fixture.root, to: fixture.directory.appending(path: "previous"))
        try fixture.file("one.md")
        #expect(throws: FolderIndex.Failure.rootUnavailable) { try FolderIndex.scan(root) }
        #expect(throws: FolderIndex.Failure.rootUnavailable) { try FolderIndex.open(selected, in: root) }
        let reapproved = try FolderIndex.authorize(fixture.root)
        #expect(try FolderIndex.scan(reapproved).files.count == 1)
    }

    @Test func remoteImagesRequireThePinnedFileInsideTheAuthorizedRoot() throws {
        let fixture = try FolderIndexFixture()
        defer { fixture.remove() }
        let root = try FolderIndex.authorize(fixture.root)
        let member = try fixture.file("notes/中文 100%?#.MARKDOWN")
        let reference = try DocumentCopyFileReference.open(at: member)
        let sibling = try fixture.file("notes/中文 100%?#.MARKDOWN", under: fixture.outside)
        let siblingReference = try DocumentCopyFileReference.open(at: sibling)

        #expect(FolderIndex.isCurrent(root))
        #expect(FolderIndex.verifyRemoteImageMember(at: member, in: root, reference: reference)
                == root.url.appending(path: "notes/中文 100%?#.MARKDOWN"))
        #expect(FolderIndex.verifyRemoteImageMember(at: member, in: root, reference: siblingReference) == nil)
        #expect(FolderIndex.verifyRemoteImageMember(at: sibling, in: root, reference: siblingReference) == nil)

        let alias = fixture.root.appending(path: "alias.md")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: member)
        #expect(FolderIndex.verifyRemoteImageMember(at: alias, in: root, reference: reference) == nil)
        let aliasParent = fixture.root.appending(path: "alias-notes")
        try FileManager.default.createSymbolicLink(at: aliasParent, withDestinationURL: member.deletingLastPathComponent())
        let aliasedPath = aliasParent.appending(path: member.lastPathComponent)
        #expect(FolderIndex.verifyRemoteImageMember(at: aliasedPath, in: root, reference: reference) == nil)

        let hardLink = fixture.outside.appending(path: "extra.md")
        try FileManager.default.linkItem(at: member, to: hardLink)
        #expect(FolderIndex.verifyRemoteImageMember(at: member, in: root, reference: reference) == nil)
        try FileManager.default.removeItem(at: hardLink)

        let moved = fixture.outside.appending(path: "moved.md")
        try FileManager.default.moveItem(at: member, to: moved)
        try fixture.file("notes/中文 100%?#.MARKDOWN")
        #expect(FolderIndex.verifyRemoteImageMember(at: member, in: root, reference: reference) == nil)
        #expect(FolderIndex.verifyRemoteImageMember(at: moved, in: root, reference: reference) == nil)

        let previous = fixture.directory.appending(path: "previous")
        try FileManager.default.moveItem(at: fixture.root, to: previous)
        let lookalike = try fixture.file("notes/中文 100%?#.MARKDOWN")
        let lookalikeReference = try DocumentCopyFileReference.open(at: lookalike)
        #expect(!FolderIndex.isCurrent(root))
        #expect(FolderIndex.verifyRemoteImageMember(at: lookalike, in: root, reference: lookalikeReference) == nil)
    }

    @Test func remoteImagesExcludeUnlistedFileTypesAndIneligibleDirectories() throws {
        let fixture = try FolderIndexFixture()
        defer { fixture.remove() }
        let root = try FolderIndex.authorize(fixture.root)
        let invisible = try fixture.file("invisible.md")
        try fixture.setFinderFlags(0x40, at: invisible)
        let alias = try fixture.file("finder.md")
        try fixture.setFinderFlags(0x80, at: alias)
        let files = try [invisible, alias, fixture.file(".git/note.md"), fixture.file("node_modules/note.md"),
                         fixture.file("Archive.app/Contents/note.md"), fixture.file("notes/sample.txt")]
        for file in files {
            let reference = try DocumentCopyFileReference.open(at: file)
            #expect(FolderIndex.verifyRemoteImageMember(at: file, in: root, reference: reference) == nil)
        }
    }

    @Test func remoteImageMembershipUsesActualEntrySpellingEvenOnCaseInsensitiveVolumes() throws {
        let fixture = try FolderIndexFixture()
        defer { fixture.remove() }
        let root = try FolderIndex.authorize(fixture.root)
        let note = try fixture.file("Notes/Note.md")
        let hidden = try fixture.file("node_modules/Note.md")
        let spelling = root.url.appending(path: "nOTES/nOTE.MD")
        let excludedSpelling = root.url.appending(path: "NODE_MODULES/nOTE.MD")
        let noteReference = try DocumentCopyFileReference.open(at: note)
        let hiddenReference = try DocumentCopyFileReference.open(at: hidden)
        let actual = try #require(FolderIndex.verifyRemoteImageMember(at: note, in: root, reference: noteReference))
        let fromAlternateSpelling = FolderIndex.verifyRemoteImageMember(at: spelling, in: root, reference: noteReference)

        if FileManager.default.fileExists(atPath: spelling.path) {
            #expect(fromAlternateSpelling?.path.utf8.elementsEqual(actual.path.utf8) == true)
        } else {
            #expect(fromAlternateSpelling == nil)
        }
        #expect(FolderIndex.verifyRemoteImageMember(at: excludedSpelling, in: root, reference: hiddenReference) == nil)
    }

    @Test func remoteImageMembershipPreservesKernelPathBytes() throws {
        let fixture = try FolderIndexFixture()
        defer { fixture.remove() }
        let root = try FolderIndex.authorize(fixture.root)
        let path = root.url.path + "/Caf\u{e9}.md"
        let descriptor = Darwin.open(path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        try #require(descriptor >= 0)
        Darwin.close(descriptor)

        var components = URLComponents()
        components.scheme = "file"
        components.host = ""
        components.path = path
        let url = try #require(components.url)
        let reference = try DocumentCopyFileReference.open(at: url)
        let actualPath = try #require(reference.currentPath())
        let verified = try #require(FolderIndex.verifyRemoteImageMember(at: url, in: root, reference: reference))
        #expect(verified.path.utf8.elementsEqual(actualPath.utf8))
    }

    @Test func favoriteAuthorizationRejectsMissingDirectoriesAndReplacementAliases() throws {
        let fixture = try FolderIndexFixture()
        defer { fixture.remove() }
        let root = try FolderIndex.authorize(fixture.root)
        #expect(try FolderIndex.authorizeFavorite(root.url) == root)

        let previous = fixture.directory.appending(path: "previous", directoryHint: .isDirectory)
        try FileManager.default.moveItem(at: fixture.root, to: previous)
        #expect(throws: FolderIndex.FavoriteFailure.missingOrMoved) { try FolderIndex.authorizeFavorite(root.url) }

        try FileManager.default.createSymbolicLink(at: fixture.root, withDestinationURL: previous)
        #expect(throws: FolderIndex.FavoriteFailure.symbolicLinkOrAlias) { try FolderIndex.authorizeFavorite(root.url) }
        try FileManager.default.removeItem(at: fixture.root)

        let alias = URL(filePath: root.url.path, directoryHint: .notDirectory)
        try Data().write(to: alias)
        try fixture.setFinderFlags(0x80, at: alias)
        #expect(throws: FolderIndex.Failure.rootUnavailable) { try FolderIndex.authorize(alias) }
        #expect(throws: FolderIndex.FavoriteFailure.symbolicLinkOrAlias) { try FolderIndex.authorizeFavorite(root.url) }
    }

    @Test func favoriteAuthorizationRejectsSymbolicLinksInAnAncestor() throws {
        let fixture = try FolderIndexFixture()
        defer { fixture.remove() }
        let note = try fixture.file("nested/test.md")
        let root = try FolderIndex.authorize(note.deletingLastPathComponent())
        let previous = fixture.directory.appending(path: "previous", directoryHint: .isDirectory)
        try FileManager.default.moveItem(at: fixture.root, to: previous)
        try FileManager.default.createSymbolicLink(at: fixture.root, withDestinationURL: previous)

        #expect(throws: FolderIndex.FavoriteFailure.symbolicLinkOrAlias) { try FolderIndex.authorizeFavorite(root.url) }
        let relocated = try FolderIndex.authorize(previous.appending(path: "nested", directoryHint: .isDirectory))
        #expect(try FolderIndex.authorize(root.url) == relocated)
    }

    @Test func favoriteAuthorizationReportsLostSearchPermission() throws {
        let fixture = try FolderIndexFixture()
        defer { fixture.remove() }
        let root = try FolderIndex.authorize(fixture.root)

        #expect(chmod(root.url.path, 0o400) == 0)
        defer { _ = chmod(root.url.path, 0o700) }
        // A privileged test runner is permitted to search this directory.
        if geteuid() != 0 {
            #expect(try FolderIndex.authorize(root.url) == root)
            #expect(throws: FolderIndex.FavoriteFailure.permissionDenied) { try FolderIndex.authorizeFavorite(root.url) }
        }
    }

    @Test func cancelledWorkAndOversizedDocumentsFailWithoutContentReads() async throws {
        let fixture = try FolderIndexFixture()
        defer { fixture.remove() }
        let file = try fixture.file("large.md")
        #expect(truncate(file.path, 32 * 1024 * 1024 + 1) == 0)
        let root = try FolderIndex.authorize(fixture.root)
        let fileEntry = try #require(FolderIndex.scan(root).files.first)
        #expect(throws: FolderIndex.Failure.fileTooLarge) { try FolderIndex.open(fileEntry, in: root) }
        let worker = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try FolderIndex.scan(root)
        }
        await #expect(throws: CancellationError.self) { try await worker.value }
    }
}
