import Foundation
import MD2Core

/// Bounded bridge payload. Matching itself is shared with the source editor.
enum PreviewTextSearch {
    static let maximumUTF16 = 2_000_000
    static let maximumNodes = 20_000
    static let maximumMatches = 20_000

    static func ranges(query: String, text: String, options: TextSearch.Options) -> [[Int]]? {
        guard text.utf16.count <= maximumUTF16 else { return nil }
        let matches = TextSearch.matches(of: query, in: text, options: options, maximumMatches: maximumMatches + 1)
        guard matches.count <= maximumMatches else { return nil }
        return matches.map { [$0.location, $0.length] }
    }

    static let script = #"""
        var findGroups = [];
        var findCurrent = -1;
        var findSnapshot = null;
        var findOutline, outlineFrame, outlineResize, outlineChanges;
        window.__md2FindActive = false;
        (function () {
            var style = document.createElement('style');
            style.textContent = `
                ::highlight(md2-find) {
                    color: light-dark(#342700, #fff5cf);
                    background-color: light-dark(#ffe066, #655117);
                }
                ::highlight(md2-find-current) {
                    color: #241800;
                    background-color: light-dark(#ffac42, #ffbd5c);
                }
                .md2-find-outline {
                    position: fixed; inset: 0; overflow: hidden; pointer-events: none;
                    contain: strict; user-select: none; z-index: 1;
                }
                .md2-find-outline > i {
                    position: absolute; outline: 2px solid light-dark(#854300, #fff5cf);
                    outline-offset: -2px; border-radius: 2px;
                }
            `;
            document.head.appendChild(style);
        })();
        function viewportBox() {
            return {left: 0, top: 0, right: document.documentElement.clientWidth,
                    bottom: document.documentElement.clientHeight};
        }
        // Use the scrollport, excluding its border and any classic scrollbars.
        function scrollport(element) {
            var box = element.getBoundingClientRect();
            var left = box.left + element.clientLeft, top = box.top + element.clientTop;
            return {left, top, right: left + element.clientWidth, bottom: top + element.clientHeight};
        }
        function clipForFind(element, cache) {
            if (!element || element === document.body) return viewportBox();
            if (cache.has(element)) return cache.get(element);
            var clip = clipForFind(element.parentElement, cache);
            var style = getComputedStyle(element);
            if (style.overflowX !== 'visible' || style.overflowY !== 'visible') {
                var box = scrollport(element);
                clip = {...clip};
                if (style.overflowX !== 'visible') {
                    clip.left = Math.max(clip.left, box.left);
                    clip.right = Math.min(clip.right, box.right);
                }
                if (style.overflowY !== 'visible') {
                    clip.top = Math.max(clip.top, box.top);
                    clip.bottom = Math.min(clip.bottom, box.bottom);
                }
            }
            cache.set(element, clip);
            return clip;
        }
        // A query can span many thousands of inline nodes. Cull contiguous
        // batches in WebKit before asking for the individual line rectangles.
        function* visibleFindRanges(group) {
            var chunkSize = 128, view = viewportBox();
            if (group.length <= chunkSize) { yield* group; return; }
            var span = document.createRange();
            for (var first = 0; first < group.length; first += chunkSize) {
                var last = Math.min(group.length, first + chunkSize) - 1;
                span.setStart(group[first].startContainer, group[first].startOffset);
                span.setEnd(group[last].endContainer, group[last].endOffset);
                var rect = span.getBoundingClientRect();
                if (rect.right <= 0 || rect.bottom <= 0 || rect.left >= view.right || rect.top >= view.bottom) continue;
                for (var i = first; i <= last; i++) yield group[i];
            }
        }
        function updateFindOutline() {
            outlineFrame = 0;
            if (!findOutline) return;
            var fragment = document.createDocumentFragment(), clips = new Map();
            // Only the current match owns outline boxes. Bound their count even
            // when a single long query matches thousands of inline fragments.
            for (var range of visibleFindRanges(findGroups[findCurrent])) {
                var clip = clipForFind(range.startContainer.parentElement, clips);
                for (var box of range.getClientRects()) {
                    if (box.width <= 0 || box.height <= 0 || box.right <= clip.left || box.left >= clip.right ||
                        box.bottom <= clip.top || box.top >= clip.bottom) continue;
                    var x = Math.max(clip.left, box.left - 2), y = Math.max(clip.top, box.top - 2);
                    var w = Math.min(clip.right, box.right + 2) - x, h = Math.min(clip.bottom, box.bottom + 2) - y;
                    var border = document.createElement('i');
                    border.style.cssText = `left:${x}px; top:${y}px; width:${w}px; height:${h}px`;
                    fragment.appendChild(border);
                    if (fragment.childElementCount === 256) break;
                }
                if (fragment.childElementCount === 256) break;
            }
            findOutline.replaceChildren(fragment);
        }
        function scheduleFindOutline() {
            if (findOutline && !outlineFrame) outlineFrame = requestAnimationFrame(updateFindOutline);
        }
        window.addEventListener('scroll', scheduleFindOutline, {capture: true, passive: true});
        window.addEventListener('resize', scheduleFindOutline);
        document.addEventListener('load', scheduleFindOutline, true);
        document.fonts.addEventListener('loadingdone', scheduleFindOutline);
        function showFindOutline() {
            if (!findOutline) {
                findOutline = document.createElement('div');
                findOutline.className = 'md2-find-outline';
                findOutline.setAttribute('aria-hidden', 'true');
                document.body.appendChild(findOutline);
                var main = document.querySelector('main');
                if (main) {
                    outlineResize = new ResizeObserver(scheduleFindOutline);
                    outlineResize.observe(main);
                    outlineChanges = new MutationObserver(scheduleFindOutline);
                    outlineChanges.observe(main, {subtree: true, childList: true, attributes: true, characterData: true});
                }
            }
            if (outlineFrame) cancelAnimationFrame(outlineFrame);
            updateFindOutline();
        }
        function clearFind() {
            CSS.highlights.delete('md2-find-current');
            CSS.highlights.delete('md2-find');
            if (outlineFrame) cancelAnimationFrame(outlineFrame);
            outlineFrame = 0;
            if (outlineResize) outlineResize.disconnect();
            if (outlineChanges) outlineChanges.disconnect();
            if (findOutline) findOutline.remove();
            outlineResize = outlineChanges = findOutline = null;
            findGroups = []; findCurrent = -1; findSnapshot = null;
        }
        window.__md2FindClear = clearFind;
        function horizontalReveal(rect, box, rtl) {
            if (rect.right - rect.left > box.right - box.left)
                return rtl ? rect.right - box.right : rect.left - box.left;
            if (rect.left < box.left) return rect.left - box.left;
            if (rect.right > box.right) return rect.right - box.right;
            return 0;
        }
        function firstFindLine(group, container) {
            var line = null;
            for (var range of group) {
                if (!container.contains(range.startContainer)) break;
                for (var r of range.getClientRects()) {
                    if (!r.width || !r.height) continue;
                    if (!line) line = {left: r.left, right: r.right, top: r.top, bottom: r.bottom};
                    else {
                        if (r.top >= line.bottom || r.bottom <= line.top) return line;
                        line.left = Math.min(line.left, r.left);
                        line.right = Math.max(line.right, r.right);
                    }
                }
            }
            return line;
        }
        function revealFindRange(group) {
            // Range has no scrollIntoView. Reveal the whole first visual line,
            // including adjacent inline runs, moving nested scrollports first.
            var start = group[0].startContainer.parentElement;
            if (!start) return;
            var rtl = getComputedStyle(start).direction === 'rtl';
            for (var el = start; el && el !== document.body; el = el.parentElement) {
                var style = getComputedStyle(el);
                var scrollX = /^(auto|scroll|hidden)$/.test(style.overflowX) && el.scrollWidth > el.clientWidth;
                var scrollY = /^(auto|scroll|hidden)$/.test(style.overflowY) && el.scrollHeight > el.clientHeight;
                if (!scrollX && !scrollY) continue;
                var rect = firstFindLine(group, el), box = scrollport(el);
                if (!rect) continue;
                el.scrollBy(scrollX ? horizontalReveal(rect, box, rtl) : 0,
                            scrollY ? (rect.top + rect.bottom - box.top - box.bottom) / 2 : 0);
            }
            var rect = firstFindLine(group, document.body), box = viewportBox();
            if (rect) window.scrollBy(horizontalReveal(rect, box, rtl), (rect.top + rect.bottom - box.bottom) / 2);
        }
        function setCurrent(index, reveal) {
            if (!findGroups.length) return { total: 0, index: 0 };
            findCurrent = ((index % findGroups.length) + findGroups.length) % findGroups.length;
            var group = findGroups[findCurrent];
            var highlight = makeFindHighlight(group);
            highlight.priority = 1;
            CSS.highlights.delete('md2-find-current');
            CSS.highlights.set('md2-find-current', highlight);
            if (reveal !== false) {
                window.__md2FindActive = true;
                revealFindRange(group);
                clearTimeout(window.__md2FindTimer);
                window.__md2FindTimer = setTimeout(() => { window.__md2FindActive = false; }, 400);
            }
            showFindOutline();
            return { total: findGroups.length, index: findCurrent + 1 };
        }
        function makeFindHighlight(ranges) {
            // WebKit scans existing ranges on each add(). Its bulk constructor
            // is linear. Respect the JS engine's argument limit if a bounded
            // snapshot has more fragments than this WebKit build accepts.
            try { return Reflect.construct(Highlight, ranges); }
            catch (error) {
                if (!(error instanceof RangeError)) throw error;
                var highlight = new Highlight();
                for (var range of ranges) highlight.add(range);
                return highlight;
            }
        }
        // Join inline nodes, with explicit block separators. No source mapping
        // is inferred. Node identity/content checks reject intervening DOM edits.
        window.__md2FindSnapshot = function () {
            clearFind();
            var root = document.querySelector('main') || document.body;
            var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT | NodeFilter.SHOW_ELEMENT, {
                acceptNode: function (node) {
                    // Formatting elements do not separate words, but a visible
                    // BR contributes a real newline in rendered text.
                    var isBreak = node.nodeType === Node.ELEMENT_NODE && node.tagName === 'BR';
                    if (node.nodeType === Node.ELEMENT_NODE && !isBreak) return NodeFilter.FILTER_SKIP;
                    var p = isBreak ? node : node.parentElement;
                    if (!p || (!isBreak && !node.nodeValue) || p.closest('script,style,mark,[aria-hidden="true"],.md2-line-gutter'))
                        return NodeFilter.FILTER_REJECT;
                    if (!p.getClientRects().length || getComputedStyle(p).visibility === 'hidden') return NodeFilter.FILTER_REJECT;
                    return NodeFilter.FILTER_ACCEPT;
                }
            });
            var records = [], breaks = [], text = '', lastBlock = null, acceptedNodes = 0, node;
            while ((node = walker.nextNode())) {
                var isBreak = node.nodeType === Node.ELEMENT_NODE;
                var value = isBreak ? '\n' : node.nodeValue;
                var block = node.parentElement.closest('p,div,li,pre,h1,h2,h3,h4,h5,h6,td,th,blockquote,section,main');
                if (acceptedNodes && block !== lastBlock) text += '\n';
                if (acceptedNodes >= 20000 || text.length + value.length > 2000000) {
                    return { unavailable: true };
                }
                if (isBreak) breaks.push(node);
                else records.push({ node: node, start: text.length, text: value });
                acceptedNodes++;
                text += value; lastBlock = block;
            }
            var id = String(Date.now()) + '-' + String(Math.random());
            findSnapshot = { id: id, records: records, breaks: breaks };
            return { id: id, text: text };
        };
        window.__md2Find = function (query, payload, reveal) {
            // The native path always supplies core-computed ranges. Keep the
            // original direct page API useful for diagnostics and CSP probes.
            if (!payload) {
                var snapshot = window.__md2FindSnapshot();
                if (snapshot.unavailable) return { total: 0, index: 0, unavailable: true };
                var lower = snapshot.text.toLowerCase(), needle = (query || '').toLowerCase(), ranges = [], at = 0;
                if (needle) while ((at = lower.indexOf(needle, at)) >= 0) {
                    ranges.push([at, needle.length]); at += needle.length;
                    if (ranges.length > 20000) return { total: 0, index: 0, unavailable: true };
                }
                payload = { id: snapshot.id, ranges: ranges };
            }
            if (!findSnapshot || payload.id !== findSnapshot.id) return { stale: true };
            var records = findSnapshot.records;
            if (records.some(r => !r.node.isConnected || r.node.nodeValue !== r.text) ||
                findSnapshot.breaks.some(node => !node.isConnected)) {
                clearFind(); return { stale: true };
            }
            if (payload.unavailable) { clearFind(); return { total: 0, index: 0, unavailable: true }; }
            var ranges = payload.ranges, groupMap = ranges.map(() => []), rangeCursor = 0;
            for (var record of records) {
                var nodeEnd = record.start + record.text.length;
                while (rangeCursor < ranges.length && ranges[rangeCursor][0] + ranges[rangeCursor][1] <= record.start) rangeCursor++;
                for (var i = rangeCursor; i < ranges.length && ranges[i][0] < nodeEnd; i++) {
                    var start = Math.max(0, ranges[i][0] - record.start);
                    var end = Math.min(record.text.length, ranges[i][0] + ranges[i][1] - record.start);
                    if (end <= start) continue;
                    var range = document.createRange();
                    range.setStart(record.node, start);
                    range.setEnd(record.node, end);
                    groupMap[i].push(range);
                }
            }
            findGroups = groupMap.filter(g => g.length);
            if (findGroups.length) CSS.highlights.set('md2-find', makeFindHighlight(findGroups.flat()));
            findSnapshot = null;
            return findGroups.length ? setCurrent(0, reveal) : { total: 0, index: 0 };
        };
        window.__md2FindNext = function (forward) {
            return setCurrent(findCurrent + (forward ? 1 : -1));
        };
        """#
}
