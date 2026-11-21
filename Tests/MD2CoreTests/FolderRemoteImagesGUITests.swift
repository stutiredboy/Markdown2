import AppKit
import ApplicationServices
import Carbon.HIToolbox
import XCTest

@testable import MD2App

/// Drives permission changes through native controls and verifies which
/// documents reach a real HTTP image server in a separate app process.
final class FolderRemoteImagesGUITests: XCTestCase {
    @MainActor
    func testFolderPermissionFollowsVerifiedTabsAndDocumentOverrides() async throws {
        try requireGUI()
        let fixture = try await Fixture()
        defer { fixture.close() }
        let guide = try fixture.note("Workspace/Guide.md", "guide")
        let ordinary = try fixture.note("Workspace/Ordinary.md", "ordinary")
        let nested = try fixture.note("Workspace/Notes/Nested.md", "nested")
        let sibling = try fixture.note("Workspace/Sibling.md", "sibling")
        let peer = try fixture.note("Workspace/Peer.md", "peer")
        let afterRevoke = try fixture.note("Workspace/After Revoke.md", "after-revoke")
        let outside = try fixture.note("Other Folder/Outside.md", "outside")
        let app = try await FolderTestApplication.launch(in: fixture.directory, arguments: [guide.path],
                                                         presentationMode: .split)
        defer { app.close() }

        let guideWindow = try app.documentWindow(guide, focused: true)
        try app.waitForRenderedImageFixture("guide", in: guideWindow)
        _ = try app.chooseDocumentFolder(containing: guide)
        fixture.assertQuiet("guide")
        try app.grantFolderImages(from: .document, in: guideWindow)
        try await fixture.waitForRequest("guide")

        try await app.openFileThroughWorkspace(ordinary)
        let standalone = try app.documentWindow(ordinary, focused: true)
        try app.waitForRenderedImageFixture("ordinary", in: standalone)
        fixture.assertQuiet("ordinary")
        let grouped = try app.openFolderNote(ordinary)
        XCTAssertTrue(CFEqual(grouped, standalone))
        try await fixture.waitForRequest("ordinary")

        try await app.openFileThroughWorkspace(outside)
        let outsideWindow = try app.documentWindow(outside, focused: true)
        try app.waitForRenderedImageFixture("outside", in: outsideWindow)
        fixture.assertQuiet("outside")

        try app.focusFiles()
        try app.pressMenuCommand("Window", "Merge All Windows")
        let merged = try app.waitFor("the folder group includes the outside document after merging windows") {
            guard let window = app.focusedWindow else { return nil }
            let tabs = app.tabTitles(in: window)
            return tabs.contains(guide.lastPathComponent) && tabs.contains(outside.lastPathComponent) ? window : nil
        }
        let outsideTab = try app.selectTab(for: outside, from: merged)
        XCTAssertTrue(CFEqual(outsideTab, outsideWindow))
        try app.waitForImageStatus(.remoteImagesBlocked, in: outsideTab)
        fixture.assertQuiet("outside")

        let nestedPreview = try app.openFolderNote(nested, relativePath: "Notes/Nested.md", preview: true)
        try app.waitForPreview(nested, in: nestedPreview)
        try await fixture.waitForRequest("nested")
        let siblingPreview = try app.openFolderNote(sibling, preview: true)
        try app.waitForPreview(sibling, in: siblingPreview)
        try await fixture.waitForRequest("sibling")
        XCTAssertFalse(try app.nativeTabs(in: siblingPreview).map(app.title).contains(nested.lastPathComponent))

        try app.pressImagePermission(.blockDocument, from: .document, in: siblingPreview)
        try app.waitForImageStatus(.remoteImagesBlockedByDocument, in: siblingPreview)
        let peerPreview = try app.openFolderNote(peer, preview: true)
        try await fixture.waitForRequest("peer")
        XCTAssertFalse(try app.nativeTabs(in: peerPreview).map(app.title).contains(sibling.lastPathComponent))

        // Use a fresh image URL without replacing the indexed file's identity.
        do {
            let file = try FileHandle(forWritingTo: sibling)
            defer { try? file.close() }
            let content = Data(fixture.markdown("sibling-reopened-blocked").utf8)
            try file.write(contentsOf: content)
            try file.truncate(atOffset: UInt64(content.count))
        }
        let reopenedSibling = try app.openFolderNote(sibling, preview: true)
        try app.waitForRenderedImageFixture("sibling-reopened-blocked", in: reopenedSibling)
        fixture.assertQuiet("sibling-reopened-blocked")
        try app.pressImagePermission(.restoreInheritance, from: .document, in: reopenedSibling)
        try await fixture.waitForRequest("sibling-reopened-blocked")

        try app.pressImagePermission(.revokeFolder, from: .sidebar, in: reopenedSibling)
        try app.waitForImageStatus(.remoteImagesBlocked, in: reopenedSibling)
        try app.replaceEditorText(fixture.markdown("sibling-after-revoke"), in: app.editor(in: reopenedSibling))
        try app.waitForRenderedImageFixture("sibling-after-revoke", in: reopenedSibling)
        let activeGuide = try app.selectTab(for: guide, from: reopenedSibling)
        try app.replaceEditorText(fixture.markdown("guide-after-revoke"), in: app.editor(in: activeGuide))
        try app.waitForRenderedImageFixture("guide-after-revoke", in: activeGuide)
        let revoked = try app.openFolderNote(afterRevoke)
        try app.waitForRenderedImageFixture("after-revoke", in: revoked)
        fixture.assertQuiet("guide-after-revoke", "sibling-after-revoke", "after-revoke", "outside")

        try app.grantFolderImages(from: .sidebar, in: revoked)
        try await fixture.waitForRequest("after-revoke")
        let switched = try app.chooseFolderByPath(containing: outside)
        XCTAssertTrue(CFEqual(switched, revoked))
        try app.replaceEditorText(fixture.markdown("after-switch"), in: app.editor(in: switched))
        try app.waitForRenderedImageFixture("after-switch", in: switched)
        fixture.assertQuiet("after-switch", "outside")
    }

