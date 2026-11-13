import AppKit
import MD2Core
import SwiftUI
import WebKit

/// Hands the surrounding view a way to ask the *live* preview page for its
/// current viewport anchor at the instant a mode switch is requested, instead
/// of relying on the last (possibly stale) debounced scroll callback.
@MainActor
final class PreviewViewportReader {
    fileprivate var capture: ((_ completion: @escaping (ViewportAnchor?) -> Void) -> Void)?
    /// Scrolls the live preview directly to a (possibly fractional) source line
    /// for continuous Side by Side follow — lighter than a mode-switch anchor and
    /// without the pinning settle loop, so the preview tracks the editor smoothly.
    fileprivate var follow: ((Double) -> Void)?
    /// Records the caret's source line so the next live-content swap keeps its
    /// rendered output in view, nudging the preview only when that line is
    /// off-screen so an edit in the middle of the viewport never yanks the preview.
    fileprivate var setEditFollow: ((Int?) -> Void)?

    /// Asks the live web view for its current anchor. Completes with `nil`
    /// when the preview is not mounted or does not answer within the capture
    /// timeout (e.g. the page is still executing heavy engine scripts).
    func currentAnchor(completion: @escaping (ViewportAnchor?) -> Void) {
        guard let capture else {
            completion(nil)
            return
        }
        capture(completion)
    }

    /// Drives the preview to follow the editor to `line` (continuous sync).
    func scrollToFollowLine(_ line: Double) {
        follow?(line)
    }

    /// Marks the caret's source `line` (or `nil` to clear) so the next live
    /// re-render keeps its rendered output visible without disturbing the preview
    /// when the line is already on screen.
    func setPendingEditFollow(_ line: Int?) {
        setEditFollow?(line)
    }
}

struct MarkdownPreviewView: NSViewRepresentable {
    let html: String
    /// The rendered content inside `<main>`, used for the in-place live update
    /// path so edits do not reload the whole page (see `liveUpdate`).
    var bodyHTML: String = ""
    /// The `math-macros:` map `html` was built with. A live update replaces
    /// only the body, so it hands these to the page with each update.
    var mathMacros: [String: String] = [:]
    let baseURL: URL?
    var remoteResourcePolicy: RemoteResourcePolicy = .blocked
    /// Changes with document identity or native permission, never source edits.
    var remoteResourceContextToken: UUID? = nil
    var onRegisterResourceInvalidator: (@escaping @MainActor () -> Void) -> Void = { _ in }
    /// When true (Side by Side mode), content-only changes are applied in place
    /// via `__md2ApplyContent` — preserving scroll position and avoiding the
    /// full-page reload flash — instead of reloading the web view.
    var liveUpdate: Bool = false
    /// Whether the preview should show a rendered leading YAML front-matter block.
    /// The shared renderer still emits it; this is a preview-only visibility state.
    var showsFrontMatter: Bool = true
    /// Whether the preview shows the starting source line beside each rendered
    /// block. Preview-only: the gutter lives in the injected user script, which
    /// the PDF exporter and the HTML builder never receive, so exported output is
    /// unaffected. Independent of the editor's own line-number preference.
    var showsLineNumbers: Bool = false
    /// The document's source-line revision that `html` was rendered from, which
    /// the page hands back with each checkbox click (see `labelPage`).
    var sourceLineRevision: Int = 0
    @Binding var jumpHeadingID: String?
    /// Fraction (0...1) to scroll to after load when no heading anchor applies.
    @Binding var jumpFraction: Double?
    /// Mode-switch viewport anchor to apply after load; takes precedence over
    /// `jumpHeadingID`/`jumpFraction` and is consumed once handed off.
    @Binding var jumpAnchor: ViewportAnchor?
    /// Exposes on-demand capture of the live viewport anchor for mode switches.
    var viewportReader: PreviewViewportReader?
    /// Reports the viewport-context anchor at the top of the viewport
    /// (debounced) on scroll, so a mode switch can fall back to it.
    var onAnchorChange: (_ anchor: ViewportAnchor, _ isUserInitiated: Bool) -> Void = { _, _ in }
    /// Called on a Cmd+double-click, requesting a switch to edit mode.
    var onEnterEdit: () -> Void = {}
    /// Called when the user presses Esc in the preview page. Returns whether
    /// the key was consumed (a visible find bar was dismissed); an unconsumed
    /// Esc stays available to the responder chain and the system.
    var onEscape: () -> Bool = { false }
    /// Called when a task checkbox is clicked, carrying the 1-based source
    /// line to rewrite, the absolute state the checkbox now shows and the
    /// source-line revision of the page that was clicked. A click the document
    /// refuses must call `restoreBoxes`: the page changed the box itself, and
    /// without an edit no re-render puts it back.
    var onToggleTask: (
        _ line: Int, _ checked: Bool, _ revision: Int, _ restoreBoxes: @escaping () -> Void
    ) -> Void = { _, _, _, _ in }
    /// Called when a gutter number is clicked, carrying the 1-based source
    /// line it shows, for the editor to select.
    var onRevealSourceLine: (_ line: Int) -> Void = { _ in }
    /// Called when the user clicks a link to a local Markdown file, so the app
    /// can open it in a document window (the preview itself never navigates).
    var onOpenMarkdownLink: (_ url: URL) -> Void = { _ in }
    var onMissingLocalLink: (_ url: URL) -> Void = { _ in }
    /// Hands a clicked link to the system. A test replaces it, because the real
    /// one starts whatever handles the URL.
    var onOpenWithSystem: (_ url: URL) -> Void = { NSWorkspace.shared.open($0) }
    /// The current find query; running search whenever it changes.
    @Binding var findQuery: String
    var findOptions = TextSearch.Options()
    /// A next/previous navigation request; consumed (set to nil) once applied.
    @Binding var findNavigation: FindCommand?
    /// Changes whenever the preview surface should become first responder.
    let focusToken: UUID
    /// Kept by ContentView across resource-context replacements. Legacy direct
    /// callers without a session retain the coordinator-local focus behavior.
    var focusState: PreviewFocusState? = nil
    /// Called when the web view receives a standard Find key/menu action before
    /// SwiftUI commands can route it through `DocumentStore`.
    var onFindShortcut: (_ action: FindCommand.Action) -> Void = { _ in }
    /// Reports match count and the 1-based index of the current match (0 when
    /// there are none) back to the find bar.
    var onFindResult: (_ total: Int, _ index: Int) -> Void = { _, _ in }
    var onFindUnavailable: (Bool) -> Void = { _ in }
    /// Localized labels shown in preview-only broken-image placeholders. The
    /// failed path/URL is appended at runtime as text.
    var localImageMissingLabel: String = "Image not found"
    var remoteImageUnavailableLabel: String = "Remote image could not be loaded"
    var remoteImageBlockedLabel: String = "Remote image blocked — allow images using the document’s Remote Images control."
    var genericImageLoadFailedLabel: String = "Image could not be loaded"
    var typography: TypographySettings = .init()
    /// Selected rendered HTML (nil when collapsed); the owner extracts/counts
    /// text off the main actor, so Select All cannot stall the WebKit callback.
    var onSelectionChange: (String?) -> Void = { _ in }

    static let selectionMessageName = "selectionChange"
    static let selectionScript = """
    (function () {
        var pending = false;
        function report() {
            pending = false;
            var selection = window.getSelection();
            var main = document.querySelector('main');
            if (!selection || selection.isCollapsed || !main || !main.contains(selection.anchorNode) || !main.contains(selection.focusNode)) {
                window.webkit.messageHandlers.selectionChange.postMessage(null);
                return;
            }
            var content = document.createElement('div');
            var excluded = '.front-matter,.footnote-ref,.footnote-backref,.diagram,.math,.toc,.md2-broken-image,.md2-line-gutter';
            for (var i = 0; i < selection.rangeCount; i++) {
                var range = selection.getRangeAt(i);
                var ancestor = range.commonAncestorContainer;
                if (ancestor.nodeType !== Node.ELEMENT_NODE) { ancestor = ancestor.parentElement; }
                if (ancestor && ancestor.closest(excluded)) { continue; }
                content.appendChild(range.cloneContents());
            }
            content.querySelectorAll(excluded).forEach(function (element) { element.remove(); });
            window.webkit.messageHandlers.selectionChange.postMessage(content.innerHTML);
        }
        document.addEventListener('selectionchange', function () {
            if (!pending) { pending = true; setTimeout(report, 60); }
        });
        window.addEventListener('load', report);
    })();
    """

    private static let enterEditMessageName = "enterEdit"
    private static let anchorMessageName = "anchorChange"
    private static let toggleTaskMessageName = "toggleTask"
    private static let revealSourceLineMessageName = "revealSourceLine"
    private static let openLinkMessageName = "openLink"
    private static let forwardedLinkSchemes = String(decoding:
        try! JSONEncoder().encode(HTMLSafety.safeURLSchemes.sorted().map { $0 + ":" }), as: UTF8.self)

