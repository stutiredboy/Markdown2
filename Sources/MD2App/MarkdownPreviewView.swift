import AppKit
import MD2Core
import SwiftUI
import WebKit

/// Hands the surrounding view a way to ask the *live* preview page for its
/// current viewport anchor at the instant a mode switch is requested, instead
/// of relying on the last (possibly stale) debounced scroll callback.
@MainActor
final class PreviewViewportReader {
    struct Position {
        let anchor: ViewportAnchor
        let movedFromAnchor: Bool
        var heldReference: [String: Any]? = nil
    }

    fileprivate var capture: ((_ whenReady: Bool, _ completion: @escaping (Position?) -> Void) -> Void)?
    /// Scrolls the live preview directly to a (possibly fractional) source line
    /// for continuous Side by Side follow — lighter than a mode-switch anchor and
    /// without the pinning settle loop, so the preview tracks the editor smoothly.
    fileprivate var follow: ((Double, Bool) -> Void)?
    /// Records the caret's source line so the next live-content swap keeps its
    /// rendered output in view, nudging the preview only when that line is
    /// off-screen so an edit in the middle of the viewport never yanks the preview.
    fileprivate var setEditFollow: ((Int?) -> Void)?
    fileprivate var changeScrollSync: ((Bool, SplitPane) -> Void)?

    /// Asks the live web view for its current anchor. Completes with `nil`
    /// when the preview is not mounted or does not answer within the capture
    /// timeout (e.g. the page is still executing heavy engine scripts).
    func currentAnchor(whenReady: Bool = false, completion: @escaping (ViewportAnchor?) -> Void) {
        currentPosition(whenReady: whenReady) { completion($0?.anchor) }
    }

    func currentPosition(whenReady: Bool = false, completion: @escaping (Position?) -> Void) {
        guard let capture else {
            completion(nil)
            return
        }
        capture(whenReady, completion)
    }

    /// Drives the preview to follow the editor to `line` (continuous sync).
    func scrollToFollowLine(_ line: Double, whenReady: Bool = false) {
        follow?(line, whenReady)
    }

