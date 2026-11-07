import AppKit

/// Data for matching one native context-menu gesture to its isolated DOM
/// snapshot, never permission for a navigation delegate to open anything.
@MainActor
struct PreviewContextMenuInput {
    struct Capture {
        let generation: UUID
        let point: NSPoint
        let page: URL
        let windowNumber: Int
    }
    private var generation = UUID()
    private var pending: Capture?

    mutating func record(_ event: NSEvent, point: NSPoint, page: URL?, windowNumber: Int?) {
        invalidate()
        guard event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control)),
              let page, let windowNumber, event.windowNumber == windowNumber else { return }
        pending = Capture(generation: generation, point: point, page: page, windowNumber: windowNumber)
    }

    mutating func take(for page: URL?) -> Capture? {
        defer { pending = nil }
        guard let pending, pending.page == page else { return nil }
        return pending
    }

    func matches(_ input: Capture, page: URL?, point: NSPoint, windowNumber: Int?) -> Bool {
        generation == input.generation && page == input.page && windowNumber == input.windowNumber
            && abs(input.point.x - point.x) <= 2 && abs(input.point.y - point.y) <= 2
    }

    mutating func invalidate() { generation = UUID(); pending = nil }
}

/// Keeps WebKit's localized Copy/Save/Share items intact. These identifier raw
/// values are WebKit implementation conventions, not public SDK constants:
/// live-menu GUI tests pin their compatibility. No private selector is called.
@MainActor
final class PreviewContextMenuAdapter {
    static let linkIdentifiers: Set<String> = ["WKMenuItemIdentifierOpenLink", "WKMenuItemIdentifierOpenLinkInNewWindow"]
    static let imageIdentifier = "WKMenuItemIdentifierOpenImageInNewWindow"
    var open: (URL) -> Void = { _ in }
    var resolveImage: (URL) -> URL? = { _ in nil }
    private weak var currentMenu: NSMenu?
    private var generation = UUID()
    private var originals: [ObjectIdentifier: (AnyObject?, Selector?, Bool)] = [:]

    @discardableResult func begin(_ menu: NSMenu) -> UUID {
        invalidate()
        currentMenu = menu
        // Never leave an unbound native navigation item active while the
        // isolated-world query is in flight. All other native items are intact.
        for item in items(in: menu) where Self.isOpenItem(item) {
            originals[ObjectIdentifier(item)] = (item.target, item.action, item.isEnabled)
            item.target = nil
            item.action = nil
            item.isEnabled = false
        }
        return generation
    }

    func bind(_ menu: NSMenu, generation expected: UUID, link: URL?, image: URL?, page: URL?) {
        guard currentMenu === menu, generation == expected else { return }
        for item in items(in: menu) {
            let identifier = item.identifier?.rawValue ?? ""
            let destination: URL?
            if Self.linkIdentifiers.contains(identifier) { destination = link }
            else if identifier == Self.imageIdentifier {
                destination = image.flatMap { resolveImage($0) ?? $0 }
            } else { continue }
            guard let destination else { continue }
            let route = PreviewLinkRouter.route(for: destination, documentPageURL: page)
            // Same-page menu navigation keeps WebKit's behavior; the navigation
            // delegate still admits only the exact current document page.
            if route == .allowInPage, let original = originals[ObjectIdentifier(item)] {
                item.target = original.0
                item.action = original.1
                item.isEnabled = original.2
                continue
            }
            let action = ContextMenuOpenAction { [weak self] in
                guard let self, self.generation == expected else { return }
                self.open(destination)
            }
            guard route != .ignore, route != .allowInPage else { continue }
            item.target = action
            item.action = #selector(ContextMenuOpenAction.openMenuTarget(_:))
            // NSMenuItem's target is weak. Retain the immutable action with its
            // own item, even when AppKit closes the menu before invoking it.
            item.representedObject = action
            item.isEnabled = originals[ObjectIdentifier(item)]?.2 ?? false
        }
    }

    func end(_ menu: NSMenu) {
        if currentMenu === menu { currentMenu = nil; originals = [:] }
        // AppKit can send the selected action after didCloseMenu. Only that
        // immutable native action survives; no navigation-delegate permission does.
    }

    func invalidate() {
        generation = UUID()
        let old = currentMenu
        currentMenu = nil
        originals = [:]
        old?.cancelTracking()
    }

    private static func isOpenItem(_ item: NSMenuItem) -> Bool {
        let identifier = item.identifier?.rawValue ?? ""
        return linkIdentifiers.contains(identifier) || identifier == imageIdentifier
    }

    private func items(in menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in [item] + (item.submenu.map { items(in: $0) } ?? []) }
    }
}

@MainActor private final class ContextMenuOpenAction: NSObject {
    private var body: (() -> Void)?
    init(_ body: @escaping () -> Void) { self.body = body }
    @objc func openMenuTarget(_ sender: NSMenuItem) {
        let action = body
        body = nil
        action?()
    }
}