    /// Page scripts (including diagram engines) cannot see native mutation
    /// handlers. Only trusted DOM input in the isolated world is forwarded.
    static func installInteractionBridge(on controller: WKUserContentController, handler: WKScriptMessageHandler) {
        controller.add(handler, contentWorld: .defaultClient, name: enterEditMessageName)
        controller.add(handler, contentWorld: .defaultClient, name: toggleTaskMessageName)
        controller.add(handler, contentWorld: .defaultClient, name: revealSourceLineMessageName)
        controller.add(handler, contentWorld: .defaultClient, name: openLinkMessageName)
        controller.addUserScript(WKUserScript(source: interactionScript,
            injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
    }

    static let interactionScript = """
        // WKNavigationAction.linkActivated also describes scripted clicks. Only
        // trusted DOM input in this isolated world may invoke native handlers.
        // Delegation includes live updates and diagram/SVG anchors; the native
        // router still checks the shared scheme list and local file existence.
        document.addEventListener('click', function (event) {
            if (!event.isTrusted || event.defaultPrevented || event.button !== 0) { return; }
            var target = event.target;
            var link = target && target.closest ? target.closest('a') : null;
            if (!link) { return; }
            var href = link.getAttribute('href') || link.getAttributeNS('http://www.w3.org/1999/xlink', 'href');
            if (!href) { return; }
            var url;
            try { url = new URL(href, document.baseURI); } catch (_) { return; }
            var page = new URL(location.href), destinationPage = new URL(url.href);
            page.hash = ''; destinationPage.hash = '';
            if (destinationPage.href === page.href) { return; }
            if (\(Self.forwardedLinkSchemes).indexOf(url.protocol) === -1) { return; }
            event.preventDefault();
            window.webkit.messageHandlers.\(Self.openLinkMessageName).postMessage(url.href);
        }, true);
        // Default WebKit menu actions do not dispatch DOM clicks. Capture only
        // trusted main-frame context data, synchronously, in this isolated world.
        // Native willOpenMenu consumes it; the data never authorizes navigation.
        (function () {
            var context = null;
            window.__md2TakeContextMenu = function () {
                var captured = context; context = null;
                if (!captured || !captured.target.isConnected
                    || document.elementFromPoint(captured.x, captured.y) !== captured.target) { return null; }
                return { page: captured.page, link: captured.link, image: captured.image,
                         x: captured.x, y: captured.y };
            };
            document.addEventListener('contextmenu', function (event) {
                if (!event.isTrusted) { return; }
                context = null;
                if (event.defaultPrevented) { return; }
                var target = event.target;
                var link = target && target.closest ? target.closest('a') : null;
                var image = target && target.closest ? target.closest('img') : null;
                function absolute(source) {
                    if (!source) { return null; }
                    try { return new URL(source, document.baseURI).href; } catch (_) { return null; }
                }
                context = {
                    target: target, x: event.clientX, y: event.clientY,
                    page: location.href,
                    link: absolute(link && (link.getAttribute('href') || link.getAttributeNS('http://www.w3.org/1999/xlink', 'href'))),
                    image: absolute(image && (image.currentSrc || image.getAttribute('src')))
                };
            }, true);
        })();
        document.addEventListener('dblclick', function(event) {
            if (event.isTrusted && event.metaKey) {
                window.webkit.messageHandlers.\(Self.enterEditMessageName).postMessage(null);
            }
        });
        // Task checkboxes are the preview's one interactive element: the click
        // toggles the box optimistically, and native rewrites the source line
        // (the re-render that follows is the authoritative state). The line only
        // means something in the source this page was rendered from, so the
        // revision native labelled the page with goes along.
        document.addEventListener('click', function (event) {
            if (!event.isTrusted) { return; }
            var box = event.target;
            if (!box || box.tagName !== 'INPUT' || !box.hasAttribute('data-md2-task-line')) { return; }
            var line = parseInt(box.getAttribute('data-md2-task-line'), 10);
            if (isNaN(line)) { return; }
            window.webkit.messageHandlers.\(Self.toggleTaskMessageName).postMessage({
                line: line,
                checked: !!box.checked,
                revision: window.\(Self.sourceLineRevisionVariable)
            });
        });
        // A gutter number asks native to select the line it shows in the
        // editor. Only the gutter layer's own spans count, and the second click
        // of a double click is not a second request.
        document.addEventListener('click', function (event) {
            if (!event.isTrusted || event.button !== 0 || event.detail > 1) { return; }
            var target = event.target;
            var span = target && target.closest ? target.closest('main > .md2-line-gutter > span[data-md2-gutter]') : null;
            if (!span) { return; }
            var line = parseInt(span.getAttribute('data-md2-gutter'), 10);
            if (isNaN(line) || line < 1) { return; }
            event.preventDefault();
            window.webkit.messageHandlers.\(Self.revealSourceLineMessageName).postMessage({ line: line });
        });
    """

    /// The isolated world's name for the page's source-line revision. A global
    /// there is out of reach of page script, unlike anything in the DOM.
    private static let sourceLineRevisionVariable = "__md2SourceLineRevision"

    /// Puts every task box back to the state its page was rendered with, which
    /// the `checked` attribute keeps. All of them, because a refused click's
    /// line may by now name another box, and because any box the source
    /// disagrees with has a re-render on the way. A live update will not do it:
    /// a kept block keeps its box, flipped.
    private static let restoreTaskBoxesScript = """
        document.querySelectorAll('input[data-md2-task-line]').forEach(function (box) {
            box.checked = box.defaultChecked;
        });
        true;
    """

    /// Replaces an `<img>` that failed to load with a placeholder naming it. Only
    /// the preview gets this, never the shared rendered HTML, so exported PDFs
    /// and prints are unaffected.
    ///
    /// One capture-phase listener serves the whole page, because error events do
    /// not bubble and a delegated listener outlives the live updates that replace
    /// individual `<img>` nodes. It has to be in place at document start: the
    /// page's policy refuses a missing local image during parsing, and even a
    /// failure from a scheme handler usually lands while the engine scripts
    /// still hold up document end.
    private var brokenImageScript: String {
        """
        window.addEventListener('error', function (event) {
            var img = event.target;
            if (!img || img.tagName !== 'IMG') { return; }
            if (img.getAttribute('data-md2-broken') === '1') { return; }
            var src = img.getAttribute('src') || '';
            var lower = src.trim().toLowerCase();
            var labelText = '\(Self.escapeForJS(genericImageLoadFailedLabel))';
            if (/^https?:/.test(lower)) {
                labelText = window.__md2RemoteImagesAllowed
                    ? '\(Self.escapeForJS(remoteImageUnavailableLabel))'
                    : '\(Self.escapeForJS(remoteImageBlockedLabel))';
            } else if (/^(file|md2-local-image):/.test(lower) || !/^[a-z][a-z0-9+.-]*:/.test(lower)) {
                labelText = '\(Self.escapeForJS(localImageMissingLabel))';
            }
            var placeholder = document.createElement('span');
            placeholder.className = 'md2-broken-image';
            placeholder.setAttribute('data-md2-broken', '1');
            var label = document.createElement('span');
            label.textContent = labelText;
            var path = document.createElement('span');
            path.className = 'md2-broken-image-path';
            // textContent (never innerHTML) so a hostile/odd path is inert.
            path.textContent = src;
            placeholder.appendChild(label);
            placeholder.appendChild(document.createTextNode(' '));
            placeholder.appendChild(path);
            if (img.parentNode) {
                img.parentNode.replaceChild(placeholder, img);
            }
        }, true);
        """
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        context.coordinator.documentLoader.install(on: configuration)

        // Forward Cmd+double-click in the rendered page back to native so the
        // surrounding view can switch into edit mode. Also report the heading at
        // the top of the viewport (debounced) so a mode switch can anchor to it,
        // and expose reflow-resilient scroll helpers the native side invokes
        // after a mode switch.
        let source = """
        var lastUserScrollIntentAt = 0;
        function markUserScrollIntent() {
            lastUserScrollIntentAt = Date.now();
        }
        window.addEventListener('wheel', markUserScrollIntent, { passive: true });
        window.addEventListener('touchmove', markUserScrollIntent, { passive: true });
        window.addEventListener('mousedown', markUserScrollIntent, { passive: true });
        window.addEventListener('keydown', function(event) {
            var keys = ['ArrowUp', 'ArrowDown', 'PageUp', 'PageDown', 'Home', 'End', ' '];
            if (keys.indexOf(event.key) >= 0) { markUserScrollIntent(); }
        }, true);
        (function () {
            var style = document.createElement('style');
            style.textContent = 'html.md2-hide-front-matter .front-matter{display:none!important;}';
            document.head.appendChild(style);
            window.__md2SetFrontMatterVisible = function (visible) {
                document.documentElement.classList.toggle('md2-hide-front-matter', !visible);
            };
            window.__md2SetFrontMatterVisible(\(Self.jsBoolean(showsFrontMatter)));
        })();
        \(Self.lineNumberGutterScript(showsLineNumbers: showsLineNumbers))
        (function () {
            // Suppress anchor reporting while we are programmatically scrolling,
            // so a mode-switch scroll is never captured back as the user's anchor.
            var suppressUntil = 0;
            // Vertical band below the viewport top sampled for the block the
            // user is reading: small enough to track the top of the viewport,
            // large enough to bridge the margins between blocks.
            var ANCHOR_BAND = 64;

            // The section heading at/above the top of the viewport — kept as
            // the compatibility fallback when block metadata cannot resolve.
            // Headings just under the top edge also count, otherwise we would
            // report the previous section.
            function headingAtTop() {
                var headings = document.querySelectorAll('h1,h2,h3,h4,h5,h6');
                var zone = Math.max(120, window.innerHeight * 0.25);
                var id = null;
                for (var i = 0; i < headings.length; i++) {
                    if (!headings[i].id) { continue; }
                    var top = headings[i].getBoundingClientRect().top;
                    if (top <= zone) {
                        id = headings[i].id;
                    } else {
                        break;
                    }
                }
                return id;
            }

            // Captures the viewport-context anchor: the deepest rendered block
            // (carrying data-md2-source-line) whose top sits at/above a small
            // band below the viewport top, plus intra-block progress and the
            // heading/fraction fallbacks.
            function captureAnchor() {
                var bandY = Math.min(ANCHOR_BAND, window.innerHeight * 0.25);
                var max = document.documentElement.scrollHeight - window.innerHeight;
                var fraction = max > 0 ? Math.min(1, Math.max(0, window.scrollY / max)) : 0;
                var anchor = {
                    line: null, endLine: null, progress: 0, inset: 0,
                    fraction: fraction, id: headingAtTop(),
                    user: Date.now() - lastUserScrollIntentAt < 1200
                };

                var nodes = document.querySelectorAll('[data-md2-source-line]');
                var best = null;
                var bestRect = null;
                for (var i = 0; i < nodes.length; i++) {
                    var rect = nodes[i].getBoundingClientRect();
                    if (rect.height <= 0) { continue; }
                    // The last element in document order starting at/above the
                    // band is the deepest block containing the viewport top.
                    if (rect.top <= bandY) { best = nodes[i]; bestRect = rect; }
                }
                if (!best) { return anchor; }

                var start = parseInt(best.getAttribute('data-md2-source-line'), 10);
                if (isNaN(start)) { return anchor; }
                var endAttr = best.getAttribute('data-md2-source-end-line');
                var end = endAttr ? parseInt(endAttr, 10) : start;
                var progress = bestRect.height > 0
                    ? (bandY - bestRect.top) / bestRect.height
                    : 0;
                anchor.line = start;
                anchor.endLine = isNaN(end) ? start : end;
                anchor.progress = Math.min(1, Math.max(0, progress));
                anchor.inset = Math.max(0, bestRect.top);
                return anchor;
            }
            window.__md2CaptureAnchor = captureAnchor;

            function topAnchor() {
                if (Date.now() < suppressUntil) { return; }
                if (window.__md2FindActive) { return; }
                window.webkit.messageHandlers.\(Self.anchorMessageName).postMessage(captureAnchor());
            }
            var pending = false;
            window.addEventListener('scroll', function () {
                if (pending) { return; }
                pending = true;
                setTimeout(function () { pending = false; topAnchor(); }, 80);
            }, { passive: true });
            window.addEventListener('load', topAnchor);

            // Keeps the viewport pinned to a target while the document is still
            // reflowing. Async KaTeX/Mermaid/diagram rendering settles over a
            // second or two after load. `getTargetY` returns the absolute Y the
            // viewport should scroll to (or null if not measurable yet). We only
            // re-scroll when that target actually MOVES — i.e. when content above
            // the anchor reflows. Content below the anchor changing the total
            // height does not move the target, so we don't scroll (avoiding a
            // pointless late jump). We stop on a user scroll or once stable.
            function keepPinned(getTargetY, silent) {
                // A recent click inside the preview is not evidence that this
                // programmatic jump was a user scroll. Only gestures that occur
                // after pinning starts may mark its final anchor as user driven.
                lastUserScrollIntentAt = 0;
                suppressUntil = Date.now() + 2600;
                var cancelled = false;
                function onUser() { cancelled = true; }
                // Fast-path cancels for common gestures; the scrollY check below
                // is the robust catch-all (covers scrollbar drags, etc.).
                window.addEventListener('wheel', onUser, { passive: true, once: true });
                window.addEventListener('keydown', onUser, { once: true });
                window.addEventListener('touchmove', onUser, { passive: true, once: true });

                var lastTargetY = null;
                var expectedY = 0;
                var started = false;
                var stableFrames = 0;
                var start = Date.now();
                function done() {
                    cancelled = true;
                    suppressUntil = 0;
                    // Report the final resting position so the captured anchor
                    // reflects where we actually landed (e.g. after an outline
                    // click programmatically scrolled the preview). A *silent*
                    // pin (the live-edit content swap) must NOT report: the edit
                    // originated in the editor, so a settle-time report here would
                    // drive the editor pane and yank it away from the caret.
                    if (!silent) { topAnchor(); }
                }
                function step() {
                    if (cancelled) { return; }
                    if (started && Math.abs(window.scrollY - expectedY) > 2) {
                        // Scroll position changed but we didn't move it: the user
                        // scrolled. Yield and stop re-anchoring.
                        done();
                        return;
                    }
                    var targetY = getTargetY();
                    if (targetY !== null && (lastTargetY === null || Math.abs(targetY - lastTargetY) > 1)) {
                        // First positioning, or the anchor moved (content above
                        // reflowed): scroll to it.
                        lastTargetY = targetY;
                        stableFrames = 0;
                        var maxY = document.documentElement.scrollHeight - window.innerHeight;
                        window.scrollTo(0, Math.min(Math.max(0, targetY), Math.max(0, maxY)));
                        expectedY = window.scrollY;
                        started = true;
                    } else {
                        stableFrames++;
                    }
                    if (stableFrames < 8 && (Date.now() - start) < 2500) {
                        requestAnimationFrame(step);
                    } else {
                        done();
                    }
                }
                // Explicit navigation must not wait for a paint. WebKit can
                // suspend animation frames in a background or unpresented page;
                // position once now, then track later reflow with the same RAF loop.
                step();
            }

            window.__md2ScrollToHeading = function (id) {
                keepPinned(function () {
                    var el = document.getElementById(id);
                    if (!el) { return null; }
                    // Absolute document Y of the element's top.
                    return el.getBoundingClientRect().top + window.scrollY;
                });
            };
            window.__md2ScrollToFraction = function (f) {
                var pinned = false;
                keepPinned(function () {
                    // Fraction maps to total height, which keeps changing as the
                    // page renders; pin once to avoid chasing it.
                    if (pinned) { return null; }
                    pinned = true;
                    var max = document.documentElement.scrollHeight - window.innerHeight;
                    return max > 0 ? max * f : 0;
                });
            };

            // Absolute document Y for a 1-based source line: the deepest block
            // whose span starts at/above the line, advanced by the line's
            // position within the block's span, minus a small inset so the
            // target never sits flush against the top edge. Returns null when
            // no block metadata resolves (caller falls back to heading/fraction).
            function sourceLineTargetY(line) {
                if (!line || line < 1) { return null; }
                var nodes = document.querySelectorAll('[data-md2-source-line]');
                var best = null;
                var bestRect = null;
                var bestStart = -1;
                for (var i = 0; i < nodes.length; i++) {
                    var start = parseInt(nodes[i].getAttribute('data-md2-source-line'), 10);
                    if (isNaN(start) || start > line) { continue; }
                    var rect = nodes[i].getBoundingClientRect();
                    if (rect.height <= 0 && rect.width <= 0) { continue; }
                    // Later elements in document order win ties so the deepest
                    // nested block (e.g. a paragraph in a blockquote) is chosen.
                    if (start >= bestStart) { best = nodes[i]; bestRect = rect; bestStart = start; }
                }
                if (!best) { return null; }
                if (line <= 1) { return 0; }
                var endAttr = best.getAttribute('data-md2-source-end-line');
                var end = endAttr ? parseInt(endAttr, 10) : bestStart;
                var offset = 0;
                if (!isNaN(end) && end > bestStart && line > bestStart) {
                    offset = Math.min(1, (line - bestStart) / (end - bestStart)) * bestRect.height;
                }
                var inset = 20;
                return Math.max(0, bestRect.top + window.scrollY + offset - inset);
            }

            // Mode-switch destination: land on the block containing the target
            // source line, with heading and proportional-fraction fallbacks.
            // The block target is re-resolved on every pinning frame so async
            // math/diagram reflow above it is tracked; the fraction fallback
            // pins once because it chases the still-changing total height.
            window.__md2ScrollToViewportAnchor = function (payload, silent) {
                var fractionPinned = false;
                keepPinned(function () {
                    var targetY = sourceLineTargetY(payload.line);
                    if (targetY !== null) { return targetY; }
                    if (payload.headingId) {
                        var el = document.getElementById(payload.headingId);
                        if (el) { return el.getBoundingClientRect().top + window.scrollY; }
                    }
                    if (fractionPinned) { return null; }
                    fractionPinned = true;
                    var max = document.documentElement.scrollHeight - window.innerHeight;
                    var f = Math.min(1, Math.max(0, payload.fraction || 0));
                    return max > 0 ? max * f : 0;
                }, silent);
            };

            // Continuous Side by Side follow: scroll directly to the rendered
            // position of a (possibly fractional) source line, WITHOUT the
            // keepPinned settle loop or its multi-second suppression, so the
            // preview tracks the editor's drag smoothly instead of snapping
            // between block tops. A fractional line interpolates inside the
            // block via sourceLineTargetY's intra-block offset. A brief
            // suppression keeps the resulting scroll from echoing back as a user
            // anchor while the editor is the active driver.
            window.__md2FollowToAnchor = function (line) {
                var targetY = sourceLineTargetY(line);
                if (targetY === null) { return; }
                var maxY = document.documentElement.scrollHeight - window.innerHeight;
                suppressUntil = Date.now() + 200;
                window.scrollTo(0, Math.min(Math.max(0, targetY), Math.max(0, maxY)));
            };

            // Side by Side edit-follow: while the user types, keep the rendered
            // output of the caret's source line in view WITHOUT disturbing the
            // preview when that line is already on screen. Only when the line has
            // scrolled off the top or below the fold do we move, placing it in the
            // lower-middle of the viewport so freshly typed content is revealed
            // with its preceding context still visible. Suppressed briefly so this
            // scroll does not echo back as a user anchor while the editor drives.
            window.__md2FollowEditLine = function (line) {
                var targetY = sourceLineTargetY(line);
                if (targetY === null) { return; }
                var viewportH = window.innerHeight;
                var scrollTop = window.scrollY;
                var topMargin = viewportH * 0.12;
                var bottomMargin = viewportH * 0.18;
                // Already comfortably visible: leave the preview untouched.
                if (targetY >= scrollTop + topMargin
                    && targetY <= scrollTop + viewportH - bottomMargin) {
                    return;
                }
                var maxY = document.documentElement.scrollHeight - viewportH;
                var desired = targetY - viewportH * 0.62;
                suppressUntil = Date.now() + 200;
                window.scrollTo(0, Math.min(Math.max(0, desired), Math.max(0, maxY)));
            };

            // --- Live content update ---------------------------------------
            // Source-line metadata: inserting a line above a block changes
            // these values and nothing else in the block.
            var lineAttributes = ['data-md2-source-line', 'data-md2-source-end-line', 'data-md2-task-line'];
            var lineSelector = '[data-md2-source-line],[data-md2-source-end-line],[data-md2-task-line]';

            function isGutterLayer(node) {
                return node.nodeType === 1 && node.classList.contains('md2-line-gutter');
            }

            function isBlankText(node) {
                return node.nodeType === 3 && node.data.trim() === '';
            }

            // <main>'s rendered nodes, without the gutter layer.
            function contentNodes(main) {
                var nodes = [];
                for (var i = 0; i < main.childNodes.length; i++) {
                    if (!isGutterLayer(main.childNodes[i])) { nodes.push(main.childNodes[i]); }
                }
                return nodes;
            }

            function lineElements(node) {
                var elements = [];
                if (node.nodeType !== 1) { return elements; }
                if (node.matches(lineSelector)) { elements.push(node); }
                var inner = node.querySelectorAll(lineSelector);
                for (var i = 0; i < inner.length; i++) { elements.push(inner[i]); }
                return elements;
            }

            // A node's identity apart from where it sits in the source. An
            // element's line attributes are taken out of the DOM while it is
            // serialized, not cut from the string, so text that spells one of
            // them still counts.
            function contentKey(node) {
                if (node.nodeType === 3) { return '#text ' + node.data; }
                if (node.nodeType === 8) { return '#comment ' + node.data; }
                if (node.nodeType !== 1) { return '#node ' + node.nodeName; }
                var elements = lineElements(node);
                var saved = [];
                for (var i = 0; i < elements.length; i++) {
                    var values = [];
                    for (var a = 0; a < lineAttributes.length; a++) {
                        values.push(elements[i].getAttribute(lineAttributes[a]));
                        elements[i].removeAttribute(lineAttributes[a]);
                    }
                    saved.push(values);
                }
                var key = node.outerHTML;
                for (var j = 0; j < elements.length; j++) {
                    for (var b = 0; b < lineAttributes.length; b++) {
                        if (saved[j][b] !== null) { elements[j].setAttribute(lineAttributes[b], saved[j][b]); }
                    }
                }
                return key;
            }

            function parseContent(html) {
                var template = document.createElement('template');
                template.innerHTML = html;
                var nodes = Array.prototype.slice.call(template.content.childNodes);
                return nodes.map(function (node) { return { node: node, key: contentKey(node) }; });
            }

            // Rendering replaces what a formula or diagram node held when it
            // arrived, so an element's key is stored when it is inserted. Text
            // and comment nodes are never rendered and key themselves.
            function storedKey(node) {
                return node.nodeType === 1 ? node.__md2Key : contentKey(node);
            }

            // Gives a kept node the line attributes of its new copy, so the
            // gutter, anchors and task toggles follow the lines it moved to.
            // Rendering adds no element that carries them, so the elements pair
            // up in document order; when they do not, the node is replaced.
            function adoptLines(kept, fresh) {
                var to = lineElements(kept);
                var from = lineElements(fresh);
                if (to.length !== from.length) { return false; }
                for (var i = 0; i < to.length; i++) {
                    for (var a = 0; a < lineAttributes.length; a++) {
                        var value = from[i].getAttribute(lineAttributes[a]);
                        if (value === null) {
                            to[i].removeAttribute(lineAttributes[a]);
                        } else if (to[i].getAttribute(lineAttributes[a]) !== value) {
                            to[i].setAttribute(lineAttributes[a], value);
                        }
                    }
                }
                return true;
            }

            // A full page load rendered its formulas and diagrams before any
            // key could be stored, so the first update keys those nodes from
            // the body the page was loaded with. <main>'s own markup adds a line
            // break before and after the body; anything else that does not pair
            // up leaves the nodes unkeyed, and the update replaces them all.
            function keyLoadedContent(main, loadedHTML) {
                var nodes = contentNodes(main);
                // Keys from a body that is no longer on the page would match
                // stale nodes.
                for (var s = 0; s < nodes.length; s++) {
                    if (nodes[s].nodeType === 1 && nodes[s].__md2Key !== undefined) { return; }
                }
                while (nodes.length && isBlankText(nodes[0])) { main.removeChild(nodes.shift()); }
                while (nodes.length && isBlankText(nodes[nodes.length - 1])) { main.removeChild(nodes.pop()); }
                var loaded = parseContent(loadedHTML);
                if (loaded.length !== nodes.length) { return; }
                for (var i = 0; i < nodes.length; i++) {
                    var node = nodes[i], copy = loaded[i].node;
                    if (node.nodeType !== copy.nodeType || node.nodeName !== copy.nodeName) { return; }
                    if (node.nodeType !== 1 && contentKey(node) !== loaded[i].key) { return; }
                }
                for (var j = 0; j < nodes.length; j++) {
                    if (nodes[j].nodeType === 1) { nodes[j].__md2Key = loaded[j].key; }
                }
            }

            // Puts `incoming` into <main>, keeping every node whose key is
            // unchanged: the common prefix and suffix stay where they are, and
            // in the range between them an old node is reused for the first new
            // node with its key. Returns the elements inserted, which are the
            // only ones that still need rendering.
            function updateContent(main, incoming, replaceAll) {
                var old = contentNodes(main);
                var oldKeys = [];
                for (var i = 0; i < old.length && !replaceAll; i++) {
                    oldKeys.push(storedKey(old[i]));
                    if (oldKeys[i] === undefined) { replaceAll = true; }
                }
                var gutter = null;
                for (var g = 0; g < main.childNodes.length; g++) {
                    if (isGutterLayer(main.childNodes[g])) { gutter = main.childNodes[g]; }
                }
                var inserted = [];
                function fresh(item) {
                    if (item.node.nodeType === 1) {
                        item.node.__md2Key = item.key;
                        inserted.push(item.node);
                    }
                    return item.node;
                }

                if (replaceAll) {
                    for (var r = 0; r < old.length; r++) { main.removeChild(old[r]); }
                    for (var n = 0; n < incoming.length; n++) { main.insertBefore(fresh(incoming[n]), gutter); }
                    return { inserted: inserted, kept: 0, replacedAll: true };
                }

                var start = 0;
                while (start < old.length && start < incoming.length
                       && oldKeys[start] === incoming[start].key
                       && adoptLines(old[start], incoming[start].node)) {
                    start++;
                }
                var oldEnd = old.length, newEnd = incoming.length;
                while (oldEnd > start && newEnd > start
                       && oldKeys[oldEnd - 1] === incoming[newEnd - 1].key
                       && adoptLines(old[oldEnd - 1], incoming[newEnd - 1].node)) {
                    oldEnd--;
                    newEnd--;
                }

                var pool = new Map();
                for (var p = start; p < oldEnd; p++) {
                    if (!pool.has(oldKeys[p])) { pool.set(oldKeys[p], []); }
                    pool.get(oldKeys[p]).push(old[p]);
                }
                var placed = [];
                for (var m = start; m < newEnd; m++) {
                    var candidates = pool.get(incoming[m].key);
                    var node = null;
                    while (!node && candidates && candidates.length) {
                        var candidate = candidates.shift();
                        if (adoptLines(candidate, incoming[m].node)) { node = candidate; }
                    }
                    placed.push(node || fresh(incoming[m]));
                }
                var used = new Set(placed);
                var removed = 0;
                for (var d = start; d < oldEnd; d++) {
                    if (!used.has(old[d])) {
                        main.removeChild(old[d]);
                        removed++;
                    }
                }
                // Only a node that is out of place moves, so kept nodes keep
                // their rendered content and their own scroll positions.
                var previous = start > 0 ? old[start - 1] : null;
                for (var k = 0; k < placed.length; k++) {
                    var expected = previous ? previous.nextSibling : main.firstChild;
                    if (placed[k] !== expected) { main.insertBefore(placed[k], expected); }
                    previous = placed[k];
                }
                return { inserted: inserted, kept: old.length - removed, replacedAll: false };
            }

            // Live preview content update, in place (without reloading the
            // page). Because the page shell and scroll node are never torn
            // down, the viewport's scroll position is preserved across edits.
            // Blocks that did not change stay in the page with their rendered
            // math, diagrams and images; only inserted blocks are rendered.
            // The native side only routes an update through here when no new
            // diagram engine is required (otherwise it does a full reload that
            // rebuilds <head>), so the render hooks below exist whenever there
            // is content to render.
            //
            // `options.macros` is the document's math-macros map;
            // `options.loaded` is the body the page was loaded with, sent with
            // the first update after a load. Returns what changed, for tests.
            window.__md2ApplyContent = function (bodyHTML, options) {
                var main = document.querySelector('main');
                if (!main) { return null; }
                options = options || {};
                if (window.__md2FindClear) { window.__md2FindClear(); }
                var macrosChanged = !!(options.macros && window.__md2SetMathMacros
                    && window.__md2SetMathMacros(options.macros));
                if (typeof options.loaded === 'string') { keyLoadedContent(main, options.loaded); }
                // Kept diagrams were drawn for the appearance of their render.
                var dark = !!(window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches);
                var appearanceChanged = typeof window.__md2DiagramDark === 'boolean'
                    && window.__md2DiagramDark !== dark;

                var result = updateContent(main, parseContent(bodyHTML), appearanceChanged);
                if (window.__md2RenderMath) {
                    if (macrosChanged || result.replacedAll) {
                        window.__md2RenderMath(main);
                    } else {
                        window.__md2RenderMathIn(result.inserted, main);
                    }
                }
                if (window.__md2RenderDiagrams) { window.__md2RenderDiagrams(result.inserted); }
                // Math and diagrams settle later; the gutter's ResizeObserver
                // picks up the resulting height changes.
                if (window.__md2RenderLineNumbers) { window.__md2RenderLineNumbers(); }
                return {
                    inserted: result.inserted.length,
                    kept: result.kept,
                    replacedAll: result.replacedAll,
                    macrosChanged: macrosChanged
                };
            };

            \(PreviewTextSearch.script)

            // --- Broken image diagnostics (preview only) ------------------
            // The placeholder's look; `brokenImageScript` puts it in the page.
            (function () {
                var style = document.createElement('style');
                style.textContent =
                    '.md2-broken-image{display:inline-flex;align-items:baseline;gap:.4em;' +
                    'max-width:100%;box-sizing:border-box;padding:.45em .7em;margin:1.1em auto;' +
                    'border:1px dashed var(--border,#d8dee4);border-radius:6px;' +
                    'background:var(--code-bg,#f6f8fa);color:var(--muted,#6b7280);' +
                    'font:13px/1.5 -apple-system,BlinkMacSystemFont,sans-serif;}' +
                    '.md2-broken-image .md2-broken-image-path{font-family:ui-monospace,' +
                    'SFMono-Regular,Menlo,monospace;word-break:break-all;color:var(--text,#1f2328);}';
                document.head.appendChild(style);
            })();
        })();
        """
        let userScript = WKUserScript(
            source: source,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        configuration.userContentController.addUserScript(userScript)
        configuration.userContentController.addUserScript(WKUserScript(
            source: brokenImageScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        Self.installInteractionBridge(on: configuration.userContentController, handler: context.coordinator)
        configuration.userContentController.add(context.coordinator, name: Self.anchorMessageName)
        configuration.userContentController.add(context.coordinator, contentWorld: .defaultClient, name: Self.selectionMessageName)
        configuration.userContentController.addUserScript(WKUserScript(source: Self.selectionScript,
            injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))

        let webView = PreviewWebView(frame: .zero, configuration: configuration)
        context.coordinator.attachFindHost(webView)
        webView.onFindAction = { action in
            context.coordinator.onFindShortcut(action)
        }
        webView.onEscape = onEscape
        webView.contextMenuAdapter.open = { [weak coordinator = context.coordinator] url in
            guard let coordinator else { return }
            coordinator.dispatch(PreviewLinkRouter.route(for: url, documentPageURL: coordinator.documentLoader.documentPageURL))
        }
        webView.contextMenuAdapter.resolveImage = { [weak coordinator = context.coordinator] url in
            coordinator?.documentLoader.originalImageURL(for: url)
        }
        // The link policy below never lets the page navigate away from the
        // document, so there is no history for a swipe to traverse.
        webView.allowsBackForwardNavigationGestures = false
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")

        let coordinator = context.coordinator
        onRegisterResourceInvalidator { [weak webView, weak coordinator] in
            guard let webView, let coordinator else { return }
            coordinator.invalidateResourceContext(in: webView)
        }
        viewportReader?.capture = { [weak webView, weak coordinator] completion in
            guard let webView, let coordinator else {
                completion(nil)
                return
            }
            coordinator.captureAnchor(in: webView, completion: completion)
        }
        viewportReader?.follow = { [weak webView, weak coordinator] line in
            guard let webView, let coordinator, coordinator.isLoaded else { return }
            webView.evaluateJavaScript(
                String(format: "window.__md2FollowToAnchor ? window.__md2FollowToAnchor(%.3f) : null;", line)
            )
        }
        viewportReader?.setEditFollow = { [weak coordinator] line in
            guard let coordinator else { return }
            coordinator.editFollowLine = line
            coordinator.editFollowDeadline = line == nil
                ? .distantPast
                : Date().addingTimeInterval(Coordinator.editFollowWindow)
        }

        return webView
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.invalidateResourceContext(in: webView)
        coordinator.detachFindHost(webView)
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onSelectionChange = onSelectionChange
        if context.coordinator.typography != typography {
            context.coordinator.typography = typography
            if context.coordinator.isLoaded { context.coordinator.applyTypography(in: webView, preservingAnchor: true) }
        }
        context.coordinator.onEnterEdit = onEnterEdit
        context.coordinator.onToggleTask = onToggleTask
        context.coordinator.onRevealSourceLine = onRevealSourceLine
        context.coordinator.onOpenMarkdownLink = onOpenMarkdownLink
        context.coordinator.onMissingLocalLink = onMissingLocalLink
        context.coordinator.onOpenWithSystem = onOpenWithSystem
        context.coordinator.onAnchorChange = onAnchorChange
        context.coordinator.onFindShortcut = onFindShortcut
        context.coordinator.onFindResult = onFindResult
        context.coordinator.onFindUnavailable = onFindUnavailable
        context.coordinator.showsFrontMatter = showsFrontMatter
        context.coordinator.showsLineNumbers = showsLineNumbers
        context.coordinator.sourceLineRevision = sourceLineRevision

        if let previewWebView = webView as? PreviewWebView {
            previewWebView.onFindAction = { action in
                context.coordinator.onFindShortcut(action)
            }
            previewWebView.onEscape = onEscape
        }

        let coordinator = context.coordinator
        viewportReader?.capture = { [weak webView, weak coordinator] completion in
            guard let webView, let coordinator else {
                completion(nil)
                return
            }
            coordinator.captureAnchor(in: webView, completion: completion)
        }
        viewportReader?.follow = { [weak webView, weak coordinator] line in
            guard let webView, let coordinator, coordinator.isLoaded else { return }
            webView.evaluateJavaScript(
                String(format: "window.__md2FollowToAnchor ? window.__md2FollowToAnchor(%.3f) : null;", line)
            )
        }
        viewportReader?.setEditFollow = { [weak coordinator] line in
            guard let coordinator else { return }
            coordinator.editFollowLine = line
            coordinator.editFollowDeadline = line == nil
                ? .distantPast
                : Date().addingTimeInterval(Coordinator.editFollowWindow)
        }

        let htmlChanged = context.coordinator.lastHTML != html
        let baseURLChanged = context.coordinator.lastBaseURL != baseURL
        let resourceContextChanged = context.coordinator.remoteResourcePolicy != remoteResourcePolicy
            || context.coordinator.remoteResourceContextToken != remoteResourceContextToken
        if resourceContextChanged {
            context.coordinator.invalidateResourceContext(in: webView)
            context.coordinator.remoteResourcePolicy = remoteResourcePolicy
            context.coordinator.remoteResourceContextToken = remoteResourceContextToken
            context.coordinator.resourceContextIsActive = true
        }
        guard context.coordinator.resourceContextIsActive else { return }
        context.coordinator.applyFrontMatterVisibility(in: webView)
        context.coordinator.applyLineNumbersVisibility(in: webView)
        if htmlChanged || baseURLChanged || resourceContextChanged {
            // In Side by Side mode, a content-only change (same document, no new
            // diagram engine needed) is applied in place so typing does not
            // reload the page or reset the preview's scroll. Everything else —
            // the initial load, a base-URL/document change, or a new diagram
            // engine that must be loaded — goes through a full load.
            let isLoadedContentUpdate = liveUpdate
                && context.coordinator.isLoaded
                && !baseURLChanged
                && !resourceContextChanged
                && !context.coordinator.lastHTML.isEmpty
            let canLiveUpdate = liveUpdate
                && context.coordinator.isLoaded
                && !baseURLChanged
                && !resourceContextChanged
                && !context.coordinator.lastHTML.isEmpty
                && !Self.requiresNewEngine(newBody: bodyHTML, loadedBody: context.coordinator.lastBody)
            context.coordinator.lastHTML = html
            context.coordinator.lastBody = bodyHTML
            context.coordinator.lastBaseURL = baseURL
            context.coordinator.lastFindQuery = nil

            if canLiveUpdate {
                context.coordinator.applyLiveContent(bodyHTML, mathMacros: mathMacros, in: webView)
            } else {
                if isLoadedContentUpdate {
                    context.coordinator.suppressNextAnchorMessage()
                }
                context.coordinator.beginLoading()
                context.coordinator.loadedBody = bodyHTML
                // Load with the pending heading as a URL fragment so WebKit scrolls
                // to it natively during parsing. This is the only thing that can
                // position the page before the external diagram/math engine scripts
                // finish executing. Bundled scripts use stable, cacheable URLs;
                // their first execution can still block JavaScript. A
                // viewport anchor's fallback heading gives the same early, coarse
                // position; the block/source-line target then refines it.
                load(
                    html,
                    baseURL: baseURL,
                    fragment: jumpAnchor?.fallbackHeadingID ?? jumpHeadingID,
                    in: webView,
                    coordinator: context.coordinator
                )
            }
        } else {
            // Text that renders to the same page is still a new revision.
            context.coordinator.labelPage(in: webView)
        }

        // Anchor/heading/fraction targets are also applied once the page has
        // finished loading, which re-affirms the position after async rendering
        // reflows the layout. On a fresh mode switch the web view is still
        // loading when the binding arrives, so the coordinator holds the target
        // and applies it on `didFinish`; if already loaded it applies immediately.
        let scrollRequest = jumpAnchor.map(ModeSwitchAnchor.viewport)
            ?? jumpHeadingID.map { .heading(id: $0) }
            ?? jumpFraction.map(ModeSwitchAnchor.fraction)
        if let scrollRequest, context.coordinator.lastScrollRequest != scrollRequest {
            context.coordinator.lastScrollRequest = scrollRequest
            context.coordinator.setPendingScroll(scrollRequest, in: webView)
            let anchor = jumpAnchor, heading = jumpHeadingID, fraction = jumpFraction
            DispatchQueue.main.async {
                // Consume after SwiftUI's update, and never erase a newer jump.
                guard self.jumpAnchor == anchor, self.jumpHeadingID == heading, self.jumpFraction == fraction else { return }
                self.jumpAnchor = nil
                self.jumpHeadingID = nil
                self.jumpFraction = nil
            }
        } else if scrollRequest == nil {
            context.coordinator.lastScrollRequest = nil
        }

        if context.coordinator.lastFindQuery != findQuery || context.coordinator.findOptions != findOptions {
            context.coordinator.findOptions = findOptions
            context.coordinator.lastFindQuery = findQuery
            context.coordinator.runFindWhenReady(findQuery, in: webView)
        }

        // Consume by token rather than clearing the binding here: mutating an
        // observed binding inside `updateNSView` is not reliably visible to the
        // next pass, so `self.findNavigation = nil` can be re-read as non-nil on a
        // follow-up update and replay the navigation indefinitely.
        if let navigation = findNavigation,
           context.coordinator.lastFindNavigationToken != navigation.token {
            context.coordinator.lastFindNavigationToken = navigation.token
            context.coordinator.handleFindNavigation(navigation.action, in: webView)
        }

        context.coordinator.updateFocusRequest(focusToken, state: focusState, in: webView)
    }

    /// Whether `newBody` needs a diagram engine that the currently-loaded page
    /// (built from `loadedBody`) has not loaded. Diagram engine scripts
    /// are only included for the diagram kinds present at load, so
    /// a live in-place content swap cannot introduce a new kind; that case must
    /// fall back to a full reload. KaTeX is always loaded, so math never forces
    /// a reload.
    private static func requiresNewEngine(newBody: String, loadedBody: String) -> Bool {
        let kinds = [
            PreviewClass.diagramMermaid,
            PreviewClass.diagramFlow,
            PreviewClass.diagramSequence
        ]
        return kinds.contains { newBody.contains($0) && !loadedBody.contains($0) }
    }

    private static func escapeForJS(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "")
    }

    static func jsBoolean(_ value: Bool) -> String {
        value ? "true" : "false"
    }

    /// The preview-only line-number gutter: its styles plus the render entry
    /// points. Kept as its own unit so the GUI tests can inject exactly this code
    /// into an offscreen web view and drive the real implementation.
    ///
    /// Numbers come from the `data-md2-source-line` metadata every top-level block
    /// already carries, and every list item of a top-level list that spans more
    /// than one source line. This script is injected only into the preview web view,
    /// never into the shared rendered HTML, so exported PDFs, prints, and exported
    /// HTML are unaffected — the same contract the broken-image and front-matter
    /// rules rely on.
    static func lineNumberGutterScript(showsLineNumbers: Bool) -> String {
        """
        (function () {
            // The digits are CSS generated content, never text nodes: the preview's
            // find walks `document.body` text nodes, so real nodes here would be
            // matched by find and would be merged by `clearFind`'s normalize().
            var style = document.createElement('style');
            style.textContent =
                ':root{--md2-gutter-width:46px;}' +
                'main{position:relative;}' +
                '.md2-line-gutter{position:absolute;inset:0;pointer-events:none;display:none;}' +
                'html.md2-line-numbers .md2-line-gutter{display:block;}' +
                '.md2-line-gutter span{position:absolute;' +
                'left:max(clamp(28px,4vw,64px) - var(--md2-gutter-width),0px);' +
                'width:calc(var(--md2-gutter-width) - 8px);text-align:right;' +
                'font-size:0.78rem;line-height:1.25;color:var(--muted);' +
                'font-variant-numeric:tabular-nums;}' +
                '.md2-line-gutter span::before{content:attr(data-md2-gutter);}' +
                // The layer passes clicks through; its numbers take them, to
                // select their line in the editor (the isolated-world bridge).
                '.md2-line-gutter span{pointer-events:auto;cursor:pointer;}' +
                // Reserve the gutter by raising the column's own padding, so no
                // horizontal scrolling can appear. Gated on the switch class, so
                // with numbers off the base rules apply byte-identically. The media
                // query mirrors the renderer's own 720px breakpoint.
                'html.md2-line-numbers main{padding-left:max(clamp(28px,4vw,64px),var(--md2-gutter-width));}' +
                '@media (max-width:720px){html.md2-line-numbers main{padding-left:max(24px,var(--md2-gutter-width));}}';
            document.head.appendChild(style);

            var lineNumberObserver = null;
            var observedGutterBlocks = [];
            var lineNumberRenderScheduled = false;

            function scheduleLineNumberRender() {
                if (lineNumberRenderScheduled) { return; }
                lineNumberRenderScheduled = true;
                requestAnimationFrame(function () {
                    lineNumberRenderScheduled = false;
                    window.__md2RenderLineNumbers();
                });
            }

            function isGutterLayer(node) {
                return !!node.classList && node.classList.contains('md2-line-gutter');
            }

            function gutterLayerIn(main) {
                for (var i = 0; i < main.children.length; i++) {
                    if (isGutterLayer(main.children[i])) { return main.children[i]; }
                }
                return null;
            }

            // Eligible blocks are the *direct children* of <main> carrying
            // source-line metadata. A subtree query would also match footnote list
            // items — which carry the attribute too — and number them twice.
            function gutterBlocks(main) {
                var blocks = [];
                for (var i = 0; i < main.children.length; i++) {
                    var child = main.children[i];
                    if (isGutterLayer(child)) { continue; }
                    if (child.hasAttribute('data-md2-source-line')) { blocks.push(child); }
                }
                return blocks;
            }

            function sameBlocks(a, b) {
                if (a.length !== b.length) { return false; }
                for (var i = 0; i < a.length; i++) {
                    if (a[i] !== b[i]) { return false; }
                }
                return true;
            }

            // Watch the blocks the numbers are positioned against, not just <main>:
            // math and diagrams settle asynchronously, and one block can grow while
            // another shrinks by the same amount, leaving <main>'s own box unchanged
            // while every number below the pair goes stale.
            //
            // Only a changed set of blocks is observed again. Observing delivers
            // a first notification, which schedules a render that lands back
            // here, so observing the same blocks on every render rebuilt the
            // gutter every frame.
            function observeGutterBlocks(blocks) {
                if (typeof ResizeObserver === 'undefined') { return; }
                if (!lineNumberObserver) {
                    lineNumberObserver = new ResizeObserver(scheduleLineNumberRender);
                }
                if (sameBlocks(observedGutterBlocks, blocks)) { return; }
                lineNumberObserver.disconnect();
                for (var i = 0; i < blocks.length; i++) {
                    lineNumberObserver.observe(blocks[i]);
                }
                observedGutterBlocks = blocks;
            }

            window.__md2RenderLineNumbers = function () {
                var main = document.querySelector('main');
                if (!main) { return 0; }
                if (!document.documentElement.classList.contains('md2-line-numbers')) { return 0; }

                var layer = gutterLayerIn(main);
                if (!layer) {
                    layer = document.createElement('div');
                    layer.className = 'md2-line-gutter';
                    layer.setAttribute('aria-hidden', 'true');
                    main.appendChild(layer);
                }
                while (layer.firstChild) { layer.removeChild(layer.firstChild); }

                var blocks = gutterBlocks(main);
                var mainTop = main.getBoundingClientRect().top;
                var numbers = [];
                var numberedLines = {};
                function addNumber(element) {
                    var rect = element.getBoundingClientRect();
                    // A hidden block reports a zero rect — the front-matter block is
                    // display:none when metadata is hidden, and numbering it would
                    // pin a garbage number at the top of the document.
                    if (rect.width === 0 && rect.height === 0) { return; }
                    var sourceLine = element.getAttribute('data-md2-source-line');
                    if (!sourceLine || numberedLines[sourceLine]) { return; }
                    numberedLines[sourceLine] = true;
                    // The layer is positioned against <main>'s padding box, so a
                    // viewport-relative difference is scroll-independent: numbers
                    // move with their content without a scroll listener.
                    numbers.push({ line: sourceLine, top: rect.top - mainTop });
                }
                for (var i = 0; i < blocks.length; i++) { addNumber(blocks[i]); }
                // A list item in a top-level list is numbered too when it spans
                // several source lines; one-line items would turn a long list
                // into a column of digits. Its first line is skipped when a block
                // number already shows it (a list's first item). Lists inside
                // quotes, alerts and footnotes stay unnumbered, like the other
                // blocks they hold, also when the quote or alert sits inside an
                // item.
                var items = main.querySelectorAll(
                    ':scope > ul li[data-md2-source-end-line], :scope > ol li[data-md2-source-end-line]'
                );
                for (var j = 0; j < items.length; j++) {
                    if (items[j].closest('blockquote, .markdown-alert')) { continue; }
                    addNumber(items[j]);
                }
                numbers.sort(function (a, b) { return a.top - b.top; });

                for (var k = 0; k < numbers.length; k++) {
                    var span = document.createElement('span');
                    span.setAttribute('data-md2-gutter', numbers[k].line);
                    span.style.top = numbers[k].top + 'px';
                    layer.appendChild(span);
                }

                observeGutterBlocks(blocks);
                return numbers.length;
            };

            window.__md2SetLineNumbersVisible = function (visible) {
                var on = !!visible;
                var changed = document.documentElement.classList.contains('md2-line-numbers') !== on;
                document.documentElement.classList.toggle('md2-line-numbers', on);
                // Only a real change needs a pass: `updateNSView` pushes this
                // value on every SwiftUI update, and rebuilding the layer each
                // time would add a redundant round trip per keystroke.
                if (on && changed) { window.__md2RenderLineNumbers(); }
            };

            window.addEventListener('resize', scheduleLineNumberRender);
            window.__md2SetLineNumbersVisible(\(jsBoolean(showsLineNumbers)));
        })();
        """
    }

    enum ImageFailureKind: Equatable {
        case local
        case remote
        case generic
    }

    static func imageFailureKind(for source: String) -> ImageFailureKind {
        let lower = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.hasPrefix("http:") || lower.hasPrefix("https:") {
            return .remote
        }
        if lower.hasPrefix("file:") || lower.hasPrefix("\(LocalImageSchemeHandler.scheme):") {
            return .local
        }
        if lower.range(of: #"^[a-z][a-z0-9+.-]*:"#, options: .regularExpression) != nil {
            return .generic
        }
        return .local
    }

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator()
        coordinator.focusState = focusState
        coordinator.typography = typography
        coordinator.onSelectionChange = onSelectionChange
        coordinator.onEnterEdit = onEnterEdit
        coordinator.onToggleTask = onToggleTask
        coordinator.onRevealSourceLine = onRevealSourceLine
        coordinator.onOpenMarkdownLink = onOpenMarkdownLink
        coordinator.onMissingLocalLink = onMissingLocalLink
        coordinator.onOpenWithSystem = onOpenWithSystem
        return coordinator
    }

    /// Preview and PDF export share the same memory page and resource boundary.
    private func load(_ html: String, baseURL: URL?, fragment: String?, in webView: WKWebView, coordinator: Coordinator) {
        (webView as? PreviewWebView)?.invalidateContextMenu()
        coordinator.documentLoader.load(html, baseURL: baseURL, fragment: fragment,
            remoteResourcePolicy: remoteResourcePolicy, in: webView)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
        var typography: TypographySettings = .init()
        var onSelectionChange: (String?) -> Void = { _ in }

        func applyTypography(in webView: WKWebView, preservingAnchor: Bool = false) {
            let css = String(data: try! JSONEncoder().encode(typography.previewCSS), encoding: .utf8)!
            webView.evaluateJavaScript("""
            (function () {
                var anchor = \(preservingAnchor ? "true" : "false") && window.__md2CaptureAnchor ? window.__md2CaptureAnchor() : null;
                var style = document.getElementById('md2-typography');
                if (!style) { style = document.createElement('style'); style.id = 'md2-typography'; document.head.appendChild(style); }
                style.textContent = \(css);
                if (anchor && window.__md2ScrollToViewportAnchor) { window.__md2ScrollToViewportAnchor(anchor); }
                window.dispatchEvent(new Event('resize'));
            })();
            """)
        }
        var lastHTML = ""
        /// The last `<main>` content applied (via full load or live swap), used
        /// to decide whether an update can be a live in-place swap.
        var lastBody = ""
        var lastBaseURL: URL?
        var remoteResourcePolicy: RemoteResourcePolicy = .blocked
        var remoteResourceContextToken: UUID?
        var resourceContextIsActive = true
        var focusState: PreviewFocusState?

        func invalidateResourceContext(in webView: WKWebView) {
            if resourceContextIsActive, !lastHTML.isEmpty {
                focusState?.preserveFocus(from: webView)
            }
            resourceContextIsActive = false
            beginLoading()
            documentLoader.invalidate(in: webView)
            (webView as? PreviewWebView)?.invalidateContextMenu()
        }
        var onEnterEdit: () -> Void = {}
        var onToggleTask: (
            _ line: Int, _ checked: Bool, _ revision: Int, _ restoreBoxes: @escaping () -> Void
        ) -> Void = { _, _, _, _ in }
        var onRevealSourceLine: (_ line: Int) -> Void = { _ in }
        var onOpenMarkdownLink: (_ url: URL) -> Void = { _ in }
        var onMissingLocalLink: (_ url: URL) -> Void = { _ in }
        var onOpenWithSystem: (_ url: URL) -> Void = { _ in }
        var onAnchorChange: (_ anchor: ViewportAnchor, _ isUserInitiated: Bool) -> Void = { _, _ in }
        var onFindShortcut: (_ action: FindCommand.Action) -> Void = { _ in }
        var onFindResult: (_ total: Int, _ index: Int) -> Void = { _, _ in }
        let documentLoader = WebDocumentLoader()
        var showsFrontMatter = true
        var showsLineNumbers = false
        /// The source-line revision of the content last handed to this view.
        var sourceLineRevision = 0
        /// The revision the page is labelled with; `nil` on a new page.
        private var pageRevision: Int?
        /// True from handing content over until it is in the page, while the
        /// page keeps the label of what it still shows.
        private var hasContentInFlight = false
        /// True from `beginLoading` until the page of that load commits. A page
        /// that finishes before then is one that load is about to replace.
        private var isAwaitingCommit = false
        var lastFindQuery: String?
        var findOptions = TextSearch.Options()
        private var findGeneration = UUID()
        private weak var findHost: WKWebView?
        private var findHostIsActive = true
        private var findInFlight = false
        var onFindUnavailable: (Bool) -> Void = { _ in }
        var lastFocusToken: UUID?

        func updateFocusRequest(_ token: UUID, state: PreviewFocusState?, in webView: WKWebView) {
            guard resourceContextIsActive, acceptsFindHost(webView) else { return }
            focusState = state
            let changed = lastFocusToken != token
            lastFocusToken = token
            let requested = changed && (state?.consume(token) ?? true)
            guard requested || state?.hasPendingRestoration == true else { return }
            DispatchQueue.main.async { [weak self, weak webView] in
                guard let self, let webView, self.resourceContextIsActive,
                      self.lastFocusToken == token, self.acceptsFindHost(webView),
                      state == nil || state?.lastConsumedToken == token else { return }
                if requested || state?.consumeRestoration(in: webView) == true {
                    webView.window?.makeFirstResponder(webView)
                }
            }
        }
        /// Token of the most recently consumed find-navigation command, so it runs
        /// exactly once even if `updateNSView` re-runs while the binding still holds
        /// the same command. See the consumption site for why clearing the binding
        /// inside `updateNSView` is not reliable.
        var lastFindNavigationToken: UUID?

        private(set) var isLoaded = false
        /// The mode-switch scroll target. Retained across an immediate apply so a
        /// reload that fires right after entering Side by Side (the preview view
        /// is rebuilt, resetting scroll to the top) re-applies it on `didFinish`
        /// instead of leaving the preview stuck at the top. Consumed by the
        /// post-load apply and cleared once the user scrolls.
        private var pendingScroll: ModeSwitchAnchor?
        var lastScrollRequest: ModeSwitchAnchor?
        private var pendingFindQuery: String?
        private var pendingFindNavigation: [FindCommand.Action] = []
        private var ignoreNextAnchorMessage = false

        /// The body the current page was loaded with, until a live update has
        /// keyed the page's nodes. The page rendered them before any key could
        /// be stored, so the first update sends this along to key them from.
        /// Set by each full load; cleared once an update is sent to the page.
        var loadedBody: String?

        /// Coalesces rapid live content swaps (one per keystroke) into a single
        /// JS push, keeping typing smooth. The latest body wins.
        private var pendingLiveBody: String?
        private var pendingLiveOptions = ""
        private var pendingLiveImages: [String: URL] = [:]
        private var liveUpdateWorkItem: DispatchWorkItem?
        private var liveUpdateGeneration = 0
        private static let liveUpdateDebounce: TimeInterval = 0.09
        /// The caret's source line to keep in view while editing, and the instant
        /// after which it lapses. While the window is live EVERY live swap follows
        /// this line and the capture + `keepPinned` re-affirm is disabled — so no
        /// stray swap in an edit burst can pin a drifted position. Re-armed by the
        /// editor on every keystroke; ignored once the window passes.
        var editFollowLine: Int?
        var editFollowDeadline = Date.distantPast
        /// How long after the last edit the preview keeps following the caret.
        /// Matches `ContentView`'s edit-window suppression so the two agree.
        static let editFollowWindow: TimeInterval = 0.85

        /// Replaces the rendered content in place (debounced), preserving the
        /// preview's current source anchor. Called only when the page is loaded
        /// and no new diagram engine is required (the caller guarantees this).
        func applyLiveContent(_ bodyHTML: String, mathMacros: [String: String], in webView: WKWebView) {
            guard resourceContextIsActive else { return }
            (webView as? PreviewWebView)?.invalidateContextMenu()
            liveUpdateGeneration += 1
            let generation = liveUpdateGeneration
            hasContentInFlight = true
            liveUpdateWorkItem?.cancel()
            let baseURL = lastBaseURL
            let loadedBody = self.loadedBody
            Task { [weak self, weak webView] in
                // The loaded body is rewritten like the page was, so its image
                // URLs match the page's (image tokens are stable per file).
                let (prepared, loaded) = await Task.detached(priority: .userInitiated) {
                    (WebDocumentLoader.rewriteContent(bodyHTML, baseURL: baseURL),
                     loadedBody.map { WebDocumentLoader.rewriteContent($0, baseURL: baseURL).html })
                }.value
                guard let self, let webView, self.resourceContextIsActive,
                      generation == self.liveUpdateGeneration else { return }
                self.pendingLiveBody = prepared.html
                self.pendingLiveOptions = Self.liveContentOptions(mathMacros: mathMacros, loadedBody: loaded)
                self.pendingLiveImages = prepared.allowedImages
                self.schedulePreparedLiveContent(in: webView, generation: generation)
            }
        }

        /// The `options` argument of `__md2ApplyContent`, as a JavaScript
        /// object literal. Pure, so it needs no actor.
        nonisolated static func liveContentOptions(mathMacros: [String: String], loadedBody: String?) -> String {
            var options: [String: Any] = ["macros": mathMacros]
            if let loadedBody { options["loaded"] = loadedBody }
            guard let data = try? JSONSerialization.data(withJSONObject: options, options: [.sortedKeys]),
                  let json = String(data: data, encoding: .utf8) else {
                return "{}"
            }
            return json
        }

        private func schedulePreparedLiveContent(in webView: WKWebView, generation: Int) {
            let work = DispatchWorkItem { [weak self, weak webView] in
                guard let self, let webView, let body = self.pendingLiveBody else { return }
                guard self.resourceContextIsActive, generation == self.liveUpdateGeneration else { return }
                self.pendingLiveBody = nil
                let options = self.pendingLiveOptions
                self.documentLoader.installImages(self.pendingLiveImages)
                self.pendingLiveImages = [:]

                // An edit is in flight: keep the caret's rendered line in view
                // (only if it scrolled off-screen) rather than re-affirming the
                // preview's previous position. While the edit window is live this
                // is the SOLE authority on the preview's position — the capture +
                // `keepPinned` re-affirm below is skipped, so no stray swap in an
                // edit burst (e.g. a multi-key delete) can pin a drifted position,
                // and the editor is never driven.
                if let followLine = self.editFollowLine, Date() < self.editFollowDeadline {
                    let script = "window.__md2ApplyContent(\(Self.jsStringLiteral(body)), \(options));"
                        + "window.__md2FollowEditLine ? window.__md2FollowEditLine(\(followLine)) : null;"
                        + "true;"
                    // This update keys the page's nodes, so later ones need no
                    // loaded body (the page ignores one sent after that anyway).
                    self.loadedBody = nil
                    webView.evaluateJavaScript(script) { [weak self, weak webView] _, error in
                        guard let self, let webView else { return }
                        self.finishLiveContent(generation: generation, error: error, in: webView)
                    }
                    return
                }
                self.editFollowLine = nil

                webView.evaluateJavaScript(
                    "window.__md2CaptureAnchor ? window.__md2CaptureAnchor() : null;"
                ) { [weak self, weak webView] result, _ in
                    guard let self, let webView, generation == self.liveUpdateGeneration else { return }
                    let anchor = (result as? [String: Any]).map(Self.viewportAnchor(fromMessage:))
                    let script = Self.liveContentScript(bodyHTML: body, options: options, anchor: anchor)
                    self.loadedBody = nil
                    webView.evaluateJavaScript(script) { [weak self, weak webView] _, error in
                        guard let self, let webView else { return }
                        self.finishLiveContent(generation: generation, error: error, in: webView)
                    }
                }
            }
            liveUpdateWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.liveUpdateDebounce, execute: work)
        }

        /// Both update scripts end in a value WebKit can return, so an `error`
        /// means the update threw and the page may still show the old content.
        private func finishLiveContent(generation: Int, error: Error?, in webView: WKWebView) {
            if error == nil, generation == liveUpdateGeneration {
                hasContentInFlight = false
                labelPage(in: webView)
            }
            if let query = lastFindQuery, !query.isEmpty {
                runFindWhenReady(query, in: webView)
            }
        }

        /// Tells the page which source-line revision it shows, for it to send
        /// back with a checkbox click. The label follows its content and never
        /// leads it: a page labelled behind what it shows only gets a click
        /// refused, but one labelled ahead would pass a stale click as current.
        func labelPage(in webView: WKWebView) {
            guard !hasContentInFlight, pageRevision != sourceLineRevision else { return }
            pageRevision = sourceLineRevision
            webView.evaluateJavaScript(
                "window.\(MarkdownPreviewView.sourceLineRevisionVariable) = \(sourceLineRevision); true;",
                in: nil, in: .defaultClient
            )
        }

        private func restoreTaskBoxes(in webView: WKWebView?) {
            webView?.evaluateJavaScript(MarkdownPreviewView.restoreTaskBoxesScript, in: nil, in: .defaultClient)
        }

        private static func liveContentScript(bodyHTML: String, options: String, anchor: ViewportAnchor?) -> String {
            var script = "window.__md2ApplyContent(\(jsStringLiteral(bodyHTML)), \(options));"
            if let anchor {
                // `true` = silent: re-affirm the preview's own position as async
                // math/diagrams reflow, but do NOT report an anchor — an edit
                // must never drive the editor pane (it would jump to the bottom).
                script += "window.__md2ScrollToViewportAnchor(\(viewportAnchorJS(anchor)), true);"
            }
            return script + "true;"
        }

        /// Encodes a string as a JavaScript string literal (quotes included) so
        /// arbitrary rendered HTML can be passed safely to `evaluateJavaScript`.
        private static func jsStringLiteral(_ string: String) -> String {
            guard let data = try? JSONSerialization.data(withJSONObject: string, options: [.fragmentsAllowed]),
                  let json = String(data: data, encoding: .utf8) else {
                return "\"\""
            }
            return json
        }

        /// How long a mode-switch capture waits for the page's JavaScript
        /// before falling back to the cached anchor.
        private static let captureTimeout: TimeInterval = 0.25
        private var pendingCaptureID = 0
        private var pendingCaptureCompletion: ((ViewportAnchor?) -> Void)?
        private var captureTimeoutWorkItem: DispatchWorkItem?

        /// Asks the live page for a fresh viewport anchor, completing with
        /// `nil` after a short timeout so a switch is never blocked by a page
        /// that is still loading or running heavy engine scripts.
        func captureAnchor(in webView: WKWebView, completion: @escaping (ViewportAnchor?) -> Void) {
            // A newer capture supersedes any still-pending one.
            pendingCaptureID += 1
            let captureID = pendingCaptureID
            pendingCaptureCompletion?(nil)
            pendingCaptureCompletion = completion

            let timeout = DispatchWorkItem { [weak self] in
                self?.finishCapture(captureID, with: nil)
            }
            captureTimeoutWorkItem?.cancel()
            captureTimeoutWorkItem = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.captureTimeout, execute: timeout)

            webView.evaluateJavaScript(
                "window.__md2CaptureAnchor ? window.__md2CaptureAnchor() : null;"
            ) { [weak self] result, _ in
                let anchor = (result as? [String: Any]).map(Self.viewportAnchor(fromMessage:))
                self?.finishCapture(captureID, with: anchor)
            }
        }

        private func finishCapture(_ captureID: Int, with anchor: ViewportAnchor?) {
            guard captureID == pendingCaptureID,
                  let completion = pendingCaptureCompletion else { return }
            pendingCaptureCompletion = nil
            captureTimeoutWorkItem?.cancel()
            captureTimeoutWorkItem = nil
            completion(anchor)
        }

        /// Decodes the anchor payload produced by the page's `captureAnchor()`
        /// JavaScript. Missing/null fields collapse to the fallbacks-only
        /// anchor; the `ViewportAnchor` initializer sanitizes the numbers.
        static func viewportAnchor(fromMessage body: [String: Any]) -> ViewportAnchor {
            ViewportAnchor(
                sourceLine: (body["line"] as? NSNumber)?.intValue,
                sourceEndLine: (body["endLine"] as? NSNumber)?.intValue,
                intraBlockProgress: (body["progress"] as? NSNumber)?.doubleValue ?? 0,
                viewportTopInset: (body["inset"] as? NSNumber)?.doubleValue ?? 0,
                scrollFraction: (body["fraction"] as? NSNumber)?.doubleValue ?? 0,
                fallbackHeadingID: body["id"] as? String
            )
        }

        /// Marks the page as loading before WebKit callbacks arrive. This prevents
        /// a same-query search from running against the previous document body.
        func beginLoading() {
            findGeneration = UUID()
            findInFlight = false
            if pendingFindQuery == nil { pendingFindQuery = lastFindQuery }
            isLoaded = false
            isAwaitingCommit = true
            hasContentInFlight = true
            liveUpdateGeneration += 1
            liveUpdateWorkItem?.cancel()
            pendingLiveBody = nil
            pendingLiveImages = [:]
        }

        /// A full reload caused by an edit can emit one load-position anchor
        /// before the user touches the preview. That report describes WebKit's
        /// reload settle, so it must not drive the editor pane.
        func suppressNextAnchorMessage() {
            ignoreNextAnchorMessage = true
        }

        /// Answers a Reload with a load of the latest HTML. WebKit would bring
        /// back the memory page, which has none of the live updates since the
        /// last load, and its navigation would be no load's, so its page would
        /// go unlabelled. WebKit also restores the reader's place, which a load
        /// does not, so that goes along. A page still loading has none to keep.
        private func reloadLatestContent(in webView: WKWebView) {
            guard resourceContextIsActive else { return }
            (webView as? PreviewWebView)?.invalidateContextMenu()
            captureAnchor(in: webView) { [weak self, weak webView] anchor in
                guard let self, let webView, self.resourceContextIsActive else { return }
                let place = self.isLoaded ? anchor : nil
                if let place {
                    self.pendingScroll = .viewport(place)
                    self.suppressNextAnchorMessage()
                }
                self.beginLoading()
                self.loadedBody = self.lastBody
                // The marks go with the page, and the find bar still counts them.
                if let query = self.lastFindQuery, !query.isEmpty {
                    self.runFindWhenReady(query, in: webView)
                }
                self.documentLoader.load(
                    self.lastHTML, baseURL: self.lastBaseURL, fragment: place?.fallbackHeadingID,
                    remoteResourcePolicy: self.remoteResourcePolicy, in: webView
                )
            }
        }

        /// Bind result delivery to the native preview host, including the gap
        /// between SwiftUI dismantling it and WebKit returning pending callbacks.
        func attachFindHost(_ webView: WKWebView) {
            guard findHost !== webView || !findHostIsActive else { return }
            findGeneration = UUID()
            findHost = webView
            findHostIsActive = true
        }

        func detachFindHost(_ webView: WKWebView) {
            guard findHost === webView else { return }
            findGeneration = UUID()
            findHostIsActive = false
            findHost = nil
            findInFlight = false
            pendingFindQuery = nil
            pendingFindNavigation.removeAll()
        }

        private func acceptsFindHost(_ webView: WKWebView) -> Bool {
            guard findHostIsActive else { return false }
            // Standalone coordinator clients acquire their first host lazily;
            // real SwiftUI views bind explicitly in makeNSView.
            if findHost == nil { findHost = webView }
            return findHost === webView
        }

        private func isCurrentFind(_ generation: UUID, in webView: WKWebView) -> Bool {
            findHostIsActive && findHost === webView && findGeneration == generation
        }

        /// Runs a preview search immediately when the page is ready, otherwise
        /// remembers the latest query and applies it after `didFinish`.
        func runFindWhenReady(_ query: String, in webView: WKWebView) {
            guard acceptsFindHost(webView) else { return }
            pendingFindQuery = query
            findGeneration = UUID()
            if isLoaded {
                applyPendingFind(in: webView)
            }
        }

        /// Parses the `{total, index}` object returned by the JS find helpers and
        /// forwards it to the find bar.
        func reportFindResult(_ result: Any?) {
            guard let dict = result as? [String: Any] else {
                onFindResult(0, 0)
                return
            }
            onFindUnavailable(dict["unavailable"] as? Bool == true)
            let total = (dict["total"] as? NSNumber)?.intValue ?? 0
            let index = (dict["index"] as? NSNumber)?.intValue ?? 0
            onFindResult(total, index)
        }

        /// Dispatches a find command produced by the find bar or the ⌘G/⇧⌘G
        /// shortcuts. `.search` (Return in the query field) is a no-op on the
        /// preview: the live query-change path already re-ran the search, and
        /// re-running `window.__md2Find` would reset the current match to 1 and
        /// scroll — the same auto-jump this change removes, just backward.
        /// Internal so tests can drive the routing deterministically.
        @MainActor func handleFindNavigation(_ action: FindCommand.Action, in webView: WKWebView) {
            guard acceptsFindHost(webView) else { return }
            switch action {
            case .search:
                break
            case .next, .previous:
                // A newly mounted page has not built its match list yet.
                // Keep commands in order until the pending query is applied.
                if pendingFindQuery != nil || findInFlight {
                    pendingFindNavigation.append(action)
                    return
                }
                let forward = action == .next
                let generation = findGeneration
                webView.evaluateJavaScript("window.__md2FindNext(\(forward));") { [weak self, weak webView] result, _ in
                    guard let self, let webView, self.isCurrentFind(generation, in: webView) else { return }
                    self.reportFindResult(result)
                }
            case .show, .showReplace:
                break // bar presentation is handled at the ContentView level
            }
        }

        func applyFrontMatterVisibility(in webView: WKWebView) {
            guard isLoaded else { return }
            webView.evaluateJavaScript(
                "window.__md2SetFrontMatterVisible ? window.__md2SetFrontMatterVisible(\(MarkdownPreviewView.jsBoolean(showsFrontMatter))) : null;"
            )
        }

        /// Flips the preview gutter's switch class. Toggling never reloads or
        /// re-renders the document — the layer is already built, and the numbers
        /// are generated content, so showing them is a class change.
        func applyLineNumbersVisibility(in webView: WKWebView) {
            guard isLoaded else { return }
            webView.evaluateJavaScript(
                "window.__md2SetLineNumbersVisible ? window.__md2SetLineNumbersVisible(\(MarkdownPreviewView.jsBoolean(showsLineNumbers))) : null;"
            )
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard resourceContextIsActive, message.frameInfo.isMainFrame else { return }
            switch message.name {
            case MarkdownPreviewView.selectionMessageName:
                guard message.world == .defaultClient else { return }
                onSelectionChange(message.body as? String)
            case MarkdownPreviewView.enterEditMessageName:
                guard message.world == .defaultClient else { return }
                onEnterEdit()
            case MarkdownPreviewView.openLinkMessageName:
                guard message.world == .defaultClient,
                      let href = message.body as? String,
                      let url = URL(string: href) else { return }
                dispatch(PreviewLinkRouter.route(for: url, documentPageURL: documentLoader.documentPageURL))
            case MarkdownPreviewView.toggleTaskMessageName:
                guard message.world == .defaultClient else { return }
                // A page not labelled yet sends no revision, and nothing can
                // say what its line means.
                guard let body = message.body as? [String: Any],
                      let line = (body["line"] as? NSNumber)?.intValue,
                      let checked = (body["checked"] as? NSNumber)?.boolValue,
                      let revision = (body["revision"] as? NSNumber)?.intValue else {
                    restoreTaskBoxes(in: message.webView)
                    return
                }
                onToggleTask(line, checked, revision) { [weak self, weak webView = message.webView] in
                    self?.restoreTaskBoxes(in: webView)
                }
            case MarkdownPreviewView.revealSourceLineMessageName:
                guard message.world == .defaultClient else { return }
                guard let body = message.body as? [String: Any],
                      let line = (body["line"] as? NSNumber)?.intValue, line >= 1 else { return }
                onRevealSourceLine(line)
            case MarkdownPreviewView.anchorMessageName:
                guard let body = message.body as? [String: Any] else { return }
                if ignoreNextAnchorMessage {
                    ignoreNextAnchorMessage = false
                    return
                }
                let isUserInitiated = (body["user"] as? NSNumber)?.boolValue ?? false
                // Once the user scrolls the preview themselves, a retained
                // mode-switch target must not snap them back on a later reload.
                if isUserInitiated { pendingScroll = nil }
                onAnchorChange(Self.viewportAnchor(fromMessage: body), isUserInitiated)
            default:
                break
            }
        }

        // MARK: Link policy

        /// The preview is a viewport onto the document, never a browser: the
        /// only allowed main-frame navigations are the app's own page (initial
        /// load, reload-on-edit, and same-page fragment jumps). Every other
        /// target is cancelled. Native opens require the isolated trusted-click
        /// bridge or a native menu action, never navigationType or a missing target
        /// frame: scripts can produce both. WebKit's own Reload becomes a load
        /// of the latest HTML.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            guard resourceContextIsActive else { decisionHandler(.cancel); return }
            // Subframe navigations stay inside the page.
            if let targetFrame = navigationAction.targetFrame, !targetFrame.isMainFrame {
                decisionHandler(.allow)
                return
            }

            // Ahead of the router, which would cancel a Reload of a page that a
            // load is replacing. That load may be gone by now: a Reload can stop
            // one still at its policy decision.
            if navigationAction.navigationType == .reload {
                decisionHandler(.cancel)
                reloadLatestContent(in: webView)
                return
            }

            let route = PreviewLinkRouter.route(
                for: navigationAction.request.url,
                documentPageURL: documentLoader.documentPageURL
            )
            if route == .allowInPage {
                decisionHandler(.allow)
                return
            }

            decisionHandler(.cancel)
        }

        /// `target="_blank"`/`window.open` requests never create an in-app
        /// browsing context. Trusted anchor clicks were already handled by the
        /// isolated bridge; a script-created request cannot invoke a handler.
        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            return nil
        }