    @MainActor
    func testFavoriteFolderPermissionPersistsAndRevocationAndRemovalTakeEffect() async throws {
        try requireGUI()
        let fixture = try await Fixture()
        defer { fixture.close() }
        let guide = try fixture.note("Favorite Workspace/Guide.md", "favorite-initial")
        let persisted = try fixture.note("Favorite Workspace/Persisted.md", "favorite-persisted")
        let revoked = try fixture.note("Favorite Workspace/Revoked.md", "favorite-revoked")
        let afterRemoval = try fixture.note("Favorite Workspace/After Removal.md", "favorite-removed")
        let reopened = try fixture.note("Favorite Workspace/Reopened.md", "favorite-reopened")
        let favoriteName = guide.deletingLastPathComponent().lastPathComponent
        var app = try await FolderTestApplication.launch(in: fixture.directory, arguments: [], presentationMode: .split)
        defer { app.close() }

        let landing = try app.chooseFolderByPath(containing: guide)
        try app.grantFolderImages(from: .sidebar, in: landing)
        _ = try app.openFolderNote(guide)
        try await fixture.waitForRequest("favorite-initial")
        let granted = try app.documentWindow(guide, focused: true)
        try app.press(app.element("folder-favorite-toggle", in: granted))
        _ = try app.favoriteFolderItem(favoriteName)

        app = try await app.relaunch()
        try app.press(app.favoriteFolderItem(favoriteName))
        _ = try app.waitForFolder(containing: guide)
        let restored = try app.openFolderNote(persisted)
        try await fixture.waitForRequest("favorite-persisted")

        try app.pressImagePermission(.revokeFolder, from: .sidebar, in: restored)
        try app.waitForImageStatus(.remoteImagesBlocked, in: restored)
        let blocked = try app.openFolderNote(revoked)
        try app.waitForRenderedImageFixture("favorite-revoked", in: blocked)
        fixture.assertQuiet("favorite-revoked")

        app = try await app.relaunch()
        try app.press(app.favoriteFolderItem(favoriteName))
        _ = try app.waitForFolder(containing: guide)
        let previouslyRevoked = try app.openFolderNote(revoked)
        try app.waitForRenderedImageFixture("favorite-revoked", in: previouslyRevoked)
        fixture.assertQuiet("favorite-revoked")

        try app.grantFolderImages(from: .sidebar, in: previouslyRevoked, remembered: true)
        try await fixture.waitForRequest("favorite-revoked")
        try app.press(app.element("folder-favorite-toggle", in: previouslyRevoked))
        _ = try app.favoriteFolderItem("No Favorite Folders", enabled: false)
        try app.waitForImageStatus(.remoteImagesBlocked, in: previouslyRevoked)
        try app.replaceEditorText(fixture.markdown("favorite-active-after-removal"), in: app.editor(in: previouslyRevoked))
        try app.waitForRenderedImageFixture("favorite-active-after-removal", in: previouslyRevoked)
        try app.key(kVK_ANSI_S, flags: .maskCommand)
        _ = try app.waitFor("the test edit is saved before relaunching") {
            (try? String(contentsOf: revoked, encoding: .utf8)) == fixture.markdown("favorite-active-after-removal")
                ? previouslyRevoked : nil
        }
        let removed = try app.openFolderNote(afterRemoval)
        try app.waitForRenderedImageFixture("favorite-removed", in: removed)
        fixture.assertQuiet("favorite-active-after-removal", "favorite-removed")

        app = try await app.relaunch()
        let reopenedLanding = try app.chooseFolderByPath(containing: guide)
        XCTAssertEqual(app.identifier(reopenedLanding), "folder-landing-window")
        let reopenedWindow = try app.openFolderNote(reopened)
        try app.waitForRenderedImageFixture("favorite-reopened", in: reopenedWindow)
        fixture.assertQuiet("favorite-reopened")
    }