    func setScrollSyncPaused(_ paused: Bool, activePane: SplitPane) {
        changeScrollSync?(paused, activePane)
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
    /// Advisory evidence from the rendered page, scoped to its source revision.
    var onRemoteImageDetected: (_ revision: Int) -> Void = { _ in }
    /// When true (Side by Side mode), content-only changes are applied in place
    /// via `__md2ApplyContent` — preserving scroll position and avoiding the
    /// full-page reload flash — instead of reloading the web view.
    var liveUpdate: Bool = false
    var holdsReadingPosition = false
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
    var textRevision = 0
    var editParagraphTitle: String? = nil
    var onEditParagraph: (PreviewParagraphHit) -> Void = { _ in }
    struct FormulaEditing: Equatable {
        let revision: Int
        let editableLines: Set<Int>
        let editLabel: String
        let revealLabel: String
        var focusLine: Int? = nil
    }
    /// Read-only preview controls for the snapshot that produced this page.
    var formulaEditing: FormulaEditing? = nil
    var onEditFormula: (_ line: Int, _ revision: Int, _ window: NSWindow) -> Void = { _, _, _ in }
    @Binding var jumpHeadingID: String?
    var animatesHeadingJump = false
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
    var onPausedInteraction: () -> Void = {}
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
    var findMayRevealMatches = true
    var findOptions = TextSearch.Options()
    /// A next/previous navigation request; consumed (set to nil) once applied.
    @Binding var findNavigation: FindCommand?
    /// Changes whenever the preview surface should become first responder.
    /// A folder tab without a request leaves focus in the file browser.
    let focusToken: UUID?
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
    var mermaidViewerLanguage: AppLanguage = .english
    var typography: TypographySettings = .init()
    var onOutlineMarginChange: ((CGFloat) -> Void)?
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
            var excluded = '.front-matter,.footnote-ref,.footnote-backref,.diagram,.math,.toc,.md2-broken-image,.md2-line-gutter,.md2-formula-action';
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
    private static let viewportReadyMessageName = "viewportReady"
    private static let outlineMarginMessageName = "outlineMarginChange"
    private static let toggleTaskMessageName = "toggleTask"
    private static let revealSourceLineMessageName = "revealSourceLine"
    private static let editFormulaMessageName = "editFormula"
    private static let openLinkMessageName = "openLink"
    private static let forwardedLinkSchemes = String(decoding:
        try! JSONEncoder().encode(HTMLSafety.safeURLSchemes.sorted().map { $0 + ":" }), as: UTF8.self)

    /// Page scripts (including diagram engines) cannot see native mutation
    /// handlers. Only trusted DOM input in the isolated world is forwarded.
    static func installInteractionBridge(on controller: WKUserContentController, handler: WKScriptMessageHandler) {
        controller.add(handler, contentWorld: .defaultClient, name: enterEditMessageName)
        controller.add(handler, contentWorld: .defaultClient, name: toggleTaskMessageName)
        controller.add(handler, contentWorld: .defaultClient, name: revealSourceLineMessageName)
        controller.add(handler, contentWorld: .defaultClient, name: editFormulaMessageName)
        controller.add(handler, contentWorld: .defaultClient, name: openLinkMessageName)
        controller.addUserScript(WKUserScript(source: interactionScript,
            injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        controller.addUserScript(WKUserScript(source: formulaControlsScript,
            injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
    }

    private static let formulaControlsScript = """
    (function () {
        var config = null;
        var controls = new Map();
        var style = null;
        function restoreFocus(line, reveal) {
            var button = controls.get(line);
            if (!button || !button.isConnected) { return false; }
            button.focus({preventScroll: true});
            var bounds = reveal ? button.getBoundingClientRect() : null;
            if (bounds && (bounds.top < 0 || bounds.bottom > window.innerHeight)) {
                button.scrollIntoView({block: 'nearest', inline: 'nearest'});
            }
            return true;
        }
        window.__md2FocusFormula = function (token, line) {
            return !!config && config.token === token && restoreFocus(line, true);
        };
        window.__md2SetFormulaControls = function (next) {
            var active = document.activeElement;
            var activeLine = null;
            controls.forEach(function (button, line) {
                if (active === button) { activeLine = line; }
                button.remove();
            });
            controls.clear();
            config = next;
            if (!config) { return; }
            var main = document.querySelector('main');
            if (!main) { return; }
            var editable = new Set(config.editableLines);
            // HTMLSafety strips authored classes and data attributes. Take the
            // line from the renderer's equation wrapper, not from the button,
            // selected text, or the content KaTeX inserted into the equation.
            var equations = main.querySelectorAll('div.math.math-display[data-md2-source-line], ' +
                'div.numbered-equation[data-md2-source-line] > div.math.math-display');
            if (equations.length && !style) {
                style = document.createElement('style');
                // CSS-generated labels keep action text out of document Find
                // and Copy while aria-label gives the native button its name.
                style.textContent = '.md2-formula-action{' +
                    'display:block;margin:0 0 .65rem auto;padding:.25em .55em;' +
                    'font:500 .78rem/1.35 -apple-system,BlinkMacSystemFont,sans-serif;' +
                    'color:var(--text);background:var(--code-bg);border:1px solid var(--border);' +
                    'border-radius:5px;cursor:pointer;user-select:none;}' +
                    '.md2-formula-action::before{content:attr(aria-label);}' +
                    '.md2-formula-action:hover{border-color:var(--accent);}' +
                    '.md2-formula-action:focus-visible{outline:2px solid var(--accent);outline-offset:2px;}' +
                    '@media print{.md2-formula-action{display:none;}}';
                document.head.appendChild(style);
            }
            equations.forEach(function (equation) {
                var block = equation.hasAttribute('data-md2-source-line') ? equation : equation.parentElement;
                var line = Number(block.getAttribute('data-md2-source-line'));
                if (!Number.isSafeInteger(line) || line < 1 || controls.has(line)) { return; }
                var canEdit = editable.has(line);
                if (canEdit && block.parentElement !== main) { return; }
                var button = document.createElement('button');
                button.type = 'button';
                button.className = 'md2-formula-action';
                button.setAttribute('data-md2-formula-line', line);
                button.setAttribute('aria-label', canEdit ? config.editLabel : config.revealLabel);
                button.addEventListener('click', function (event) {
                    if (!event.isTrusted || event.defaultPrevented || !config || controls.get(line) !== button ||
                        button.previousElementSibling !== block || !main.contains(block) ||
                        Number(block.getAttribute('data-md2-source-line')) !== line ||
                        (canEdit && block.parentElement !== main)) { return; }
                    window.webkit.messageHandlers.\(Self.editFormulaMessageName).postMessage({
                        line: line, token: config.token
                    });
                });
                controls.set(line, button);
                block.after(button);
            });
            if (activeLine !== null) { restoreFocus(activeLine, false); }
        };
        if (window.__md2FormulaConfig) { window.__md2SetFormulaControls(window.__md2FormulaConfig); }
    })();
    """

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
            function isContinuationPart(node) {
                return node?.nodeType === Node.TEXT_NODE ||
                    (node?.nodeType === Node.ELEMENT_NODE && !node.matches('br,[data-md2-source-line]') &&
                     getComputedStyle(node).display.startsWith('inline'));
            }
            function continuationHit(event, owner) {
                var caret = document.caretRangeFromPoint(event.clientX, event.clientY);
                var text = caret?.startContainer;
                if (text?.nodeType !== Node.TEXT_NODE || !owner.contains(text)) { return null; }
                // A caret lookup can snap to text even when the user clicks
                // blank space. Accept a point on the nearby glyphs only.
                var probe = caret.cloneRange(), offset = caret.startOffset;
                probe.setStart(text, Math.max(0, offset - 1));
                probe.setEnd(text, Math.min(text.length, offset + 1));
                if (!Array.from(probe.getClientRects()).some(rect => rect.left <= event.clientX &&
                    rect.right >= event.clientX && rect.top <= event.clientY && rect.bottom >= event.clientY)) { return null; }
                var first = text;
                while (first.parentNode !== owner) { first = first.parentNode; }
                if (!isContinuationPart(first)) { return null; }
                // The marker must be a direct sibling in this run. Never look
                // through an authored BR or across another source block.
                for (var steps = 0; isContinuationPart(first.previousSibling); steps++) {
                    if (steps >= 8192) { return null; }
                    first = first.previousSibling;
                }
                var marker = first.previousSibling;
                var line = Number(marker?.dataset?.md2SourceNextLine);
                if (marker?.tagName !== 'BR' || !Number.isSafeInteger(line) || line <= 0) { return null; }
                var hit = {line: line, revision: window.__md2TextRevision};
                var plain = '', column = null;
                for (var node = first, count = 0; isContinuationPart(node); node = node.nextSibling, count++) {
                    if (count >= 8192 || node.nodeType !== Node.TEXT_NODE || plain.length + node.length > 16384) { return hit; }
                    if (node === text) { column = plain.length + offset; }
                    plain += node.data;
                }
                if (column !== null) { Object.assign(hit, {plainLines: [plain], row: 0, column: column}); }
                return hit;
            }
            // Resolve the block under the pointer, independently of visible gutter
            // numbers and of WebKit's current (possibly word-wide) selection.
            function paragraphHit(event) {
                var target = event.target;
                if (!target.closest || target.closest('input,button,.md2-line-gutter,.md2-diagram-viewer')) { return null; }
                var main = target.closest('main');
                if (!main) { return null; }
                var block = target.closest('[data-md2-source-line]');
                if (!block || block.matches('blockquote,li')) {
                    var continuation = continuationHit(event, block || main);
                    if (continuation) { return continuation; }
                }
                if (!block || !main.contains(block)) { return null; }
                var hit = { line: Number(block.dataset.md2SourceLine), revision: window.__md2TextRevision };
                if (block.tagName !== 'P') { return hit; }
                var caret = document.caretRangeFromPoint(event.clientX, event.clientY);
                if (!caret || caret.startContainer.nodeType !== Node.TEXT_NODE ||
                    !block.contains(caret.startContainer)) { return hit; }

                // Plain paragraphs have one BR per source break. Transformed
                // inline content keeps the block-level source target.
                if (block.childNodes.length > 8192) { return hit; }
                var lines = [''], row = null, column = null, length = 0;
                for (var node of block.childNodes) {
                    if (node.nodeType === Node.TEXT_NODE) {
                        length += node.length;
                        if (length > 16384) { return hit; }
                        if (node === caret.startContainer) {
                            row = lines.length - 1;
                            column = lines[row].length + caret.startOffset;
                        }
                        lines[lines.length - 1] += node.data;
                    } else if (node.tagName === 'BR') {
                        lines.push('');
                    } else { return hit; }
                }
                if (lines.at(-1) === '') { lines.pop(); }
                var end = Number(block.dataset.md2SourceEndLine || hit.line);
                if (row !== null && lines.length === end - hit.line + 1) {
                    Object.assign(hit, {plainLines: lines, row: row, column: column});
                }
                return hit;
            }
            document.addEventListener('dblclick', function (event) {
                if (!event.isTrusted || event.defaultPrevented || event.button !== 0 || !event.metaKey ||
                    event.target.closest('a,input,button,.md2-line-gutter,.md2-diagram-viewer')) { return; }
                var hit = paragraphHit(event);
                if (hit) {
                    window.webkit.messageHandlers.\(Self.enterEditMessageName).postMessage(hit);
                } else if (event.target.closest('main') || event.target.matches('body,html')) {
                    // Generated document sections without a source block retain
                    // the existing Read-to-Write viewport shortcut.
                    window.webkit.messageHandlers.\(Self.enterEditMessageName).postMessage({background: true, revision: window.__md2TextRevision});
                }
            });
            var context = null;
            window.__md2TakeContextMenu = function () {
                var captured = context; context = null;
                if (!captured || !captured.target.isConnected
                    || document.elementFromPoint(captured.x, captured.y) !== captured.target) { return null; }
                return { page: captured.page, link: captured.link, image: captured.image,
                         paragraph: captured.paragraph, x: captured.x, y: captured.y };
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
                    page: location.href, paragraph: paragraphHit(event),
                    link: absolute(link && (link.getAttribute('href') || link.getAttributeNS('http://www.w3.org/1999/xlink', 'href'))),
                    image: absolute(image && (image.currentSrc || image.getAttribute('src')))
                };
            }, true);
        })();
        // Task checkboxes toggle optimistically, and native rewrites the source
        // line (the re-render that follows is the authoritative state). The line only
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
        (function () {
        var remoteNodes = new Set();
        var reportedRevision;
        function remoteSource(img) {
            var selected = img.currentSrc || '';
            var declared = img.getAttribute('src') || '';
            var http = /^https?:/i;
            if (http.test(selected)) { return selected; }
            return http.test(declared.trim().replace(/[\\t\\n\\r]/g, '')) ? declared : '';
        }
        function reportRemoteImage(refresh) {
            // The live update can retain an engine-generated image or its
            // placeholder. Forget detached nodes before checking the new body.
            for (var node of remoteNodes) {
                if (!node.isConnected) { remoteNodes.delete(node); }
            }
            var revision = window.\(Self.sourceLineRevisionVariable);
            if (remoteNodes.size && Number.isInteger(revision) && (refresh || revision !== reportedRevision)) {
                reportedRevision = revision;
                window.webkit.messageHandlers.\(Self.remoteImageMessageName).postMessage(revision);
            }
        }
        window.__md2ReportRemoteImage = reportRemoteImage;
        window.addEventListener('load', function (event) {
            var img = event.target;
            if (event.isTrusted && img && img.tagName === 'IMG' && remoteSource(img)) {
                remoteNodes.add(img);
                if (window.\(Self.sourceLineRevisionVariable) !== reportedRevision) { reportRemoteImage(false); }
            }
        }, true);
        window.addEventListener('error', function (event) {
            var img = event.target;
            if (!img || img.tagName !== 'IMG') { return; }
            if (img.getAttribute('data-md2-broken') === '1') { return; }
            var remote = remoteSource(img);
            var src = remote || img.getAttribute('src') || '';
            var lower = src.trim().toLowerCase();
            var labelText = '\(Self.escapeForJS(genericImageLoadFailedLabel))';
            if (remote) {
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
                if (event.isTrusted && remote) {
                    remoteNodes.add(placeholder);
                    if (window.\(Self.sourceLineRevisionVariable) !== reportedRevision) { reportRemoteImage(false); }
                }
            }
        }, true);
        })();
        """
    }

    private static let remoteImageMessageName = "remoteImageDetected"

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
        function markUserScrollIntent(event) {
            lastUserScrollIntentAt = Date.now();
            window.__md2NoteHeldReloadScroll?.(event);
            if (window.__md2ScrollSyncPaused) {
                window.webkit.messageHandlers.\(Self.anchorMessageName).postMessage({ interaction: true });
            }
        }
        window.addEventListener('wheel', markUserScrollIntent, { passive: true });
        window.addEventListener('touchmove', markUserScrollIntent, { passive: true });
        window.addEventListener('mousedown', markUserScrollIntent, { passive: true });
        window.addEventListener('keydown', function(event) {
            var keys = ['ArrowUp', 'ArrowDown', 'PageUp', 'PageDown', 'Home', 'End', ' '];
            if (keys.indexOf(event.key) >= 0) { markUserScrollIntent(event); }
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
            // This offset belongs to the source→preview handoff. A later
            // layout-only repin must not erase evidence of reader navigation.
            var anchoredScrollY = null;
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
                    movedFromAnchor: anchoredScrollY !== null && Math.abs(window.scrollY - anchoredScrollY) > 1,
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
            var pending = null;
            window.addEventListener('scroll', function () {
                if (pending) { return; }
                pending = setTimeout(function () { pending = null; topAnchor(); }, 80);
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
            var pinSequence = 0;
            var animatedPinEpoch = 0;
            function keepPinned(getTargetY, silent, rememberOffset, animate) {
                releaseReference();
                // A recent click inside the preview is not evidence that this
                // programmatic jump was a user scroll. Only gestures that occur
                // after pinning starts may mark its final anchor as user driven.
                lastUserScrollIntentAt = 0;
                suppressUntil = Date.now() + 2600;
                var sequence = ++pinSequence;
                // An outline animation takes over any older pin. Any newer
                // navigation supersedes the animation in turn.
                var epoch = animate ? ++animatedPinEpoch : animatedPinEpoch;
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
                var initialY = window.scrollY;
                var duration = animate && !matchMedia('(prefers-reduced-motion: reduce)').matches ? 180 : 0;
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
                    if (cancelled || epoch !== animatedPinEpoch || (animate && sequence !== pinSequence)) { return; }
                    if (started && Math.abs(window.scrollY - expectedY) > 2) {
                        // Scroll position changed but we didn't move it: the user
                        // scrolled. Yield and stop re-anchoring.
                        done();
                        return;
                    }
                    var targetY = getTargetY();
                    var progress = duration > 0 ? Math.min(1, (Date.now() - start) / duration) : 1;
                    if (targetY !== null && (progress < 1 || lastTargetY === null || Math.abs(targetY - lastTargetY) > 1)) {
                        // First positioning, or the anchor moved (content above
                        // reflowed): scroll to it.
                        if (progress === 1) { lastTargetY = targetY; }
                        stableFrames = 0;
                        var maxY = document.documentElement.scrollHeight - window.innerHeight;
                        var destination = Math.min(Math.max(0, targetY), Math.max(0, maxY));
                        var y = progress === 1 ? destination : initialY + (destination - initialY) * (1 - Math.pow(1 - progress, 3));
                        window.scrollTo(0, y);
                        expectedY = window.scrollY;
                        if (rememberOffset) { anchoredScrollY = expectedY; }
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

            window.__md2ScrollToHeading = function (id, animate) {
                keepPinned(function () {
                    var el = document.getElementById(id);
                    if (!el) { return null; }
                    // Absolute document Y of the element's top.
                    return el.getBoundingClientRect().top + window.scrollY;
                }, false, false, animate);
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
                // A source handoff can supply just a line or fraction. Keep
                // its first settled offset to detect later reader navigation.
                var rememberOffset = !silent && (payload.fromEditor || anchoredScrollY === null);
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
                }, silent, rememberOffset);
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
                releaseReference();
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
                releaseReference();
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
            var lineAttributes = ['data-md2-source-line', 'data-md2-source-end-line', 'data-md2-source-next-line', 'data-md2-task-line'];
            var lineSelector = lineAttributes.map(name => `[${name}]`).join(',');

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
                if (window.__md2FindClear) { window.__md2FindClear(window.__md2ScrollSyncPaused); }
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

            \(PreviewHeldReference.script)

            window.__md2UpdateLivePreview = function (body, options, hold, caretLine) {
                // Capture, reconcile and restore in a single WebKit turn, so
                // input between two asynchronous calls cannot be overwritten.
                var blocks = hold && visibleReferences();
                var y = window.scrollY;
                var anchor = !hold && !caretLine && captureAnchor();
                window.__md2ApplyContent(body, options);
                if (hold) {
                    pinReference(blocks, y);
                } else if (caretLine) {
                    window.__md2FollowEditLine(caretLine);
                } else {
                    anchor.headingId = anchor.id;
                    window.__md2ScrollToViewportAnchor(anchor, true);
                }
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
            forMainFrameOnly: true,
            in: .defaultClient
        ))
        configuration.userContentController.add(context.coordinator, contentWorld: .defaultClient, name: Self.remoteImageMessageName)
        configuration.userContentController.addUserScript(WKUserScript(
            source: PreviewMermaidViewer.script(language: mermaidViewerLanguage),
            injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient
        ))
        configuration.userContentController.add(context.coordinator, contentWorld: .defaultClient,
                                                name: PreviewMermaidViewer.stateMessage)
        Self.installInteractionBridge(on: configuration.userContentController, handler: context.coordinator)
        configuration.userContentController.add(context.coordinator, name: Self.anchorMessageName)
        configuration.userContentController.add(context.coordinator, name: PreviewHeldReference.reloadMessageName)
        configuration.userContentController.add(context.coordinator, name: Self.outlineMarginMessageName)
        configuration.userContentController.add(context.coordinator, contentWorld: .defaultClient, name: Self.selectionMessageName)
        configuration.userContentController.addUserScript(WKUserScript(source: Self.selectionScript,
            injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        configuration.userContentController.add(context.coordinator, contentWorld: .defaultClient,
                                                name: Self.viewportReadyMessageName)
        configuration.userContentController.addUserScript(WKUserScript(
            source: "window.webkit.messageHandlers.\(Self.viewportReadyMessageName).postMessage(null);",
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
        webView.contextMenuAdapter.editParagraph = { [weak coordinator = context.coordinator] hit in
            coordinator?.editParagraph(hit)
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
        registerViewportReader(in: webView, coordinator: context.coordinator)

        return webView
    }

    private func registerViewportReader(in webView: WKWebView, coordinator: Coordinator) {
        viewportReader?.follow = { [weak webView, weak coordinator] line, whenReady in
            guard let webView, let coordinator, coordinator.resourceContextIsActive else { return }
            coordinator.followEditor(to: line, whenReady: whenReady, in: webView)
        }
        viewportReader?.setEditFollow = { [weak coordinator] line in
            guard let coordinator else { return }
            coordinator.editFollowLine = line
            coordinator.editFollowDeadline = line == nil
                ? .distantPast
                : Date().addingTimeInterval(Coordinator.editFollowWindow)
        }
        viewportReader?.changeScrollSync = { [weak webView, weak coordinator] paused, activePane in
            guard let webView, let coordinator else { return }
            coordinator.holdsReadingPosition = paused
            coordinator.resetScrollOwnership(keepLoadingReference: !paused && activePane == .preview)
            webView.evaluateJavaScript("window.__md2ChangeScrollSync?.(\(MarkdownPreviewView.jsBoolean(paused)));")
        }
        viewportReader?.capture = { [weak webView, weak coordinator] whenReady, completion in
            guard let webView, let coordinator, coordinator.resourceContextIsActive else {
                completion(nil)
                return
            }
            if whenReady && (!coordinator.viewportIsReady || coordinator.hasContentInFlight) {
                coordinator.pendingResumeCapture = completion
            } else {
                coordinator.capturePosition(in: webView, completion: completion)
            }
        }
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.invalidateResourceContext(in: webView)
        coordinator.detachFindHost(webView)
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onSelectionChange = onSelectionChange
        context.coordinator.onRemoteImageDetected = onRemoteImageDetected
        let wasObservingOutlineMargin = context.coordinator.onOutlineMarginChange != nil
        context.coordinator.onOutlineMarginChange = onOutlineMarginChange
        if wasObservingOutlineMargin && onOutlineMarginChange == nil {
            context.coordinator.stopObservingOutlineMargin(in: webView)
        }
        if context.coordinator.mermaidViewerLanguage != mermaidViewerLanguage {
            context.coordinator.mermaidViewerLanguage = mermaidViewerLanguage
            if context.coordinator.viewportIsReady { context.coordinator.applyMermaidViewerLanguage(in: webView) }
        }
        context.coordinator.liveUpdate = liveUpdate
        context.coordinator.holdsReadingPosition = holdsReadingPosition
        let revisionChanged = context.coordinator.sourceLineRevision != sourceLineRevision
        let typographyChanged = context.coordinator.typography != typography
        if typographyChanged {
            context.coordinator.typography = typography
            if context.coordinator.viewportIsReady { context.coordinator.applyTypography(in: webView, preservingAnchor: true) }
        }
        context.coordinator.onEnterEdit = onEnterEdit
        context.coordinator.onEditParagraph = onEditParagraph
        context.coordinator.textRevision = textRevision
        context.coordinator.onToggleTask = onToggleTask
        context.coordinator.onRevealSourceLine = onRevealSourceLine
        context.coordinator.onEditFormula = onEditFormula
        context.coordinator.formulaEditing = formulaEditing
        context.coordinator.onOpenMarkdownLink = onOpenMarkdownLink
        context.coordinator.onMissingLocalLink = onMissingLocalLink
        context.coordinator.onOpenWithSystem = onOpenWithSystem
        context.coordinator.onAnchorChange = onAnchorChange
        context.coordinator.onPausedInteraction = onPausedInteraction
        context.coordinator.onFindShortcut = onFindShortcut
        context.coordinator.onFindResult = onFindResult
        context.coordinator.onFindUnavailable = onFindUnavailable
        context.coordinator.findMayRevealMatches = findMayRevealMatches
        context.coordinator.showsFrontMatter = showsFrontMatter
        context.coordinator.showsLineNumbers = showsLineNumbers
        context.coordinator.sourceLineRevision = sourceLineRevision

        if let previewWebView = webView as? PreviewWebView {
            previewWebView.onFindAction = { action in
                context.coordinator.onFindShortcut(action)
            }
            previewWebView.onEscape = onEscape
            previewWebView.contextMenuAdapter.editParagraphTitle = editParagraphTitle
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
        } else if baseURLChanged {
            context.coordinator.invalidateHeldReload()
        }
        guard context.coordinator.resourceContextIsActive else { return }
        registerViewportReader(in: webView, coordinator: context.coordinator)
        context.coordinator.applyFrontMatterVisibility(in: webView)
        context.coordinator.applyLineNumbersVisibility(in: webView)
        if htmlChanged || baseURLChanged || resourceContextChanged {
            // In Side by Side mode, a content-only change (same document, no new
            // diagram engine needed) is applied in place so typing does not
            // reload the page or reset the preview's scroll. Everything else —
            // the initial load, a base-URL/document change, or a new diagram
            // engine that must be loaded — goes through a full load.
            let isLoadedContentUpdate = liveUpdate
                && context.coordinator.viewportIsReady
                && !baseURLChanged
                && !resourceContextChanged
                && !context.coordinator.lastHTML.isEmpty
            // Formula controls are outside the renderer body. Never hand their
            // modified DOM to the renderer's keyed live-content reconciler.
            let canLiveUpdate = isLoadedContentUpdate && formulaEditing == nil && !context.coordinator.hasFormulaControls
                && !Self.requiresNewEngine(newBody: bodyHTML, loadedBody: context.coordinator.lastBody)
            context.coordinator.lastHTML = html
            context.coordinator.lastBody = bodyHTML
            context.coordinator.lastBaseURL = baseURL
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
                context.coordinator.loadLatest(
                    fragment: jumpAnchor?.fallbackHeadingID ?? jumpHeadingID,
                    preservingReference: isLoadedContentUpdate && holdsReadingPosition,
                    in: webView
                )
            }
        } else {
            // Text that renders to the same page is still a new revision.
            context.coordinator.labelPage(in: webView)
            context.coordinator.configureFormulaControls(in: webView)
            if onOutlineMarginChange != nil, !typographyChanged, context.coordinator.isLoaded,
               revisionChanged || !wasObservingOutlineMargin {
                context.coordinator.observeOutlineMargin(in: webView)
            }
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
            context.coordinator.setPendingScroll(scrollRequest, in: webView, animatingHeading: animatesHeadingJump)
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
            // Generated digits stay outside the document text used by Find and Copy.
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
        coordinator.mermaidViewerLanguage = mermaidViewerLanguage
        coordinator.onSelectionChange = onSelectionChange
        coordinator.onEnterEdit = onEnterEdit
        coordinator.onToggleTask = onToggleTask
        coordinator.onRevealSourceLine = onRevealSourceLine
        coordinator.onOpenMarkdownLink = onOpenMarkdownLink
        coordinator.onMissingLocalLink = onMissingLocalLink
        coordinator.onOpenWithSystem = onOpenWithSystem
        return coordinator
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
        var typography: TypographySettings = .init()
        var mermaidViewerLanguage: AppLanguage = .english

        func applyMermaidViewerLanguage(in webView: WKWebView) {
            guard lastBody.contains(PreviewClass.diagramMermaid) else { return }
            webView.evaluateJavaScript(
                "window.__md2SetMermaidViewerLabels?.(\(PreviewMermaidViewer.labels(language: mermaidViewerLanguage)))",
                in: nil, in: .defaultClient, completionHandler: nil
            )
        }
        var onSelectionChange: (String?) -> Void = { _ in }
        var onRemoteImageDetected: (Int) -> Void = { _ in }
        var onOutlineMarginChange: ((CGFloat) -> Void)?
        private var outlineMarginToken: String?

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
            observeOutlineMargin(in: webView)
        }

        /// WebKit applies the reading width asynchronously. Keep the outline
        /// hidden until layout confirms the empty gutter, including any text or
        /// math that spills out of the centered column.
        func observeOutlineMargin(in webView: WKWebView) {
            guard onOutlineMarginChange != nil else { return }
            let token = UUID().uuidString
            outlineMarginToken = token
            webView.evaluateJavaScript("""
            (function () {
                var main = document.querySelector('main');
                if (!main) { return; }
                if (!window.__md2MeasureOutlineMargin) {
                    var token = null;
                    var lastWidth = null;
                    function report() {
                        var rect = main.getBoundingClientRect();
                        var right = rect.left + window.scrollX + Math.max(rect.width, main.scrollWidth);
                        // The actual-size dialog takes the full WebKit viewport,
                        // including the margin normally available to the native outline.
                        var width = document.querySelector('.md2-diagram-viewer[open]') ? 0
                            : Math.floor(document.documentElement.clientWidth - right);
                        if (width === lastWidth) { return; }
                        lastWidth = width;
                        window.webkit.messageHandlers.\(MarkdownPreviewView.outlineMarginMessageName).postMessage({token: token, width: width});
                    }
                    var resizeObserver = new ResizeObserver(report);
                    var mutationObserver = new MutationObserver(report);
                    resizeObserver.observe(main);
                    mutationObserver.observe(main, {childList: true, characterData: true, subtree: true});
                    window.addEventListener('resize', report);
                    document.fonts.addEventListener('loadingdone', report);
                    window.__md2MeasureOutlineMargin = function (nextToken) {
                        token = nextToken;
                        lastWidth = null;
                        report();
                    };
                    window.__md2StopOutlineMargin = function () {
                        resizeObserver.disconnect();
                        mutationObserver.disconnect();
                        window.removeEventListener('resize', report);
                        document.fonts.removeEventListener('loadingdone', report);
                        delete window.__md2MeasureOutlineMargin;
                        delete window.__md2StopOutlineMargin;
                    };
                }
                window.__md2MeasureOutlineMargin('\(token)');
            })();
            """)
        }

        func stopObservingOutlineMargin(in webView: WKWebView) {
            outlineMarginToken = nil
            if isLoaded { webView.evaluateJavaScript("window.__md2StopOutlineMargin?.();") }
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
            invalidateHeldReload()
            pendingEditorFollow = nil
            pendingResumeCapture = nil
            beginLoading()
            documentLoader.invalidate(in: webView)
            (webView as? PreviewWebView)?.invalidateContextMenu()
        }

        func invalidateHeldReload() {
            heldReloadCapture = nil
            pendingHeldReload = nil
        }
        var onEnterEdit: () -> Void = {}
        var onEditParagraph: (PreviewParagraphHit) -> Void = { _ in }
        var textRevision = 0
        private var pageTextRevision: Int?

        func editParagraph(_ hit: PreviewParagraphHit) {
            guard resourceContextIsActive, !hasContentInFlight, hit.revision == pageTextRevision,
                  hit.revision == textRevision else { return }
            onEditParagraph(hit)
        }
        var onToggleTask: (
            _ line: Int, _ checked: Bool, _ revision: Int, _ restoreBoxes: @escaping () -> Void
        ) -> Void = { _, _, _, _ in }
        var onRevealSourceLine: (_ line: Int) -> Void = { _ in }
        var onEditFormula: (_ line: Int, _ revision: Int, _ window: NSWindow) -> Void = { _, _, _ in }
        var formulaEditing: FormulaEditing?
        /// A new token retires messages queued by any earlier page/configuration,
        /// even when two source revisions produce identical rendered HTML.
        private var formulaPage: (config: FormulaEditing, token: String)?
        var hasFormulaControls: Bool { formulaPage != nil }
        private var restoredFormulaFocusRevision: Int?
        var onOpenMarkdownLink: (_ url: URL) -> Void = { _ in }
        var onMissingLocalLink: (_ url: URL) -> Void = { _ in }
        var onOpenWithSystem: (_ url: URL) -> Void = { _ in }
        var onAnchorChange: (_ anchor: ViewportAnchor, _ isUserInitiated: Bool) -> Void = { _, _ in }
        var onPausedInteraction: () -> Void = {}
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
        private(set) var hasContentInFlight = false
        /// True from `beginLoading` until the page of that load commits. A page
        /// that finishes before then is one that load is about to replace.
        private var isAwaitingCommit = false
        var lastFindQuery: String?
        var findMayRevealMatches = true
        var findOptions = TextSearch.Options()
        private var findGeneration = UUID()
        private weak var findHost: WKWebView?
        private var findHostIsActive = true
        private var findInFlight = false
        var onFindUnavailable: (Bool) -> Void = { _ in }
        var lastFocusToken: UUID?

        func updateFocusRequest(_ token: UUID?, state: PreviewFocusState?, in webView: WKWebView) {
            guard resourceContextIsActive, acceptsFindHost(webView) else { return }
            focusState = state
            let changed = lastFocusToken != token
            lastFocusToken = token
            let requested = token.map { changed && (state?.consume($0) ?? true) } ?? false
            guard requested || state?.hasPendingRestoration == true else { return }
            DispatchQueue.main.async { [weak self, weak webView] in
                guard let self, let webView, self.resourceContextIsActive,
                      self.lastFocusToken == token, self.acceptsFindHost(webView),
                      !requested || state == nil || state?.lastConsumedToken == token else { return }
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
        /// Split rendering and navigation can use the committed document as
        /// soon as its viewport helpers exist, even with images still loading.
        var liveUpdate = false
        private(set) var viewportIsReady = false
        /// The mode-switch scroll target. Retained across an immediate apply so a
        /// reload that fires right after entering Side by Side (the preview view
        /// is rebuilt, resetting scroll to the top) re-applies it on `didFinish`
        /// instead of leaving the preview stuck at the top. Consumed by the
        /// post-load apply and cleared once the user scrolls.
        private var pendingScroll: ModeSwitchAnchor?
        private struct HeldReload {
            let id: UUID
            let page: URL
            let window: ObjectIdentifier?
            let resourceContext: UUID?
            var viewportTop: CGFloat?
            var sequence = 0
            var place: [String: Any]?
        }
        private var pendingHeldReload: HeldReload?
        private var heldReloadCapture: UUID?
        private var pendingEditorFollow: Double?
        fileprivate var pendingResumeCapture: ((PreviewViewportReader.Position?) -> Void)?
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
        func resetScrollOwnership(keepLoadingReference: Bool) {
            editFollowLine = nil
            editFollowDeadline = .distantPast
            pendingScroll = nil
            pendingEditorFollow = nil
            pendingResumeCapture = nil
            if !keepLoadingReference { pendingHeldReload = nil }
        }

        func followEditor(to line: Double, whenReady: Bool, in webView: WKWebView) {
            pendingResumeCapture = nil
            if !viewportIsReady || (hasContentInFlight && (whenReady || pendingEditorFollow != nil)) {
                // Continuous scrolling normally waits for the next gesture. A
                // resume is a single request and must survive the engine load.
                if whenReady || pendingEditorFollow != nil { pendingEditorFollow = line }
                return
            }
            pendingEditorFollow = nil
            webView.evaluateJavaScript(
                String(format: "window.__md2FollowToAnchor ? window.__md2FollowToAnchor(%.3f) : null;", line)
            )
        }

        private func completeResumeIfReady(in webView: WKWebView) {
            guard viewportIsReady, !hasContentInFlight else { return }
            if let pendingEditorFollow {
                followEditor(to: pendingEditorFollow, whenReady: true, in: webView)
            } else if let capture = pendingResumeCapture {
                pendingResumeCapture = nil
                capturePosition(in: webView, completion: capture)
            }
        }

        var holdsReadingPosition = false
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
            queueFindAfterContentChange()
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

                let caretLine = Date() < self.editFollowDeadline ? self.editFollowLine : nil
                let hold = MarkdownPreviewView.jsBoolean(self.holdsReadingPosition)
                let script = "window.__md2UpdateLivePreview(\(Self.jsStringLiteral(body)), \(options), \(hold), \(caretLine ?? 0)); true;"
                self.loadedBody = nil
                webView.evaluateJavaScript(script) { [weak self, weak webView] _, error in
                    guard let self, let webView else { return }
                    self.finishLiveContent(generation: generation, error: error, in: webView)
                }
            }
            liveUpdateWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.liveUpdateDebounce, execute: work)
        }

        /// Both update scripts end in a value WebKit can return, so an `error`
        /// means the update threw and the page may still show the old content.
        private func finishLiveContent(generation: Int, error: Error?, in webView: WKWebView) {
            guard error == nil, generation == liveUpdateGeneration else { return }
            hasContentInFlight = false
            // Recheck retained images even when a preferences-only render
            // changed the body without changing its source revision.
            pageRevision = nil
            labelPage(in: webView)
            completeResumeIfReady(in: webView)
            applyPendingFind(in: webView)
        }

        /// Tells the page which source-line revision it shows, for it to send
        /// back with a checkbox click. The label follows its content and never
        /// leads it: a page labelled behind what it shows only gets a click
        /// refused, but one labelled ahead would pass a stale click as current.
        func labelPage(in webView: WKWebView) {
            guard !hasContentInFlight, pageRevision != sourceLineRevision || pageTextRevision != textRevision else { return }
            pageRevision = sourceLineRevision
            pageTextRevision = textRevision
            webView.evaluateJavaScript(
                """
                window.\(MarkdownPreviewView.sourceLineRevisionVariable) = \(sourceLineRevision);
                window.__md2TextRevision = \(textRevision);
                if (window.__md2ReportRemoteImage) { window.__md2ReportRemoteImage(true); }
                true;
                """,
                in: nil, in: .defaultClient
            )
        }

        func configureFormulaControls(in webView: WKWebView) {
            guard !hasContentInFlight, formulaPage?.config != formulaEditing,
                  let pageURL = documentLoader.documentPageURL else { return }
            var payload = "null"
            if let config = formulaEditing {
                let token = UUID().uuidString
                let options: [String: Any] = [
                    "token": token, "editableLines": Array(config.editableLines),
                    "editLabel": config.editLabel, "revealLabel": config.revealLabel
                ]
                guard let data = try? JSONSerialization.data(withJSONObject: options) else { return }
                payload = String(decoding: data, as: UTF8.self)
                formulaPage = (config, token)
            } else {
                formulaPage = nil
            }
            // A commit can arrive ahead of the document-end user script, and
            // slow remote images must not delay controls for visible formulas.
            webView.evaluateJavaScript("""
                if (location.href.split('#')[0] === \(Self.jsStringLiteral(pageURL.absoluteString))) {
                    window.__md2FormulaConfig = \(payload);
                    if (window.__md2SetFormulaControls) { window.__md2SetFormulaControls(window.__md2FormulaConfig); }
                }
                true;
                """, in: nil, in: .defaultClient)
            if isLoaded { restoreFormulaFocus(in: webView) }
        }

        private func restoreFormulaFocus(in webView: WKWebView) {
            guard let page = formulaPage, let line = page.config.focusLine,
                  page.config.revision != restoredFormulaFocusRevision,
                  let window = webView.window, window.isKeyWindow,
                  let responder = window.firstResponder as? NSView,
                  responder === webView || responder.isDescendant(of: webView) else { return }
            restoredFormulaFocusRevision = page.config.revision
            webView.evaluateJavaScript("window.__md2FocusFormula ? window.__md2FocusFormula(\(Self.jsStringLiteral(page.token)), \(line)) : false;",
                                       in: nil, in: .defaultClient)
        }

        private func restoreTaskBoxes(in webView: WKWebView?) {
            webView?.evaluateJavaScript(MarkdownPreviewView.restoreTaskBoxesScript, in: nil, in: .defaultClient)
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

        /// Give a busy WebKit process a short window to answer before
        /// restoring the cached anchor. Capture remains asynchronous.
        private static let captureTimeout: TimeInterval = 0.5
        private var pendingCaptureID = 0
        private var pendingCaptureCompletion: ((PreviewViewportReader.Position?) -> Void)?
        private var captureTimeoutWorkItem: DispatchWorkItem?

        /// Asks the live page for a fresh viewport anchor, completing with
        /// `nil` after a short timeout so a switch is never blocked by a page
        /// that is still loading or running heavy engine scripts.
        func capturePosition(in webView: WKWebView, includeReference: Bool = false, completion: @escaping (PreviewViewportReader.Position?) -> Void) {
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

            let capture: String
            if includeReference, let reload = pendingHeldReload {
                let page = Self.jsStringLiteral(reload.page.absoluteString)
                capture = "({ ...window.__md2CaptureAnchor(), heldReference: window.__md2BeginHeldReload('\(reload.id.uuidString)', \(page)) })"
            } else {
                capture = "window.__md2CaptureAnchor?.()"
            }
            webView.evaluateJavaScript(capture) { [weak self] result, _ in
                let position = (result as? [String: Any]).map {
                    PreviewViewportReader.Position(
                        anchor: Self.viewportAnchor(fromMessage: $0),
                        movedFromAnchor: $0["movedFromAnchor"] as? Bool == true,
                        heldReference: $0["heldReference"] as? [String: Any]
                    )
                }
                self?.finishCapture(captureID, with: position)
            }
        }

        private func finishCapture(_ captureID: Int, with position: PreviewViewportReader.Position?) {
            guard captureID == pendingCaptureID,
                  let completion = pendingCaptureCompletion else { return }
            pendingCaptureCompletion = nil
            captureTimeoutWorkItem?.cancel()
            captureTimeoutWorkItem = nil
            completion(position)
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
            outlineMarginToken = nil
            queueFindAfterContentChange()
            isLoaded = false
            viewportIsReady = false
            isAwaitingCommit = true
            hasContentInFlight = true
            formulaPage = nil
            liveUpdateGeneration += 1
            liveUpdateWorkItem?.cancel()
            pendingLiveBody = nil
            pendingLiveImages = [:]
        }

        /// Capture the old page before a new diagram engine replaces its DOM.
        /// Edits arriving during capture coalesce into the latest full load.
        func loadLatest(fragment: String?, preservingReference: Bool, in webView: WKWebView) {
            guard heldReloadCapture == nil else { return }
            (webView as? PreviewWebView)?.invalidateContextMenu()
            if preservingReference, let page = documentLoader.documentPageURL {
                let token = UUID()
                heldReloadCapture = token
                pendingHeldReload = HeldReload(id: token, page: page, window: webView.window.map(ObjectIdentifier.init),
                                               resourceContext: remoteResourceContextToken,
                                               viewportTop: Self.viewportTop(in: webView))
                capturePosition(in: webView, includeReference: true) { [weak self, weak webView] position in
                    guard let self, let webView, self.resourceContextIsActive,
                          self.heldReloadCapture == token else { return }
                    self.heldReloadCapture = nil
                    if self.pendingHeldReload?.id == token, self.pendingHeldReload?.sequence == 0,
                       self.holdsReadingPosition || self.pendingEditorFollow == nil {
                        self.pendingHeldReload?.place = position?.heldReference
                    }
                    self.loadLatest(fragment: fragment, preservingReference: false, in: webView)
                }
            } else {
                documentLoader.load(lastHTML, baseURL: lastBaseURL, fragment: fragment,
                                    remoteResourcePolicy: remoteResourcePolicy, in: webView)
            }
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
            invalidateHeldReload()
            (webView as? PreviewWebView)?.invalidateContextMenu()
            capturePosition(in: webView) { [weak self, weak webView] position in
                guard let self, let webView, self.resourceContextIsActive else { return }
                let place = self.isLoaded ? position?.anchor : nil
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

        private func queueFindAfterContentChange() {
            findGeneration = UUID()
            findInFlight = false
            if pendingFindQuery == nil { pendingFindQuery = lastFindQuery }
        }

        /// Runs a preview search immediately when the page is ready, otherwise
        /// remembers the latest query and applies it after `didFinish`.
        func runFindWhenReady(_ query: String, in webView: WKWebView) {
            guard acceptsFindHost(webView) else { return }
            pendingFindQuery = query
            findGeneration = UUID()
            applyPendingFind(in: webView)
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
            guard viewportIsReady else { return }
            webView.evaluateJavaScript(
                "window.__md2SetFrontMatterVisible ? window.__md2SetFrontMatterVisible(\(MarkdownPreviewView.jsBoolean(showsFrontMatter))) : null;"
            )
        }

        /// Flips the preview gutter's switch class. Toggling never reloads or
        /// re-renders the document — the layer is already built, and the numbers
        /// are generated content, so showing them is a class change.
        func applyLineNumbersVisibility(in webView: WKWebView) {
            guard viewportIsReady else { return }
            webView.evaluateJavaScript(
                "window.__md2SetLineNumbersVisible ? window.__md2SetLineNumbersVisible(\(MarkdownPreviewView.jsBoolean(showsLineNumbers))) : null;"
            )
        }

        private func messageIsFromCurrentPage(_ message: WKScriptMessage) -> Bool {
            guard let documentURL = documentLoader.documentPageURL else { return false }
            return messagePage(message) == documentURL
        }

        private func messagePage(_ message: WKScriptMessage) -> URL? {
            guard let frameURL = message.frameInfo.request.url else { return nil }
            var page = URLComponents(url: frameURL.absoluteURL, resolvingAgainstBaseURL: false)
            page?.fragment = nil
            return page?.url
        }

        private func messageIsFromOutgoingPage(_ message: WKScriptMessage, in webView: WKWebView) -> Bool {
            guard let reload = pendingHeldReload else { return false }
            return reload.page == messagePage(message) && reload.window == webView.window.map(ObjectIdentifier.init)
                && reload.resourceContext == remoteResourceContextToken
        }

        private static func viewportTop(in webView: WKWebView) -> CGFloat? {
            guard let window = webView.window else { return nil }
            let bounds = webView.bounds
            let top = NSPoint(x: bounds.midX, y: webView.isFlipped ? bounds.minY : bounds.maxY)
            // Measure from the window's top edge so moving the window or
            // resizing from the bottom does not move the preview within it.
            return window.convertPoint(toScreen: webView.convert(top, to: nil)).y - window.frame.maxY
        }

        fileprivate func noteHeldReloadScrollbarDrag(in webView: WKWebView) {
            let reload = pendingHeldReload
            guard resourceContextIsActive, holdsReadingPosition || reload != nil, acceptsFindHost(webView),
                  let page = reload?.page ?? documentLoader.documentPageURL else { return }
            if let reload {
                guard reload.window == webView.window.map(ObjectIdentifier.init),
                      reload.resourceContext == remoteResourceContextToken else { return }
            }
            let token = reload.map { "'\($0.id.uuidString)'" } ?? "null"
            let url = Self.jsStringLiteral(page.absoluteString)
            webView.evaluateJavaScript("window.__md2NoteHeldReloadScrollbarDrag?.(\(token), \(url));")
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard resourceContextIsActive, message.frameInfo.isMainFrame else { return }
            switch message.name {
            case MarkdownPreviewView.viewportReadyMessageName:
                guard liveUpdate, !isAwaitingCommit, documentLoader.currentNavigation != nil,
                      message.world == .defaultClient, messageIsFromCurrentPage(message),
                      let webView = message.webView, acceptsFindHost(webView) else { return }
                prepareViewportIfNeeded(in: webView)
            case MarkdownPreviewView.remoteImageMessageName:
                guard message.world == .defaultClient, !hasContentInFlight,
                      let webView = message.webView, acceptsFindHost(webView),
                      messageIsFromCurrentPage(message),
                      let revision = message.body as? Int, revision == pageRevision else { return }
                onRemoteImageDetected(revision)
            case PreviewMermaidViewer.stateMessage:
                guard message.world == .defaultClient, let webView = message.webView as? PreviewWebView,
                      acceptsFindHost(webView), let open = message.body as? Bool else { return }
                webView.mermaidViewerOpen = open
            case MarkdownPreviewView.selectionMessageName:
                guard message.world == .defaultClient else { return }
                onSelectionChange(message.body as? String)
            case MarkdownPreviewView.enterEditMessageName:
                guard message.world == .defaultClient, let webView = message.webView, acceptsFindHost(webView),
                      let data = message.body as? [String: Any] else { return }
                if let hit = PreviewParagraphHit(data) {
                    editParagraph(hit)
                } else if !hasContentInFlight, data["background"] as? Bool == true,
                          let revision = data["revision"] as? Int, revision == pageTextRevision, revision == textRevision {
                    onEnterEdit()
                }
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
            case MarkdownPreviewView.editFormulaMessageName:
                guard message.world == .defaultClient, !hasContentInFlight,
                      let webView = message.webView, acceptsFindHost(webView), let window = webView.window,
                      let page = formulaPage, page.config == formulaEditing,
                      let body = message.body as? [String: Any], body["token"] as? String == page.token,
                      let line = body["line"] as? Int, line > 0 else { return }
                onEditFormula(line, page.config.revision, window)
            case MarkdownPreviewView.anchorMessageName:
                guard message.world == .page, let webView = message.webView, acceptsFindHost(webView),
                      let body = message.body as? [String: Any] else { return }
                if body["interaction"] as? Bool == true {
                    if holdsReadingPosition && (messageIsFromCurrentPage(message) || messageIsFromOutgoingPage(message, in: webView)) {
                        onPausedInteraction()
                    }
                    return
                }
                // The outgoing viewport has its own content-based handoff.
                // A debounced report from it cannot clear that newer position.
                guard messageIsFromCurrentPage(message), !messageIsFromOutgoingPage(message, in: webView) else { return }
                let isUserInitiated = (body["user"] as? NSNumber)?.boolValue ?? false
                if ignoreNextAnchorMessage {
                    ignoreNextAnchorMessage = false
                    if !isUserInitiated { return }
                }
                // Once the user scrolls the preview themselves, a retained
                // mode-switch target must not snap them back on a later reload.
                if isUserInitiated {
                    pendingScroll = nil
                    pendingEditorFollow = nil
                    pendingHeldReload = nil
                }
                onAnchorChange(Self.viewportAnchor(fromMessage: body), isUserInitiated)
            case PreviewHeldReference.reloadMessageName:
                guard message.world == .page, let webView = message.webView, acceptsFindHost(webView),
                      messageIsFromOutgoingPage(message, in: webView), var reload = pendingHeldReload,
                      let body = message.body as? [String: Any], body["token"] as? String == reload.id.uuidString,
                      let sequence = body["sequence"] as? Int, sequence > reload.sequence,
                      let place = body["place"] as? [String: Any] else { return }
                reload.sequence = sequence
                reload.place = place
                reload.viewportTop = Self.viewportTop(in: webView)
                pendingHeldReload = reload
            case MarkdownPreviewView.outlineMarginMessageName:
                guard isLoaded, message.world == .page, let outlineMarginToken,
                      let body = message.body as? [String: Any], body["token"] as? String == outlineMarginToken,
                      let width = (body["width"] as? NSNumber)?.doubleValue, width.isFinite else { return }
                onOutlineMarginChange?(CGFloat(width))
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

        /// Applies the scroll target when the current page's viewport is ready.
        func setPendingScroll(_ anchor: ModeSwitchAnchor, in webView: WKWebView, animatingHeading: Bool = false) {
            pendingScroll = anchor
            pendingEditorFollow = nil
            pendingResumeCapture = nil
            if viewportIsReady {
                // Apply now, but KEEP the target: entering Side by Side rebuilds
                // the preview view, triggering a reload that resets scroll to the
                // top right after this. Retaining `pendingScroll` lets the
                // post-reload `didFinish` re-apply it.
                applyPendingScroll(in: webView, consume: false, animatingHeading: animatingHeading)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Taken for loaded, a page on its way out would receive an edit that
            // the load then overwrites with older text.
            guard resourceContextIsActive, !isAwaitingCommit,
                  documentLoader.currentNavigation == nil || navigation === documentLoader.currentNavigation else { return }
            isLoaded = true
            prepareViewportIfNeeded(in: webView)
            applyPendingFind(in: webView)
            restoreFormulaFocus(in: webView)
        }

        private func prepareViewportIfNeeded(in webView: WKWebView) {
            guard !viewportIsReady else { return }
            viewportIsReady = true
            applyTypography(in: webView)
            applyFrontMatterVisibility(in: webView)
            applyMermaidViewerLanguage(in: webView)
            applyLineNumbersVisibility(in: webView)
            if holdsReadingPosition { webView.evaluateJavaScript("window.__md2ChangeScrollSync?.(true);") }
            if pendingScroll == nil, pendingEditorFollow == nil, let reload = pendingHeldReload, let place = reload.place,
               let page = documentLoader.documentPageURL, page != reload.page,
               reload.window == webView.window.map(ObjectIdentifier.init), reload.resourceContext == remoteResourceContextToken {
                let viewportRise = if let oldTop = reload.viewportTop, let newTop = Self.viewportTop(in: webView) {
                    Double((newTop - oldTop) / webView.pageZoom)
                } else {
                    0.0
                }
                webView.callAsyncJavaScript("""
                    if (location.href.split('#')[0] === page) { window.__md2RestoreReference?.(place, viewportRise); }
                    """, arguments: ["place": place, "page": page.absoluteString, "viewportRise": viewportRise], in: nil, in: .page,
                                            completionHandler: nil)
            }
            pendingHeldReload = nil
            applyPendingScroll(in: webView, consume: true)
            completeResumeIfReady(in: webView)
            if holdsReadingPosition && findMayRevealMatches { applyPendingFind(in: webView) }
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            guard resourceContextIsActive else { return }
            (webView as? PreviewWebView)?.invalidateContextMenu()
            (webView as? PreviewWebView)?.mermaidViewerOpen = false
            // Label it now: `didFinish` waits for every image, and the boxes work
            // from the end of parsing. A page some newer load will replace stays
            // unlabelled, so its clicks are refused.
            guard navigation === documentLoader.currentNavigation else { return }
            isLoaded = false
            viewportIsReady = false
            isAwaitingCommit = false
            hasContentInFlight = false
            pageRevision = nil
            labelPage(in: webView)
            configureFormulaControls(in: webView)
        }

        private func applyPendingScroll(in webView: WKWebView, consume: Bool = true, animatingHeading: Bool = false) {
            guard let anchor = pendingScroll else { return }
            if consume { pendingScroll = nil }

            switch anchor {
            case let .viewport(viewport):
                webView.evaluateJavaScript(
                    "window.__md2ScrollToViewportAnchor(\(Self.viewportAnchorJS(viewport)));"
                )
            case let .heading(id):
                let escapedID = MarkdownPreviewView.escapeForJS(id)
                webView.evaluateJavaScript("window.__md2ScrollToHeading('\(escapedID)', \(MarkdownPreviewView.jsBoolean(animatingHeading))); ")
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
                "fraction": anchor.scrollFraction,
                "fromEditor": anchor.editorPosition != nil
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
            // A paused, visible Find result can be restored once the new page
            // is interactive, including while an image is still downloading.
            guard isLoaded || (holdsReadingPosition && findMayRevealMatches && viewportIsReady),
                  !hasContentInFlight, acceptsFindHost(webView), let query = pendingFindQuery else { return }
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
                    let payload: [String: Any] = ["id": id, "ranges": ranges ?? [], "unavailable": ranges == nil,
                                                  "caseSensitive": options.caseSensitive, "wholeWord": options.wholeWord]
                    guard let data = try? JSONSerialization.data(withJSONObject: payload),
                          let json = String(data: data, encoding: .utf8) else {
                        self.completeFind(nil, generation: generation, in: webView)
                        return
                    }
                    let reveal = MarkdownPreviewView.jsBoolean(self.findMayRevealMatches)
                    self.finishFind(script: "window.__md2Find('\(MarkdownPreviewView.escapeForJS(query))', \(json), \(reveal));", generation: generation, in: webView)
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
    private var primaryDragY: CGFloat?

    fileprivate func invalidateContextMenu() {
        contextMenuInput.invalidate()
        contextMenuAdapter.invalidate()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window {
            primaryDragY = nil
            invalidateContextMenu()
        }
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
        primaryDragY = event.locationInWindow.y
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        primaryDragY = nil
        super.mouseUp(with: event)
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
        let previousY = primaryDragY
        let y = event.locationInWindow.y
        primaryDragY = y
        // The scrollbar can consume drag events before they reach the DOM.
        if let previousY, y != previousY {
            (navigationDelegate as? MarkdownPreviewView.Coordinator)?.noteHeldReloadScrollbarDrag(in: self)
        }
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
                                         page: page, paragraph: PreviewParagraphHit(data["paragraph"]))
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

    fileprivate var mermaidViewerOpen = false

    private func dismissPreviewControl() -> Bool {
        if mermaidViewerOpen {
            evaluateJavaScript("window.__md2CloseMermaidViewer?.()", in: nil, in: .defaultClient, completionHandler: nil)
            return true
        }
        return onEscape?() == true
    }

    private static let escapeKeyCode: UInt16 = 53

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        contextMenuInput.invalidate()
        // Esc travels as a plain key press; claim it only when the owner
        // actually consumed it (dismissed a find bar), so full-screen exit
        // and other system uses keep working.
        if event.keyCode == Self.escapeKeyCode, dismissPreviewControl() {
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
        _ = dismissPreviewControl()
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
