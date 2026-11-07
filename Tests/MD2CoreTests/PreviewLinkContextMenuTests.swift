import AppKit
import Testing
@testable import MD2App

// AppKit menu actions pump the run loop; serialize to prevent another test's
// cancellation from interrupting an action currently being dispatched.
@Suite(.serialized) @MainActor struct PreviewLinkContextMenuTests {
    init() { _ = NSApplication.shared }
    @Test func nativeItemsKeepOtherActionsAndFreezeTargetsWithoutOpeningOnShow() {
        _ = NSApplication.shared
        let adapter = PreviewContextMenuAdapter()
        var opened: [URL] = []
        adapter.open = { opened.append($0) }
        let target = MenuActionTarget()
        let menu = fixture(target)
        let copy = menu.items[2]
        let copyAction = copy.action
        let copyObject = copy.representedObject as? String
        let first = URL(string: "https://example.com/first")!
        let generation = adapter.begin(menu)
        #expect(opened.isEmpty)
        #expect(!menu.items[0].isEnabled)
        adapter.bind(menu, generation: generation, link: first, image: nil, page: nil)
        #expect(opened.isEmpty)
        #expect(copy.target === target)
        #expect(copy.action == copyAction)
        #expect(copy.representedObject as? String == copyObject)
        #expect(copy.title == "WebKit localized copy")
        #expect(copy.isEnabled)
        menu.performActionForItem(at: 2)
        #expect(target.count == 1)
        adapter.end(menu)
        // AppKit may close a menu before dispatching the selected action.
        menu.performActionForItem(at: 0)
        #expect(opened == [first])
        menu.performActionForItem(at: 0)
        #expect(opened == [first])
    }

    @Test func originallyDisabledOpenItemsRemainDisabled() {
        let adapter = PreviewContextMenuAdapter()
        let target = MenuActionTarget()
        let menu = fixture(target)
        menu.items[0].isEnabled = false
        let generation = adapter.begin(menu)
        adapter.bind(menu, generation: generation, link: URL(string: "https://example.com/disabled"),
                     image: nil, page: nil)
        #expect(!menu.items[0].isEnabled)
    }

    @Test func cancelledLateMetadataAndOldPageActionsCannotBindAnotherMenu() {
        let adapter = PreviewContextMenuAdapter()
        var opened: [URL] = []
        adapter.open = { opened.append($0) }
        let target = MenuActionTarget()
        let first = fixture(target), second = fixture(target)
        let stale = adapter.begin(first)
        adapter.end(first)
        adapter.bind(first, generation: stale, link: URL(string: "https://example.com/stale"), image: nil, page: nil)
        #expect(!first.items[0].isEnabled)
        let current = adapter.begin(second)
        adapter.bind(second, generation: stale, link: URL(string: "https://example.com/wrong"), image: nil, page: nil)
        #expect(!second.items[0].isEnabled)
        adapter.bind(second, generation: current, link: URL(string: "https://example.com/current"), image: nil, page: nil)
        adapter.invalidate()
        second.performActionForItem(at: 0)
        #expect(opened.isEmpty)
        #expect(target.count == 0)
    }

    @Test func imageAndLinkTargetsStayDistinctAndSamePageUsesOriginalNativeAction() {
        let adapter = PreviewContextMenuAdapter()
        var opened: [URL] = []
        adapter.open = { opened.append($0) }
        let link = URL(string: "https://example.com/link")!
        let image = URL(string: "https://example.com/image.png")!
        let target = MenuActionTarget()
        let menu = fixture(target)
        let generation = adapter.begin(menu)
        adapter.bind(menu, generation: generation, link: link, image: image, page: nil)
        menu.performActionForItem(at: 1)
        #expect(opened == [image])
        menu.performActionForItem(at: 0)
        #expect(opened == [image, link])
        let page = URL(string: "md2-doc://document/id/index.html")!
        let same = fixture(target), sameGeneration = adapter.begin(same)
        adapter.bind(same, generation: sameGeneration, link: URL(string: "#section", relativeTo: page)?.absoluteURL,
                     image: nil, page: page)
        #expect(same.items[0].target === target)
        same.performActionForItem(at: 0)
        #expect(target.count == 1)
        #expect(opened == [image, link])
        let blocked = fixture(target), blockedGeneration = adapter.begin(blocked)
        adapter.bind(blocked, generation: blockedGeneration, link: URL(string: "ssh://example.com"),
                     image: URL(string: "md2-local-image://image/unknown"), page: page)
        #expect(!blocked.items[0].isEnabled)
        #expect(!blocked.items[1].isEnabled)
    }

    @Test func localImagesRequireExactCurrentlyWhitelistedURL() {
        let loader = WebDocumentLoader()
        let file = URL(fileURLWithPath: "/tmp/current-image.png")
        loader.installImages(["token": file])
        let good = URL(string: "md2-local-image://image/token")!
        #expect(loader.originalImageURL(for: good) == file)
        for spelling in ["md2-local-image://image/unknown", "md2-local-image://image/token?x=1",
                         "md2-local-image://image/token#x", "md2-local-image://image/token/more",
                         "md2-local-image://other/token", "md2-local-image://image/%74oken",
                         "md2-local-image://image:80/token", "md2-local-image://user@image/token",
                         "file:///tmp/current-image.png"] {
            #expect(loader.originalImageURL(for: URL(string: spelling)!) == nil, "\(spelling)")
        }
        loader.installImages([:])
        #expect(loader.originalImageURL(for: good) == nil)
    }

    private func fixture(_ target: MenuActionTarget) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (identifier, title) in [("WKMenuItemIdentifierOpenLink", "Open"),
                                    ("WKMenuItemIdentifierOpenImageInNewWindow", "Image"),
                                    ("WKMenuItemIdentifierCopyLink", "WebKit localized copy")] {
            let item = NSMenuItem(title: title, action: #selector(MenuActionTarget.countMenuAction(_:)), keyEquivalent: "")
            item.identifier = NSUserInterfaceItemIdentifier(identifier)
            item.target = target
            item.representedObject = "original WebKit metadata"
            menu.addItem(item)
        }
        return menu
    }
}

@MainActor private final class MenuActionTarget: NSObject {
    var count = 0
    @objc func countMenuAction(_ sender: Any?) { count += 1 }
}