        fileprivate func dispatch(_ route: PreviewLinkRouter.Route) {
            guard resourceContextIsActive else { return }
            switch route {
            case .allowInPage, .ignore:
                break
            case let .openExternal(url):
                onOpenWithSystem(url)
            case let .openMarkdownDocument(url):
                guard FileManager.default.fileExists(atPath: url.path) else {
                    onMissingLocalLink(url)
                    return
                }
                onOpenMarkdownLink(url)
            case let .openWithSystem(url):
                guard FileManager.default.fileExists(atPath: url.path) else {
                    onMissingLocalLink(url)
                    return
                }
                onOpenWithSystem(url)
            }
        }

        // MARK: Deferred scrolling

        /// Records a scroll target and applies it now if the page has finished
        /// loading, otherwise defers it to `didFinish`.
        func setPendingScroll(_ anchor: ModeSwitchAnchor, in webView: WKWebView) {
            pendingScroll = anchor
            if isLoaded {
                // Apply now, but KEEP the target: entering Side by Side rebuilds
                // the preview view, triggering a reload that resets scroll to the
                // top right after this. Retaining `pendingScroll` lets the
                // post-reload `didFinish` re-apply it.
                applyPendingScroll(in: webView, consume: false)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Taken for loaded, a page on its way out would receive an edit that
            // the load then overwrites with older text.
            guard resourceContextIsActive, !isAwaitingCommit,
                  documentLoader.currentNavigation == nil || navigation === documentLoader.currentNavigation else { return }
            isLoaded = true
            applyTypography(in: webView)
            applyFrontMatterVisibility(in: webView)
            applyLineNumbersVisibility(in: webView)
            applyPendingScroll(in: webView, consume: true)
            applyPendingFind(in: webView)
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            guard resourceContextIsActive else { return }
            (webView as? PreviewWebView)?.invalidateContextMenu()
            // A new document started loading; hold scrolling until it finishes.
            isLoaded = false
            // Label it now: `didFinish` waits for every image, and the boxes work
            // from the end of parsing. A page some newer load will replace stays
            // unlabelled, so its clicks are refused.
            guard navigation === documentLoader.currentNavigation else { return }
            isAwaitingCommit = false
            hasContentInFlight = false
            pageRevision = nil
            labelPage(in: webView)
        }

        private func applyPendingScroll(in webView: WKWebView, consume: Bool = true) {
            guard let anchor = pendingScroll else { return }
            if consume { pendingScroll = nil }

            switch anchor {
            case let .viewport(viewport):
                webView.evaluateJavaScript(
                    "window.__md2ScrollToViewportAnchor(\(Self.viewportAnchorJS(viewport)));"
                )
            case let .heading(id):
                let escapedID = MarkdownPreviewView.escapeForJS(id)
                webView.evaluateJavaScript("window.__md2ScrollToHeading('\(escapedID)');")
            case let .fraction(value):
                let clamped = min(max(value, 0), 1)
                webView.evaluateJavaScript("window.__md2ScrollToFraction(\(clamped));")
            }
        }

        /// Encodes a viewport anchor as the JSON object literal consumed by
        /// `__md2ScrollToViewportAnchor`. JSON encoding also escapes the
        /// heading id safely for the JavaScript context.
        private static func viewportAnchorJS(_ anchor: ViewportAnchor) -> String {
            var payload: [String: Any] = [
                "progress": anchor.intraBlockProgress,
                "inset": anchor.viewportTopInset,
                "fraction": anchor.scrollFraction
            ]
            if let line = anchor.sourceLine { payload["line"] = line }
            if let endLine = anchor.sourceEndLine { payload["endLine"] = endLine }
            if let headingID = anchor.fallbackHeadingID { payload["headingId"] = headingID }

            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let json = String(data: data, encoding: .utf8) else {
                return "{}"
            }
            return json
        }

        private func applyPendingFind(in webView: WKWebView) {
            guard acceptsFindHost(webView), let query = pendingFindQuery else { return }
            pendingFindQuery = nil
            findInFlight = true
            let generation = findGeneration
            let options = findOptions
            if query.isEmpty {
                finishFind(script: "window.__md2FindClear && window.__md2FindClear(); ({total:0,index:0});", generation: generation, in: webView)
                return
            }
            webView.evaluateJavaScript("window.__md2FindSnapshot ? window.__md2FindSnapshot() : null;") { [weak self, weak webView] snapshot, _ in
                guard let self, let webView, self.isCurrentFind(generation, in: webView) else { return }
                guard let snapshot = snapshot as? [String: Any] else {
                    // Older page/test fixtures expose only the original API.
                    self.finishFind(script: "window.__md2Find('\(MarkdownPreviewView.escapeForJS(query))');", generation: generation, in: webView)
                    return
                }
                if snapshot["unavailable"] as? Bool == true {
                    self.completeFind(["total": 0, "index": 0, "unavailable": true], generation: generation, in: webView)
                    return
                }
                guard let id = snapshot["id"] as? String, let text = snapshot["text"] as? String else {
                    self.completeFind(nil, generation: generation, in: webView)
                    return
                }
                Task { @MainActor [weak self, weak webView] in
                    let ranges = await Task.detached(priority: .userInitiated) {
                        PreviewTextSearch.ranges(query: query, text: text, options: options)
                    }.value
                    guard let self, let webView, self.isCurrentFind(generation, in: webView) else { return }
                    let payload: [String: Any] = ["id": id, "ranges": ranges ?? [], "unavailable": ranges == nil]
                    guard let data = try? JSONSerialization.data(withJSONObject: payload),
                          let json = String(data: data, encoding: .utf8) else {
                        self.completeFind(nil, generation: generation, in: webView)
                        return
                    }
                    self.finishFind(script: "window.__md2Find('\(MarkdownPreviewView.escapeForJS(query))', \(json));", generation: generation, in: webView)
                }
            }
        }

        private func finishFind(script: String, generation: UUID, in webView: WKWebView) {
            webView.evaluateJavaScript(script) { [weak self, weak webView] result, _ in
                guard let self, let webView else { return }
                self.completeFind(result, generation: generation, in: webView)
            }
        }

        private func completeFind(_ result: Any?, generation: UUID, in webView: WKWebView) {
            guard isCurrentFind(generation, in: webView) else { return }
            findInFlight = false
            if let dict = result as? [String: Any], dict["stale"] as? Bool == true {
                // The normal content-update path schedules the latest snapshot;
                // never apply marks/counts or drain navigation against stale DOM.
                if let query = lastFindQuery { runFindWhenReady(query, in: webView) }
                return
            }
            reportFindResult(result)
            let navigation = pendingFindNavigation
            pendingFindNavigation.removeAll()
            for action in navigation { handleFindNavigation(action, in: webView) }
        }

    }
}