    private func requireGUI() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1",
                          "Set MD2_RUN_GUI_TESTS=1 to exercise folder remote-image permissions.")
        guard AXIsProcessTrusted() else { throw FixtureError("Remote image permissions require Accessibility trust") }
    }
}

private struct FixtureError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private struct Fixture {
    let directory: URL
    let server: ResourceRequestServer
    let port: UInt16

    init() async throws {
        let server = try ResourceRequestServer()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while server.port == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        guard let port = server.port else {
            server.stop()
            throw FixtureError("The image server never started listening")
        }
        self.server = server
        self.port = port
        directory = FileManager.default.temporaryDirectory.appending(path: "MD2-Folder-Images-\(UUID())", directoryHint: .isDirectory)
    }

    func markdown(_ marker: String) -> String {
        "# Fixture \(marker)\n\n![Test image](http://localhost:\(port)/\(marker).png)\n"
    }

    func note(_ relativePath: String, _ marker: String) throws -> URL {
        let file = directory.appending(path: relativePath, directoryHint: .notDirectory)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try markdown(marker).write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    func waitForRequest(_ marker: String) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !server.requests.contains(where: { $0.path == "/\(marker).png" }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        guard server.requests.contains(where: { $0.path == "/\(marker).png" }) else {
            throw FixtureError("Expected /\(marker).png. Requests: \(server.requests.map(\.path))")
        }
    }

    @MainActor
    func assertQuiet(_ markers: String..., file: StaticString = #filePath, line: UInt = #line) {
        RunLoop.current.run(until: Date().addingTimeInterval(0.45))
        let denied = Set(markers.map { "/\($0).png" })
        XCTAssertTrue(server.requests.allSatisfy { !denied.contains($0.path) },
                      "Unexpected image requests for \(markers): \(server.requests.map(\.path))",
                      file: file, line: line)
    }

    func close() {
        server.stop()
        try? FileManager.default.removeItem(at: directory)
    }
}

private enum ImagePermissionSurface: String {
    case document = "remote-images-permissions"
    case sidebar = "folder-remote-images-menu"
}

private enum ImagePermissionAction: String {
    case grantFolder = "Allow for This Folder…"
    case revokeFolder = "Remove Folder Permission"
    case blockDocument = "Block in This Document"
    case restoreInheritance = "Use Folder Permission"

