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
    let baseURL: URL?
    /// When true (Side by Side mode), content-only changes are applied in place
    /// via `__md2ApplyContent` — preserving scroll position and avoiding the
    /// full-page reload flash — instead of reloading the web view.
    var liveUpdate: Bool = false
    /// Whether the preview should show a rendered leading YAML front-matter block.
    /// The shared renderer still emits it; this is a preview-only visibility state.
    var showsFrontMatter: Bool = true
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
    /// line to rewrite and the absolute state the checkbox now shows.
    var onToggleTask: (_ line: Int, _ checked: Bool) -> Void = { _, _ in }
    /// Called when the user clicks a link to a local Markdown file, so the app
    /// can open it in a document window (the preview itself never navigates).
    var onOpenMarkdownLink: (_ url: URL) -> Void = { _ in }
    /// The current find query; running search whenever it changes.
    @Binding var findQuery: String
    /// A next/previous navigation request; consumed (set to nil) once applied.
    @Binding var findNavigation: FindCommand?
    /// Changes whenever the preview surface should become first responder.
    let focusToken: UUID
    /// Called when the web view receives a standard Find key/menu action before
    /// SwiftUI commands can route it through `DocumentStore`.
    var onFindShortcut: (_ action: FindCommand.Action) -> Void = { _ in }
    /// Reports match count and the 1-based index of the current match (0 when
    /// there are none) back to the find bar.
    var onFindResult: (_ total: Int, _ index: Int) -> Void = { _, _ in }
    /// Localized labels shown in preview-only broken-image placeholders. The
    /// failed path/URL is appended at runtime as text.
    var localImageMissingLabel: String = "Image not found"
    var remoteImageUnavailableLabel: String = "Remote image could not be loaded"
    var genericImageLoadFailedLabel: String = "Image could not be loaded"

    private static let enterEditMessageName = "enterEdit"
    private static let anchorMessageName = "anchorChange"
    private static let toggleTaskMessageName = "toggleTask"

    /// Filename pieces for the temporary preview file written alongside the
    /// document (kept in the document directory so relative image paths resolve
    /// under the granted read access).
    private static let previewFilePrefix = ".md2-preview-"
    private static let previewFileSuffix = ".html"
    /// Preview files older than this are treated as leftovers from a prior
    /// session/crash and swept. The age gate keeps a live sibling window's file
    /// (rewritten on every render) safe.
    private static let stalePreviewAge: TimeInterval = 3600
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.setURLSchemeHandler(
            context.coordinator.localImageSchemeHandler,
            forURLScheme: LocalImageSchemeHandler.scheme
        )

        // Forward Cmd+double-click in the rendered page back to native so the
        // surrounding view can switch into edit mode. Also report the heading at
        // the top of the viewport (debounced) so a mode switch can anchor to it,
        // and expose reflow-resilient scroll helpers the native side invokes
        // after a mode switch.
        let source = """
        document.addEventListener('dblclick', function(event) {
            if (event.metaKey) {
                window.webkit.messageHandlers.\(Self.enterEditMessageName).postMessage(null);
            }
        });
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
        // Task checkboxes are the preview's one interactive element: the click
        // toggles the box optimistically, and native rewrites the source line
        // (the re-render that follows is the authoritative state).
        document.addEventListener('click', function (event) {
            var box = event.target;
            if (!box || box.tagName !== 'INPUT' || !box.hasAttribute('data-md2-task-line')) { return; }
            var line = parseInt(box.getAttribute('data-md2-task-line'), 10);
            if (isNaN(line)) { return; }
            window.webkit.messageHandlers.\(Self.toggleTaskMessageName).postMessage({
                line: line,
                checked: !!box.checked
            });
        });
        (function () {
            var style = document.createElement('style');
            style.textContent = 'html.md2-hide-front-matter .front-matter{display:none!important;}';
            document.head.appendChild(style);
            window.__md2SetFrontMatterVisible = function (visible) {
                document.documentElement.classList.toggle('md2-hide-front-matter', !visible);
            };
            window.__md2SetFrontMatterVisible(\(Self.jsBoolean(showsFrontMatter)));
        })();
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
                requestAnimationFrame(step);
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

            // Live preview content swap: replaces the rendered content inside
            // <main> in place (without reloading the page), then re-runs the
            // math and diagram bootstraps over the new subtree. Because the
            // page shell and scroll node are never torn down, the viewport's
            // scroll position is preserved across edits. The native side only
            // routes an update through here when no new diagram engine is
            // required (otherwise it does a full reload that rebuilds <head>),
            // so the render hooks below exist whenever there is content to
            // render.
            window.__md2ApplyContent = function (bodyHTML) {
                var main = document.querySelector('main');
                if (!main) { return; }
                if (window.__md2FindClear) { window.__md2FindClear(); }
                main.innerHTML = bodyHTML;
                if (window.__md2RenderMath) { window.__md2RenderMath(main); }
                if (window.__md2RenderDiagrams) { window.__md2RenderDiagrams(main); }
            };

            // --- Find (preview, read-only) --------------------------------
            // Walks text nodes and wraps case-insensitive matches in <mark>
            // elements so they can be highlighted and scrolled to. Returns
            // {total, index} so the native find bar can show "i / n". The
            // current match also gets a distinct class. `__md2FindActive`
            // briefly suppresses anchor reporting so programmatic scrolling to a
            // match is not captured as the user's mode-switch anchor.
            var findMarks = [];
            var findCurrent = -1;
            window.__md2FindActive = false;

            (function ensureFindStyle() {
                var style = document.createElement('style');
                style.textContent =
                    'mark.md2-find{background:#ffe066;color:inherit;border-radius:2px;}' +
                    'mark.md2-find-current{background:#ff9f1c;}';
                document.head.appendChild(style);
            })();

            function clearFind() {
                for (var i = 0; i < findMarks.length; i++) {
                    var m = findMarks[i];
                    var parent = m.parentNode;
                    if (!parent) { continue; }
                    parent.replaceChild(document.createTextNode(m.textContent), m);
                    parent.normalize();
                }
                findMarks = [];
                findCurrent = -1;
            }
            window.__md2FindClear = clearFind;

            function setCurrent(index) {
                if (findMarks.length === 0) { return { total: 0, index: 0 }; }
                if (findCurrent >= 0 && findCurrent < findMarks.length) {
                    findMarks[findCurrent].classList.remove('md2-find-current');
                }
                findCurrent = ((index % findMarks.length) + findMarks.length) % findMarks.length;
                var el = findMarks[findCurrent];
                el.classList.add('md2-find-current');
                window.__md2FindActive = true;
                el.scrollIntoView({ block: 'center', inline: 'nearest' });
                clearTimeout(window.__md2FindTimer);
                window.__md2FindTimer = setTimeout(function () {
                    window.__md2FindActive = false;
                }, 400);
                return { total: findMarks.length, index: findCurrent + 1 };
            }

            window.__md2Find = function (query) {
                clearFind();
                if (!query) { return { total: 0, index: 0 }; }
                var lower = query.toLowerCase();
                var walker = document.createTreeWalker(
                    document.body, NodeFilter.SHOW_TEXT, {
                        acceptNode: function (node) {
                            if (!node.nodeValue) { return NodeFilter.FILTER_REJECT; }
                            var p = node.parentNode;
                            if (p && (p.tagName === 'SCRIPT' || p.tagName === 'STYLE' ||
                                      p.tagName === 'MARK')) {
                                return NodeFilter.FILTER_REJECT;
                            }
                            return node.nodeValue.toLowerCase().indexOf(lower) >= 0
                                ? NodeFilter.FILTER_ACCEPT
                                : NodeFilter.FILTER_REJECT;
                        }
                    }
                );
                var targets = [];
                var n;
                while ((n = walker.nextNode())) { targets.push(n); }

                for (var t = 0; t < targets.length; t++) {
                    var node = targets[t];
                    var text = node.nodeValue;
                    var lowerText = text.toLowerCase();
                    var frag = document.createDocumentFragment();
                    var from = 0;
                    var at;
                    while ((at = lowerText.indexOf(lower, from)) >= 0) {
                        if (at > from) {
                            frag.appendChild(document.createTextNode(text.slice(from, at)));
                        }
                        var mark = document.createElement('mark');
                        mark.className = 'md2-find';
                        mark.textContent = text.slice(at, at + query.length);
                        frag.appendChild(mark);
                        findMarks.push(mark);
                        from = at + query.length;
                    }
                    if (from < text.length) {
                        frag.appendChild(document.createTextNode(text.slice(from)));
                    }
                    node.parentNode.replaceChild(frag, node);
                }

                if (findMarks.length === 0) { return { total: 0, index: 0 }; }
                return setCurrent(0);
            };

            window.__md2FindNext = function (forward) {
                if (findMarks.length === 0) { return { total: 0, index: 0 }; }
                return setCurrent(findCurrent + (forward ? 1 : -1));
            };

            // --- Broken image diagnostics (preview only) ------------------
            // This script is injected only into the preview web view, never into
            // the shared rendered HTML, so exported PDFs/prints are unaffected.
            // A single capture-phase listener catches <img> load failures even
            // after a live innerHTML content swap, because error events do not
            // bubble (capture is required) and a delegated listener outlives the
            // per-keystroke <main> rebuild that replaces individual <img> nodes.
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

                window.addEventListener('error', function (event) {
                    var img = event.target;
                    if (!img || img.tagName !== 'IMG') { return; }
                    if (img.getAttribute('data-md2-broken') === '1') { return; }
                    var src = img.getAttribute('src') || '';
                    var lower = src.trim().toLowerCase();
                    var labelText = '\(Self.escapeForJS(genericImageLoadFailedLabel))';
                    if (/^https?:/.test(lower)) {
                        labelText = '\(Self.escapeForJS(remoteImageUnavailableLabel))';
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
            })();
        })();
        """
        let userScript = WKUserScript(
            source: source,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        configuration.userContentController.addUserScript(userScript)
        configuration.userContentController.add(context.coordinator, name: Self.enterEditMessageName)
        configuration.userContentController.add(context.coordinator, name: Self.anchorMessageName)
        configuration.userContentController.add(context.coordinator, name: Self.toggleTaskMessageName)

        let webView = PreviewWebView(frame: .zero, configuration: configuration)
        webView.onFindAction = { action in
            context.coordinator.onFindShortcut(action)
        }
        webView.onEscape = onEscape
        // The link policy below never lets the page navigate away from the
        // document, so there is no history for a swipe to traverse.
        webView.allowsBackForwardNavigationGestures = false
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")

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

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onEnterEdit = onEnterEdit
        context.coordinator.onToggleTask = onToggleTask
        context.coordinator.onOpenMarkdownLink = onOpenMarkdownLink
        context.coordinator.onAnchorChange = onAnchorChange
        context.coordinator.onFindShortcut = onFindShortcut
        context.coordinator.onFindResult = onFindResult
        context.coordinator.showsFrontMatter = showsFrontMatter

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
        context.coordinator.applyFrontMatterVisibility(in: webView)
        if htmlChanged || baseURLChanged {
            // In Side by Side mode, a content-only change (same document, no new
            // diagram engine needed) is applied in place so typing does not
            // reload the page or reset the preview's scroll. Everything else —
            // the initial load, a base-URL/document change, or a new diagram
            // engine that must be inlined into <head> — goes through a full load.
            let isLoadedContentUpdate = liveUpdate
                && context.coordinator.isLoaded
                && !baseURLChanged
                && !context.coordinator.lastHTML.isEmpty
            let canLiveUpdate = liveUpdate
                && context.coordinator.isLoaded
                && !baseURLChanged
                && !context.coordinator.lastHTML.isEmpty
                && !Self.requiresNewEngine(newBody: bodyHTML, loadedBody: context.coordinator.lastBody)
            context.coordinator.lastHTML = html
            context.coordinator.lastBody = bodyHTML
            context.coordinator.lastBaseURL = baseURL
            context.coordinator.lastFindQuery = nil

            if canLiveUpdate {
                context.coordinator.applyLiveContent(bodyHTML, in: webView)
            } else {
                if isLoadedContentUpdate {
                    context.coordinator.suppressNextAnchorMessage()
                }
                context.coordinator.beginLoading()
                // Load with the pending heading as a URL fragment so WebKit scrolls
                // to it natively during parsing. This is the only thing that can
                // position the page before the inlined diagram/math engine scripts
                // finish executing (which blocks all JavaScript, including our own
                // scroll code, for several seconds on engine-heavy documents). A
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
        }

        // Anchor/heading/fraction targets are also applied once the page has
        // finished loading, which re-affirms the position after async rendering
        // reflows the layout. On a fresh mode switch the web view is still
        // loading when the binding arrives, so the coordinator holds the target
        // and applies it on `didFinish`; if already loaded it applies immediately.
        if let jumpAnchor {
            context.coordinator.setPendingScroll(.viewport(jumpAnchor), in: webView)
            self.jumpAnchor = nil
            self.jumpHeadingID = nil
            self.jumpFraction = nil
        } else if let jumpHeadingID {
            context.coordinator.setPendingScroll(.heading(id: jumpHeadingID), in: webView)
            self.jumpHeadingID = nil
            self.jumpFraction = nil
        } else if let jumpFraction {
            context.coordinator.setPendingScroll(.fraction(jumpFraction), in: webView)
            self.jumpHeadingID = nil
            self.jumpFraction = nil
        }

        if context.coordinator.lastFindQuery != findQuery {
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

        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            DispatchQueue.main.async {
                webView.window?.makeFirstResponder(webView)
            }
        }
    }

    /// Highlights all matches of `query` and reports the JavaScript result.
    private static func evaluateFind(
        _ query: String,
        in webView: WKWebView,
        completion: @escaping (Any?) -> Void
    ) {
        let escaped = Self.escapeForJS(query)
        webView.evaluateJavaScript("window.__md2Find('\(escaped)');") { result, _ in
            completion(result)
        }
    }

    /// Whether `newBody` needs a diagram engine that the currently-loaded page
    /// (built from `loadedBody`) does not have inlined. Diagram engine scripts
    /// are only injected into `<head>` for the diagram kinds present at load, so
    /// a live in-place content swap cannot introduce a new kind; that case must
    /// fall back to a full reload. KaTeX is always inlined, so math never forces
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
        coordinator.onEnterEdit = onEnterEdit
        coordinator.onToggleTask = onToggleTask
        coordinator.onOpenMarkdownLink = onOpenMarkdownLink
        return coordinator
    }

    /// Loads the rendered HTML into the web view.
    ///
    /// `loadHTMLString(_:baseURL:)` does not grant the web view file-system access.
    /// Local images are therefore resolved and whitelisted by the rewriter below;
    /// for other relative page resources, a file-backed document is loaded from a
    /// temporary HTML file beside the source document with directory read access.
    private func load(_ html: String, baseURL: URL?, fragment: String?, in webView: WKWebView, coordinator: Coordinator) {
        let rewritten = LocalImageHTMLRewriter.rewrite(html, baseURL: baseURL)
        coordinator.localImageSchemeHandler.setAllowedImages(rewritten.allowedImages)

        guard let baseURL, baseURL.isFileURL else {
            webView.loadHTMLString(rewritten.html, baseURL: baseURL)
            return
        }

        let previewURL = baseURL.appendingPathComponent(
            "\(Self.previewFilePrefix)\(coordinator.previewID)\(Self.previewFileSuffix)"
        )
        do {
            if let previous = coordinator.previewFileURL, previous != previewURL {
                try? FileManager.default.removeItem(at: previous)
            }
            sweepStalePreviewFiles(in: baseURL, keeping: previewURL)
            try rewritten.html.write(to: previewURL, atomically: true, encoding: .utf8)
            coordinator.previewFileURL = previewURL
            // Local images, including `../` paths outside the document directory,
            // are rewritten to a preview-local scheme whose handler serves only
            // the exact files referenced by this render. The document-directory
            // grant remains available for other relative page resources.
            // The request URL carries the anchor fragment so the browser scrolls
            // to it as the DOM is built. A per-load query token keeps every
            // request URL distinct: reloading the same preview file with only a
            // fragment appended would otherwise be a same-document navigation —
            // WebKit just scrolls, never re-reads the file, and `didFinish`
            // never fires — leaving the page showing stale content.
            let request = URLRequest(
                url: fragmentURL(previewURL, fragment: fragment, loadToken: coordinator.nextLoadToken())
            )
            webView.loadFileRequest(request, allowingReadAccessTo: baseURL)
        } catch {
            webView.loadHTMLString(rewritten.html, baseURL: baseURL)
        }
    }

    /// Removes stale `.md2-preview-*.html` leftovers in `directory` — files this
    /// app wrote in a prior session that a normal teardown would have cleaned but
    /// a crash/force-quit left behind. Never removes `keeping` (the file about to
    /// be loaded) or any file modified within `stalePreviewAge`, so a live sibling
    /// window's preview file is left intact.
    private func sweepStalePreviewFiles(in directory: URL, keeping: URL) {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: []
        ) else {
            return
        }

        let cutoff = Date().addingTimeInterval(-Self.stalePreviewAge)
        for url in entries {
            let name = url.lastPathComponent
            guard name.hasPrefix(Self.previewFilePrefix),
                  name.hasSuffix(Self.previewFileSuffix),
                  url != keeping else {
                continue
            }

            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if let modified, modified > cutoff {
                continue
            }

            try? fileManager.removeItem(at: url)
        }
    }

    /// Builds the load-request URL: the preview file plus a uniqueness query
    /// token (see the call site) and, if provided, a percent-encoded fragment.
    private func fragmentURL(_ url: URL, fragment: String?, loadToken: Int) -> URL {
        var absolute = url.absoluteString + "?md2r=\(loadToken)"
        if let fragment,
           let encoded = fragment.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) {
            absolute += "#" + encoded
        }
        return URL(string: absolute) ?? url
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
        var lastHTML = ""
        /// The last `<main>` content applied (via full load or live swap), used
        /// to decide whether an update can be a live in-place swap.
        var lastBody = ""
        var lastBaseURL: URL?
        let previewID = UUID().uuidString
        var previewFileURL: URL?
        var onEnterEdit: () -> Void = {}
        var onToggleTask: (_ line: Int, _ checked: Bool) -> Void = { _, _ in }
        var onOpenMarkdownLink: (_ url: URL) -> Void = { _ in }
        var onAnchorChange: (_ anchor: ViewportAnchor, _ isUserInitiated: Bool) -> Void = { _, _ in }
        var onFindShortcut: (_ action: FindCommand.Action) -> Void = { _ in }
        var onFindResult: (_ total: Int, _ index: Int) -> Void = { _, _ in }
        let localImageSchemeHandler = LocalImageSchemeHandler()
        var showsFrontMatter = true
        var lastFindQuery: String?
        var lastFocusToken: UUID?
        /// Token of the most recently consumed find-navigation command, so it runs
        /// exactly once even if `updateNSView` re-runs while the binding still holds
        /// the same command. See the consumption site for why clearing the binding
        /// inside `updateNSView` is not reliable.
        var lastFindNavigationToken: UUID?

        private(set) var isLoaded = false
        /// Monotonic per-load token appended to the request URL so consecutive
        /// loads of the same preview file are always real navigations.
        private var loadToken = 0

        func nextLoadToken() -> Int {
            loadToken += 1
            return loadToken
        }
        /// The mode-switch scroll target. Retained across an immediate apply so a
        /// reload that fires right after entering Side by Side (the preview view
        /// is rebuilt, resetting scroll to the top) re-applies it on `didFinish`
        /// instead of leaving the preview stuck at the top. Consumed by the
        /// post-load apply and cleared once the user scrolls.
        private var pendingScroll: ModeSwitchAnchor?
        private var pendingFindQuery: String?
        private var ignoreNextAnchorMessage = false

        /// Coalesces rapid live content swaps (one per keystroke) into a single
        /// JS push, keeping typing smooth. The latest body wins.
        private var pendingLiveBody: String?
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
        func applyLiveContent(_ bodyHTML: String, in webView: WKWebView) {
            let rewritten = LocalImageHTMLRewriter.rewrite(bodyHTML, baseURL: lastBaseURL)
            localImageSchemeHandler.setAllowedImages(rewritten.allowedImages)
            pendingLiveBody = rewritten.html
            liveUpdateGeneration += 1
            let generation = liveUpdateGeneration
            liveUpdateWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self, weak webView] in
                guard let self, let webView, let body = self.pendingLiveBody else { return }
                guard generation == self.liveUpdateGeneration else { return }
                self.pendingLiveBody = nil

                // An edit is in flight: keep the caret's rendered line in view
                // (only if it scrolled off-screen) rather than re-affirming the
                // preview's previous position. While the edit window is live this
                // is the SOLE authority on the preview's position — the capture +
                // `keepPinned` re-affirm below is skipped, so no stray swap in an
                // edit burst (e.g. a multi-key delete) can pin a drifted position,
                // and the editor is never driven.
                if let followLine = self.editFollowLine, Date() < self.editFollowDeadline {
                    let script = "window.__md2ApplyContent(\(Self.jsStringLiteral(body)));"
                        + "window.__md2FollowEditLine ? window.__md2FollowEditLine(\(followLine)) : null;"
                    webView.evaluateJavaScript(script) { [weak self, weak webView] _, _ in
                        guard let self, let webView else { return }
                        if let query = self.lastFindQuery, !query.isEmpty {
                            self.runFindWhenReady(query, in: webView)
                        }
                    }
                    return
                }
                self.editFollowLine = nil

                webView.evaluateJavaScript(
                    "window.__md2CaptureAnchor ? window.__md2CaptureAnchor() : null;"
                ) { [weak self, weak webView] result, _ in
                    guard let self, let webView, generation == self.liveUpdateGeneration else { return }
                    let anchor = (result as? [String: Any]).map(Self.viewportAnchor(fromMessage:))
                    let script = Self.liveContentScript(bodyHTML: body, anchor: anchor)
                    webView.evaluateJavaScript(script) { [weak self, weak webView] _, _ in
                        guard let self, let webView else { return }
                        if let query = self.lastFindQuery, !query.isEmpty {
                            self.runFindWhenReady(query, in: webView)
                        }
                    }
                }
            }
            liveUpdateWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.liveUpdateDebounce, execute: work)
        }

        private static func liveContentScript(bodyHTML: String, anchor: ViewportAnchor?) -> String {
            var script = "window.__md2ApplyContent(\(jsStringLiteral(bodyHTML)));"
            if let anchor {
                // `true` = silent: re-affirm the preview's own position as async
                // math/diagrams reflow, but do NOT report an anchor — an edit
                // must never drive the editor pane (it would jump to the bottom).
                script += "window.__md2ScrollToViewportAnchor(\(viewportAnchorJS(anchor)), true);"
            }
            return script
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
            isLoaded = false
        }

        /// A full reload caused by an edit can emit one load-position anchor
        /// before the user touches the preview. That report describes WebKit's
        /// reload settle, so it must not drive the editor pane.
        func suppressNextAnchorMessage() {
            ignoreNextAnchorMessage = true
        }

        /// Runs a preview search immediately when the page is ready, otherwise
        /// remembers the latest query and applies it after `didFinish`.
        func runFindWhenReady(_ query: String, in webView: WKWebView) {
            pendingFindQuery = query
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
            switch action {
            case .search:
                break
            case .next, .previous:
                let forward = action == .next
                webView.evaluateJavaScript("window.__md2FindNext(\(forward));") { [weak self] result, _ in
                    self?.reportFindResult(result)
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

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            switch message.name {
            case MarkdownPreviewView.enterEditMessageName:
                onEnterEdit()
            case MarkdownPreviewView.toggleTaskMessageName:
                guard let body = message.body as? [String: Any],
                      let line = (body["line"] as? NSNumber)?.intValue,
                      let checked = (body["checked"] as? NSNumber)?.boolValue else { return }
                onToggleTask(line, checked)
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
        /// load, reload-on-edit, and same-page fragment jumps — `about:`/
        /// `applewebdata:` for string-loaded untitled documents). Every other
        /// target is cancelled; a genuine link activation (including
        /// new-window requests, which carry no target frame) is handed off to
        /// the matching external handler, while a script- or meta-driven
        /// redirect is cancelled outright so a document can never auto-open
        /// anything.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            // Subframe navigations stay inside the page.
            if let targetFrame = navigationAction.targetFrame, !targetFrame.isMainFrame {
                decisionHandler(.allow)
                return
            }

            let route = PreviewLinkRouter.route(
                for: navigationAction.request.url,
                documentPageURL: previewFileURL
            )
            if route == .allowInPage {
                decisionHandler(.allow)
                return
            }

            if navigationAction.navigationType == .linkActivated || navigationAction.targetFrame == nil {
                dispatch(route)
            }
            decisionHandler(.cancel)
        }

        /// `target="_blank"`/`window.open` requests never create an in-app
        /// browsing context; a link-activated one routes exactly like a plain
        /// click on the same URL.
        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if navigationAction.navigationType == .linkActivated {
                dispatch(PreviewLinkRouter.route(
                    for: navigationAction.request.url,
                    documentPageURL: previewFileURL
                ))
            }
            return nil
        }

        private func dispatch(_ route: PreviewLinkRouter.Route) {
            switch route {
            case .allowInPage, .ignore:
                break
            case let .openExternal(url):
                NSWorkspace.shared.open(url)
            case let .openMarkdownDocument(url):
                // A dead target (file since removed) is ignored rather than
                // surfacing a failed open for a click the page offered.
                guard FileManager.default.fileExists(atPath: url.path) else { return }
                onOpenMarkdownLink(url)
            case let .openWithSystem(url):
                guard FileManager.default.fileExists(atPath: url.path) else { return }
                NSWorkspace.shared.open(url)
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
            isLoaded = true
            applyFrontMatterVisibility(in: webView)
            applyPendingScroll(in: webView, consume: true)
            applyPendingFind(in: webView)
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            // A new document started loading; hold scrolling until it finishes.
            isLoaded = false
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
            guard let query = pendingFindQuery else { return }
            pendingFindQuery = nil
            MarkdownPreviewView.evaluateFind(query, in: webView) { [weak self] result in
                self?.reportFindResult(result)
            }
        }

        deinit {
            if let previewFileURL {
                try? FileManager.default.removeItem(at: previewFileURL)
            }
        }
    }
}

private final class PreviewWebView: WKWebView {
    var onFindAction: ((FindCommand.Action) -> Void)?
    /// Esc handler; returns whether the key was consumed (find bar dismissed).
    var onEscape: (() -> Bool)?

    private static let escapeKeyCode: UInt16 = 53

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
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
