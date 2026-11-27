import Foundation

/// Table column resizing belongs to the interactive preview's isolated world.
enum PreviewTableResize {
    static let messageName = "tableColumnWidths"
    static let minWidth = 40
    static let maxWidth = 2000
    static let maxColumns = 64
    static let maxKeyLength = 2048
    static let maxEntries = 256

    struct Update: Equatable {
        let key: String
        /// nil restores the table's automatic layout.
        let widths: [Int]?
    }

    static func parse(_ body: Any) -> Update? {
        guard let dict = body as? [String: Any],
              let key = dict["key"] as? String,
              !key.isEmpty, key.utf16.count <= maxKeyLength else { return nil }
        if dict["widths"] == nil || dict["widths"] is NSNull {
            return Update(key: key, widths: nil)
        }
        guard let raw = dict["widths"] as? [NSNumber],
              (1...maxColumns).contains(raw.count) else { return nil }
        var widths: [Int] = []
        for number in raw {
            let value = number.doubleValue
            guard value.isFinite, value == value.rounded(),
                  value >= Double(minWidth), value <= Double(maxWidth) else { return nil }
            widths.append(Int(value))
        }
        return Update(key: key, widths: widths)
    }

    static let script = #"""
    (function () {
        'use strict';
        var main = document.querySelector('main');
        if (!main || window.__md2SetTableColumnWidths) { return; }

        var MIN = \#(minWidth), MAX = \#(maxWidth), MAX_COLUMNS = \#(maxColumns), EDGE = 5;
        var RESIZED = 'md2-col-resized', HOT = 'md2-col-resize-hot';
        var HOVERING = 'md2-col-resize-hovering', DRAGGING = 'md2-col-resizing';
        var root = document.documentElement;
        var widthsByKey = new Map();
        var appliedWidths = new WeakMap();
        var hot = null, drag = null, consumeClick = false, completedDrag = false;

        var style = document.createElement('style');
        // The outer table remains the scroller. The two fixed-layout groups use
        // the same explicit width so WebKit lines up their independent columns.
        style.textContent =
            'table.' + RESIZED + '>thead,table.' + RESIZED + '>tbody{display:table;table-layout:fixed;border-collapse:collapse;}' +
            'table.' + RESIZED + '>tbody>tr:first-child>:is(th,td){border-top:0;}' +
            'table.' + RESIZED + '>:is(thead,tbody)>tr>:is(th,td){box-sizing:border-box;overflow:hidden;overflow-wrap:anywhere;}' +
            // A native caption sits below the anonymous table box. When the
            // groups have their own table boxes, order it below them in the
            // outer scroller while leaving the document order untouched.
            'table.' + RESIZED + ':has(>caption.tbl-caption){display:flex;flex-direction:column;align-items:flex-start;}' +
            'table.' + RESIZED + '>caption.tbl-caption{display:block;order:1;box-sizing:border-box;overflow-wrap:anywhere;}' +
            'th.' + HOT + '{cursor:col-resize;box-shadow:inset -2px 0 0 var(--accent);}' +
            'html.' + HOVERING + ',html.' + HOVERING + ' *,html.' + DRAGGING + ',html.' + DRAGGING + ' *{cursor:col-resize!important;}' +
            'html.' + DRAGGING + ',html.' + DRAGGING + ' *{-webkit-user-select:none!important;user-select:none!important;}';
        document.head.appendChild(style);

        function clamp(width) {
            return Math.min(MAX, Math.max(MIN, Math.round(width)));
        }

        function eligibleHeader(table) {
            if (!table || !main.contains(table)) { return null; }
            var heads = 0;
            for (var child of table.children) {
                if (child.tagName === 'THEAD') { heads++; }
                else if (child.tagName !== 'CAPTION' && child.tagName !== 'TBODY') { return null; }
            }
            if (heads !== 1 || table.tHead.rows.length !== 1 || table.tBodies.length > 1) { return null; }
            var cells = Array.from(table.tHead.rows[0].cells);
            if (!cells.length || cells.length > MAX_COLUMNS ||
                cells.some(function (cell) { return cell.tagName !== 'TH'; }) ||
                table.querySelector('[colspan],[rowspan]')) { return null; }
            var body = table.tBodies[0];
            if (body && body.rows.length) {
                if (body.rows[0].cells.length !== cells.length) { return null; }
                for (var row of body.rows) {
                    if (row.cells.length > cells.length) { return null; }
                }
            }
            return cells;
        }

        function groups(table) {
            return [table.tHead, table.tBodies[0]].filter(Boolean);
        }

        function bottomCaption(table) {
            var caption = table.caption;
            return caption && caption.classList.contains('tbl-caption') ? caption : null;
        }

        // Count equal headers in document order. Read each signature once per
        // pass, including when several resized tables are restored together.
        function visitTables(visit) {
            var seen = new Map();
            for (var table of main.querySelectorAll('table')) {
                var cells = eligibleHeader(table);
                var key = null;
                if (cells) {
                    var signature = cells.map(function (cell) { return cell.textContent.trim(); }).join('\u001f').slice(0, 1500);
                    var prefix = cells.length + '|' + signature;
                    var ordinal = seen.get(prefix) || 0;
                    seen.set(prefix, ordinal + 1);
                    key = cells.length + '|' + ordinal + '|' + signature;
                }
                if (visit(table, key)) { return; }
            }
        }

        function keyOf(table) {
            var key = null;
            visitTables(function (candidate, candidateKey) {
                if (candidate !== table) { return false; }
                key = candidateKey;
                return true;
            });
            return key;
        }

        function applyWidths(table, widths) {
            var previous = appliedWidths.get(table);
            if (previous === widths) { return; }
            var columns = [];
            for (var i = 0; i < widths.length; i++) {
                if (!previous || previous[i] !== widths[i]) { columns.push(i); }
            }
            if (columns.length) {
                table.classList.add(RESIZED);
                var total = widths.reduce(function (sum, width) { return sum + width; }, 0) + 'px';
                var caption = bottomCaption(table);
                if (caption) { caption.style.width = total; }
                for (var group of groups(table)) {
                    group.style.width = total;
                    for (var row of group.rows) {
                        for (var column of columns) {
                            var cell = row.cells[column];
                            if (cell) { cell.style.width = widths[column] + 'px'; }
                        }
                    }
                }
            }
            appliedWidths.set(table, widths);
        }

        function dropWidth(element) {
            element.style.removeProperty('width');
            if (!element.getAttribute('style')) { element.removeAttribute('style'); }
        }

        function removeClass(element, name) {
            element.classList.remove(name);
            if (!element.classList.length) { element.removeAttribute('class'); }
        }

        function clearWidths(table) {
            if (!appliedWidths.delete(table)) { return; }
            removeClass(table, RESIZED);
            var caption = bottomCaption(table);
            if (caption) { dropWidth(caption); }
            for (var group of groups(table)) {
                dropWidth(group);
                for (var row of group.rows) {
                    for (var cell of row.cells) { dropWidth(cell); }
                }
            }
        }

        function restoreAll() {
            if (hot && !hot.th.isConnected) { setHot(null); }
            if (drag && !drag.table.isConnected) { finish(false); }
            if (!widthsByKey.size) { return; }
            visitTables(function (table, key) {
                if (drag && drag.table === table) { return; }
                var widths = key && widthsByKey.get(key);
                if (widths) { applyWidths(table, widths); }
                else { clearWidths(table); }
            });
        }

        function post(key, widths) {
            window.webkit.messageHandlers['\#(messageName)'].postMessage({ key: key, widths: widths });
        }

        function headerAt(target) {
            var th = target && target.closest ? target.closest('th') : null;
            return th && th.parentElement.parentElement.tagName === 'THEAD' ? th : null;
        }

        function hitTest(event) {
            if (!main.contains(event.target)) { return null; }
            var x = event.clientX, y = event.clientY;
            // Just to the right of the last cell the pointer can be over the
            // table's empty block area, or over main's padding.
            var th = headerAt(event.target) || headerAt(document.elementFromPoint(x - EDGE - 1, y));
            if (!th) { return null; }
            var rect = th.getBoundingClientRect();
            var edge = Math.abs(rect.right - x) <= EDGE ? th : th.previousElementSibling;
            if (!edge) { return null; }
            var right = edge === th ? rect.right : edge.getBoundingClientRect().right;
            if (Math.abs(right - x) > EDGE || y < rect.top || y > rect.bottom) { return null; }
            var table = th.closest('table');
            var tableRect = table.getBoundingClientRect();
            var clipLeft = tableRect.left + table.clientLeft;
            if (right <= clipLeft || right > clipLeft + table.clientWidth + 1) { return null; }
            var cells = eligibleHeader(table);
            return cells ? { table: table, column: cells.indexOf(edge), th: edge, cells: cells } : null;
        }

        function setHot(next) {
            if (hot?.th === next?.th) { return; }
            if (hot) { removeClass(hot.th, HOT); }
            if (next) { next.th.classList.add(HOT); }
            root.classList.toggle(HOVERING, !!next);
            hot = next;
        }

        function changeWidth(current, x) {
            var dx = x - current.startX;
            if (!current.widths && Math.abs(dx) < 2) { return; }
            var widths = current.startWidths.slice();
            widths[current.column] = clamp(widths[current.column] + dx);
            current.widths = widths;
        }

        function finish(commit) {
            var current = drag;
            drag = null;
            removeClass(root, DRAGGING);
            if (current.frame) { cancelAnimationFrame(current.frame); }
            if (!current.widths) { return; }
            completedDrag = true;
            if (!current.table.isConnected) { return; }
            if (!commit) {
                if (current.previous) { applyWidths(current.table, current.previous); }
                else { clearWidths(current.table); }
                return;
            }
            applyWidths(current.table, current.widths);
            widthsByKey.set(current.key, current.widths);
            post(current.key, current.widths);
        }

        window.addEventListener('mousedown', function (event) {
            if (!event.isTrusted || event.button !== 0) { return; }
            if (drag) { finish(false); }
            consumeClick = false;
            completedDrag = false;
            if (event.ctrlKey) { return; } // Preserve the macOS context click.
            var hit = hitTest(event);
            if (!hit) { return; }
            event.preventDefault();
            event.stopPropagation();
            consumeClick = true;
            if (event.metaKey || event.altKey || event.shiftKey) { return; }
            var key = keyOf(hit.table);
            if (!key) { return; }
            var previous = appliedWidths.get(hit.table);
            var start = previous || hit.cells.map(function (cell) { return clamp(cell.getBoundingClientRect().width); });
            drag = {
                table: hit.table, key: key, column: hit.column, startX: event.clientX,
                previous: previous, startWidths: start, widths: null, frame: 0
            };
            setHot(hit);
            root.classList.add(DRAGGING);
        }, true);

        window.addEventListener('mousemove', function (event) {
            if (!event.isTrusted) { return; }
            if (!drag) { setHot(hitTest(event)); return; }
            event.preventDefault();
            if (!drag.table.isConnected) { finish(false); return; }
            changeWidth(drag, event.clientX);
            if (drag.widths && !drag.frame) {
                var current = drag;
                current.frame = requestAnimationFrame(function () {
                    current.frame = 0;
                    if (drag === current) { applyWidths(current.table, current.widths); }
                });
            }
        }, true);

        window.addEventListener('mouseout', function (event) {
            if (!drag && !event.relatedTarget) { setHot(null); }
        }, true);

        window.addEventListener('mouseup', function (event) {
            if (!drag || !event.isTrusted || event.button !== 0) { return; }
            event.preventDefault();
            event.stopPropagation();
            changeWidth(drag, event.clientX);
            finish(true);
            setHot(hitTest(event));
        }, true);

        // Window capture precedes the document-level link and source bridges.
        window.addEventListener('click', function (event) {
            if (!event.isTrusted || event.detail === 0 || (!consumeClick && !hitTest(event))) { return; }
            consumeClick = false;
            event.preventDefault();
            event.stopPropagation();
        }, true);

        window.addEventListener('dblclick', function (event) {
            if (!event.isTrusted || event.button !== 0 || event.ctrlKey) { return; }
            var hit = hitTest(event);
            if (!hit) { return; }
            event.preventDefault();
            event.stopPropagation();
            if (completedDrag || !appliedWidths.has(hit.table)) { return; }
            var key = keyOf(hit.table);
            if (!key) { return; }
            clearWidths(hit.table);
            widthsByKey.delete(key);
            post(key, null);
            setHot(hitTest(event));
        }, true);

        window.addEventListener('keydown', function (event) {
            if (drag && event.isTrusted && event.key === 'Escape') {
                event.preventDefault();
                event.stopPropagation();
                finish(false);
                setHot(null);
            }
        }, true);
        window.addEventListener('blur', function () {
            if (drag) { finish(false); }
            setHot(null);
        });

        window.__md2SetTableColumnWidths = function (entries) {
            // Only a new navigation receives a native snapshot. Mutations in
            // the current page use the map managed by its own input handlers.
            widthsByKey = new Map(Object.entries(entries));
            restoreAll();
        };

        // Live updates replace their top-level block. Watching only main's
        // children also avoids line-number overlay and inline engine changes.
        new MutationObserver(restoreAll).observe(main, { childList: true });
        if (window.__md2TableColumnWidthsConfig) {
            window.__md2SetTableColumnWidths(window.__md2TableColumnWidthsConfig);
        }
    })();
    """#
}

/// Wider columns survive preview reloads only for the lifetime of a document.
@MainActor
final class PreviewTableColumnWidths {
    private(set) var entries: [String: [Int]] = [:]

    func apply(_ update: PreviewTableResize.Update) {
        if let widths = update.widths {
            guard entries[update.key] != nil || entries.count < PreviewTableResize.maxEntries else { return }
            entries[update.key] = widths
        } else {
            entries.removeValue(forKey: update.key)
        }
    }

    func removeAll() { entries.removeAll() }

    func javaScriptLiteral() -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: entries, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