    var identifier: String {
        switch self {
        case .grantFolder: "remote-images-folder-allow"
        case .revokeFolder: "remote-images-folder-revoke"
        case .blockDocument: "remote-images-block-document"
        case .restoreInheritance: "remote-images-restore-inheritance"
        }
    }
}

@MainActor
private extension FolderTestApplication {
    func openFolderNote(_ document: URL, relativePath: String? = nil, preview: Bool = false) throws -> AXUIElement {
        let result = try quickFind(relativePath ?? document.lastPathComponent, expecting: document.lastPathComponent)
        if preview {
            try focusFiles()
            try key(kVK_Space)
        } else {
            try openSelection(using: result.open)
        }
        return try documentWindow(document, focused: true)
    }

    func waitForRenderedImageFixture(_ marker: String, in window: AXUIElement) throws {
        _ = try waitFor("rendered fixture \(marker)") {
            guard let web = descendant(window, matching: { attribute(kAXRoleAttribute, of: $0) as? String == "AXWebArea" })
            else { return nil }
            return descendant(web) { labels($0).contains("Fixture \(marker)") }
        }
    }

    func waitForImageStatus(_ key: L10nKey, in window: AXUIElement) throws {
        let status = L10n.text(key, language: .english)
        _ = try waitFor("the document reports \(status)") {
            descendant(window) { identifier($0) == "remote-images-status" && labels($0).contains(status) }
        }
    }

    func selectTab(for document: URL, from window: AXUIElement) throws -> AXUIElement {
        let tab = try XCTUnwrap(nativeTabs(in: window).first { title($0).hasPrefix(document.lastPathComponent) })
        try press(tab)
        return try documentWindow(document, focused: true)
    }

    func pressImagePermission(
        _ action: ImagePermissionAction, from surface: ImagePermissionSurface, in window: AXUIElement
    ) throws {
        let opener = try element(surface.rawValue, in: window)
        try press(opener)
        let item = try waitFor("the \(action.rawValue) permission action") {
            for root in [opener, window] + windows {
                if let item = descendant(root, matching: {
                    identifier($0) == action.identifier ||
                        (attribute(kAXRoleAttribute, of: $0) as? String == kAXMenuItemRole && title($0) == action.rawValue)
                }) {
                    return item
                }
            }
            return nil
        }
        try press(item)
    }

    func grantFolderImages(
        from surface: ImagePermissionSurface, in window: AXUIElement, remembered: Bool = false
    ) throws {
        let root = try element("folder-root-path", in: window)
        let path = try XCTUnwrap(labels(root).first { $0.hasPrefix("/") })
        let lifetime = L10n.text(remembered ? .remoteImagesFolderFavorite : .remoteImagesFolderSession, language: .english)
        try pressImagePermission(.grantFolder, from: surface, in: window)
        _ = try waitFor("the consent sheet identifies the root and permission lifetime") {
            descendant(window) {
                labels($0).contains { $0.contains(path) && $0.contains(lifetime) }
            }
        }
        let confirm = try element("folder-remote-images-confirm", in: window)
        try press(confirm)
        _ = try waitFor("the folder permission sheet to dismiss") {
            descendant(window) { identifier($0) == "folder-remote-images-confirm" } == nil ? window : nil
        }
    }

    func favoriteFolderItem(_ name: String, enabled: Bool = true) throws -> AXUIElement {
        try waitFor("Favorite Folders’ \(name) menu item") {
            guard let menuBar,
                  let file = children(menuBar).first(where: { title($0) == "File" }),
                  let fileMenu = children(file).first,
                  let favorites = children(fileMenu).first(where: { title($0) == "Favorite Folders" }),
                  let submenu = children(favorites).first else { return nil }
            return children(submenu).first {
                title($0) == name && (attribute(kAXEnabledAttribute, of: $0) as? Bool) == enabled
            }
        }
    }
}