private final class PreviewWebView: WKWebView {
    let contextMenuAdapter = PreviewContextMenuAdapter()
    private var contextMenuInput = PreviewContextMenuInput()

    fileprivate func invalidateContextMenu() {
        contextMenuInput.invalidate()
        contextMenuAdapter.invalidate()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { invalidateContextMenu() }
        super.viewWillMove(toWindow: newWindow)
    }

    private func recordContextMenuInput(_ event: NSEvent) {
        let nativePoint = convert(event.locationInWindow, from: nil)
        let clientPoint = NSPoint(x: nativePoint.x, y: isFlipped ? nativePoint.y : bounds.height - nativePoint.y)
        contextMenuInput.record(event, point: clientPoint, page: url, windowNumber: window?.windowNumber)
    }

    override func rightMouseDown(with event: NSEvent) {
        recordContextMenuInput(event)
        super.rightMouseDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        // A Control-left gesture is a context click; an ordinary click clears
        // a prior suppressed context event before normal WebKit processing.
        recordContextMenuInput(event)
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        contextMenuInput.invalidate()
        super.keyDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        contextMenuInput.invalidate()
        super.scrollWheel(with: event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        contextMenuInput.invalidate()
        super.rightMouseDragged(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        contextMenuInput.invalidate()
        super.mouseDragged(with: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        contextMenuInput.invalidate()
        super.otherMouseDown(with: event)
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        let generation = contextMenuAdapter.begin(menu)
        let page = url
        // AppKit's callback can supply events unrelated to the pointer input
        // (observed types 0 and 13 in the macOS 15 GUI tests).
        // Match the original mouse-down input, not this callback's coordinates.
        // Mouse-up deliberately does not clear it: menu creation is asynchronous.
        let input = contextMenuInput.take(for: page)
        evaluateJavaScript("window.__md2TakeContextMenu ? window.__md2TakeContextMenu() : null",
                           in: nil, in: .defaultClient) { [weak self, weak menu] result in
            guard let self, let menu, let input, self.url == page,
                  case let .success(value) = result, let data = value as? [String: Any],
                  let capturedPage = data["page"] as? String, URL(string: capturedPage) == page,
                  let x = data["x"] as? Double, let y = data["y"] as? Double,
                  self.contextMenuInput.matches(input, page: self.url, point: NSPoint(x: x, y: y),
                                                windowNumber: self.window?.windowNumber) else { return }
            self.contextMenuAdapter.bind(menu, generation: generation,
                                         link: (data["link"] as? String).flatMap(URL.init(string:)),
                                         image: (data["image"] as? String).flatMap(URL.init(string:)),
                                         page: page)
        }
    }

    override func didCloseMenu(_ menu: NSMenu, with event: NSEvent?) {
        contextMenuInput.invalidate()
        contextMenuAdapter.end(menu)
        super.didCloseMenu(menu, with: event)
    }

    var onFindAction: ((FindCommand.Action) -> Void)?
    /// Esc handler; returns whether the key was consumed (find bar dismissed).
    var onEscape: (() -> Bool)?

    private static let escapeKeyCode: UInt16 = 53

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        contextMenuInput.invalidate()
        // Esc travels as a plain key press; claim it only when the owner
        // actually consumed it (dismissed a find bar), so full-screen exit
        // and other system uses keep working.
        if event.keyCode == Self.escapeKeyCode, onEscape?() == true {
            return true
        }
        if let action = findAction(for: event) {
            onFindAction?(action)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        contextMenuInput.invalidate()
        // Fallback path for an Esc that reaches the responder chain instead of
        // the key-equivalent pass (WebKit hands unhandled page keys back via
        // doCommandBySelector). Never call super: `NSResponder` declares but
        // does not implement `cancelOperation:`, so a super call dies with an
        // unrecognized selector. An unconsumed Esc simply ends here, matching
        // the pre-override behavior.
        _ = onEscape?()
    }

    @objc(performFindPanelAction:)
    func md2PerformFindPanelAction(_ sender: Any?) {
        onFindAction?(.fromFindMenuItem(sender))
    }

    override func performTextFinderAction(_ sender: Any?) {
        onFindAction?(.fromFindMenuItem(sender))
    }

    private func findAction(for event: NSEvent) -> FindCommand.Action? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command),
              !flags.contains(.control),
              !flags.contains(.option),
              let key = event.charactersIgnoringModifiers?.lowercased() else {
            return nil
        }

        switch key {
        case "f":
            return .show
        case "g":
            return flags.contains(.shift) ? .previous : .next
        default:
            return nil
        }
    }
}
