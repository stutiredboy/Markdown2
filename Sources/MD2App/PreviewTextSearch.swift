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
        var findMarks = [];
        var findGroups = [];
        var findCurrent = -1;
        var findSnapshot = null;
        window.__md2FindActive = false;
        (function () {
            var style = document.createElement('style');
            style.textContent = 'mark.md2-find{background:#ffe066;color:inherit;border-radius:2px;}mark.md2-find-current{background:#ff9f1c;}';
            document.head.appendChild(style);
        })();
        function clearFind() {
            for (var m of findMarks) {
                var parent = m.parentNode;
                if (!parent) continue;
                parent.replaceChild(document.createTextNode(m.textContent), m);
                parent.normalize();
            }
            findMarks = []; findGroups = []; findCurrent = -1; findSnapshot = null;
        }
        window.__md2FindClear = clearFind;
        function setCurrent(index) {
            if (!findGroups.length) return { total: 0, index: 0 };
            if (findCurrent >= 0 && findCurrent < findGroups.length)
                findGroups[findCurrent].forEach(m => m.classList.remove('md2-find-current'));
            findCurrent = ((index % findGroups.length) + findGroups.length) % findGroups.length;
            var group = findGroups[findCurrent];
            group.forEach(m => m.classList.add('md2-find-current'));
            window.__md2FindActive = true;
            group[0].scrollIntoView({ block: 'center', inline: 'nearest' });
            clearTimeout(window.__md2FindTimer);
            window.__md2FindTimer = setTimeout(() => { window.__md2FindActive = false; }, 400);
            return { total: findGroups.length, index: findCurrent + 1 };
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
        window.__md2Find = function (query, payload) {
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
                var fragments = [], from = 0;
                for (var i = rangeCursor; i < ranges.length && ranges[i][0] < nodeEnd; i++) {
                    var start = Math.max(0, ranges[i][0] - record.start);
                    var end = Math.min(record.text.length, ranges[i][0] + ranges[i][1] - record.start);
                    if (end <= start) continue;
                    if (start > from) fragments.push(document.createTextNode(record.text.slice(from, start)));
                    var mark = document.createElement('mark'); mark.className = 'md2-find';
                    mark.textContent = record.text.slice(start, end);
                    fragments.push(mark); findMarks.push(mark); groupMap[i].push(mark); from = end;
                }
                if (!fragments.length) continue;
                if (from < record.text.length) fragments.push(document.createTextNode(record.text.slice(from)));
                var fragment = document.createDocumentFragment(); fragments.forEach(n => fragment.appendChild(n));
                record.node.parentNode.replaceChild(fragment, record.node);
            }
            findGroups = groupMap.filter(g => g.length);
            findSnapshot = null;
            return findGroups.length ? setCurrent(0) : { total: 0, index: 0 };
        };
        window.__md2FindNext = function (forward) {
            return setCurrent(findCurrent + (forward ? 1 : -1));
        };
        """#
}
