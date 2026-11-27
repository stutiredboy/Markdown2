import AppKit

/// Tracks visible rendered content across a split preview edit or a new engine page.
enum PreviewHeldReference {
    static let reloadMessageName = "heldReferenceReload"

    @MainActor static let script = #"""
    // Source line numbers change on insertion. A container top also cannot
    // describe a reader's place inside a large, newly rebuilt table or list.
    // The WebKit bridge carries only a fixed-size content fingerprint, even
    // for a long header or a data URL. Stream all UTF-16 units through two
    // independent 32-bit hashes. A separator outside the UTF-16 range keeps
    // adjacent cells distinct (["a", "bc"] versus ["ab", "c"]).
    function heldKey(node, sampleTableBody = false) {
        var first = 2166136261, second = 5381, length = 0;
        function unit(value) {
            first = Math.imul(first ^ value, 16777619);
            second = (Math.imul(second, 33) + value) | 0;
            length++;
        }
        function write(text) {
            for (var i = 0; i < text.length; i++) { unit(text.charCodeAt(i)); }
        }
        function field(text) { write(text); unit(65536); }
        function ownText(element) {
            // Never flatten a nested table/list to label an ancestor. Text
            // nodes are streamed rather than allocating the entire subtree.
            var walker = document.createTreeWalker(element, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, {
                acceptNode(child) {
                    if (child.nodeType === Node.TEXT_NODE) { return NodeFilter.FILTER_ACCEPT; }
                    return child.matches('ul,ol,table') ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_SKIP;
                }
            });
            var text;
            while ((text = walker.nextNode())) { write(text.data); }
            unit(65536);
        }
        function cells(row) {
            field(String(row.cells.length));
            for (var cell of row.cells) { ownText(cell); }
        }
        field(node.tagName);
        if (node.tagName === 'IMG') {
            // The same local file has the same opaque src across engine pages.
            field(node.getAttribute('src') || '');
        } else if (node.tagName === 'TABLE') {
            field(node.id);
            if (node.caption) { ownText(node.caption); }
            if (sampleTableBody) {
                // Corroborate the visible rows without scanning the entire table.
                var firstBody = node.tHead?.rows.length || 0, lastBody = node.rows.length - 1;
                if (firstBody <= lastBody) { cells(node.rows[firstBody]); }
                if (firstBody < lastBody) { cells(node.rows[lastBody]); }
            } else if (node.tHead) { for (var row of node.tHead.rows) { cells(row); } }
        } else if (node.tagName === 'OL' || node.tagName === 'UL') { field(node.id); }
        else if (node.tagName === 'TR') { cells(node); }
        else { ownText(node); }
        return length + ':' + (first >>> 0) + ':' + (second >>> 0);
    }

    // A row/item matches within its own container. A table's source span
    // and visible rows can identify it after an in-place header edit. Its
    // header or caption also helps identify it after a move or insertion.
    function visibleReferences() {
        var main = document.querySelector('main'), blocks = [];
        if (!main) { return blocks; }
        var retained = currentPinnedReference();
        var locations = new Map();
        function location(node) {
            if (!locations.has(node.tagName)) {
                var indices = new Map();
                Array.from(main.getElementsByTagName(node.tagName)).forEach((item, i) => indices.set(item, i));
                locations.set(node.tagName, indices);
            }
            return locations.get(node.tagName).get(node);
        }
        function remember(node, top, index, group) {
            blocks.push({node: node, top: top, index: index, tag: node.tagName, group: group});
        }
        function visit(node, rect, index, group) {
            if (rect.height <= 0 || rect.bottom <= 0 || rect.top >= window.innerHeight) { return; }
            if (node.matches('table,ul,ol')) {
                var items = node.tagName === 'TABLE' ? node.rows : node.children;
                var scope = {tag: node.tagName, key: heldKey(node), index: location(node), count: items.length};
                // Rows and immediate list items are in vertical layout order.
                // Measure the visible run, including nested lists, without
                // walking thousands of rows before and after the viewport.
                var lo = 0, hi = items.length;
                while (lo < hi) {
                    var mid = Math.floor((lo + hi) / 2);
                    if (items[mid].getBoundingClientRect().bottom <= 0) { lo = mid + 1; } else { hi = mid; }
                }
                for (var i = lo; i < items.length; i++) {
                    var childRect = items[i].getBoundingClientRect();
                    if (childRect.top >= window.innerHeight) { break; }
                    visit(items[i], childRect, i, scope);
                }
            } else if (node.tagName !== 'IMG') {
                for (var child of node.children) {
                    if (child.matches('img,table,ol,ul') || child.querySelector('img,table,ol,ul')) {
                        visit(child, child.getBoundingClientRect(), 0, null);
                    }
                }
            }
            if (node.tagName === 'IMG') { remember(node, rect.top, location(node), null); }
            else if (group && node.matches('tr,li')) { remember(node, rect.top, index, group); }
        }
        for (var i = 0; i < main.children.length; i++) {
            var node = main.children[i];
            if (isGutterLayer(node)) { continue; }
            var rect = node.getBoundingClientRect();
            if (rect.height <= 0 || rect.bottom <= 0) { continue; }
            if (rect.top >= window.innerHeight) { break; }
            visit(node, rect, i, null);
            remember(node, rect.top, i, null);
        }
        // WebKit may round each scroll by a fraction of a CSS pixel. Keep
        // aiming at the original top while the same reading reference survives.
        // The other visible blocks keep freshly measured positions for fallback.
        if (retained) {
            var index = blocks.findIndex(block => block.node === retained.node);
            if (index >= 0) {
                var block = blocks.splice(index, 1)[0];
                block.top = retained.top;
                blocks.unshift(block);
            }
        }
        return blocks;
    }

    function resolveHeldReference(blocks) {
        if (blocks[0]?.node?.isConnected) { return blocks[0]; }
        var main = document.querySelector('main'), collections = new Map(), indices = new Map();
        var wanted = new Set(), keys = new Map();
        function keyOf(node) {
            if (!keys.has(node)) { keys.set(node, heldKey(node)); }
            return keys.get(node);
        }
        for (var ref of blocks) {
            if (ref.node?.isConnected) { continue; }
            if (ref.node && !ref.group && ref.tag !== 'IMG') { continue; }
            if (ref.node) { ref.key = keyOf(ref.node); }
            wanted.add(ref.key);
            if (ref.group) { wanted.add(ref.group.key); }
        }
        function collection(tag) {
            if (!collections.has(tag)) { collections.set(tag, main.getElementsByTagName(tag)); }
            return collections.get(tag);
        }

        // Try the old ordinal and, for rows/items, the shift implied by the
        // change in length. An insertion above or below can resolve immediately.
        // Otherwise index the collection once, retaining only keys we need.
        function matching(nodes, ref, accept, shiftedIndex, neighbors) {
            function matches(i) {
                var node = nodes[i];
                return node && node.tagName === ref.tag && keyOf(node) === ref.key;
            }
            // Compare the other visible rows/items at their original offsets.
            // Repeated labels alone cannot tell whether an insertion was
            // above the viewport or below it.
            function support(i) {
                var score = 0;
                for (var peer of neighbors || []) {
                    var node = nodes[i + peer.index - ref.index];
                    if (node && keyOf(node) === peer.key) { score++; }
                }
                return score;
            }
            var preferred = [ref.index];
            if (shiftedIndex !== undefined && shiftedIndex !== ref.index) { preferred.push(shiftedIndex); }
            var best = null, bestScore = -1, bestDistance = Infinity;
            function consider(i) {
                var score = support(i), distance = Math.abs(i - ref.index);
                if (score < bestScore || (score === bestScore && distance >= bestDistance)) { return false; }
                var result = accept(nodes[i]);
                if (!result) { return false; }
                best = result; bestScore = score; bestDistance = distance;
                return score === (neighbors?.length || 0);
            }
            for (var i of preferred) { if (matches(i) && consider(i)) { return best; } }
            if (!indices.has(nodes)) {
                var byKey = new Map();
                for (var i = 0; i < nodes.length; i++) {
                    var key = keyOf(nodes[i]);
                    if (!wanted.has(key)) { continue; }
                    if (!byKey.has(key)) { byKey.set(key, []); }
                    byKey.get(key).push(i);
                }
                indices.set(nodes, byKey);
            }
            // Nearest candidates first, so equal neighborhood scores retain
            // ordinal proximity. An exact neighborhood needs no more scanning.
            var candidates = indices.get(nodes).get(ref.key) || [];
            var right = candidates.findIndex(index => index >= ref.index);
            if (right < 0) { right = candidates.length; }
            var left = right - 1;
            while (left >= 0 || right < candidates.length) {
                var closerOnLeft = left >= 0 && (right === candidates.length ||
                    ref.index - candidates[left] <= candidates[right] - ref.index);
                var i = closerOnLeft ? candidates[left--] : candidates[right++];
                if (!preferred.includes(i) && nodes[i].tagName === ref.tag && consider(i)) { break; }
            }
            return best;
        }
        function rowAtUnchangedTableLocation(table, block, neighbors) {
            // A live swap detaches the old row with its owner still attached
            // to it. Across page loads there is no old DOM to corroborate.
            var original = block.node?.closest('table');
            if (!original?.hasAttribute('data-md2-source-line') || !table) { return null; }
            var headerRows = original.tHead?.rows.length || 0;
            if (block.index < headerRows || table.rows.length !== block.group.count ||
                (table.tHead?.rows.length || 0) !== headerRows ||
                table.getAttribute('data-md2-source-line') !== original.getAttribute('data-md2-source-line') ||
                table.getAttribute('data-md2-source-end-line') !== original.getAttribute('data-md2-source-end-line') ||
                heldKey(table, true) !== heldKey(original, true)) { return null; }
            var rows = table.rows;
            if (keyOf(rows[block.index]) !== block.key) { return null; }
            // Verify the visible body row sequence. An old header may match a
            // different table even though this is the one the reader held.
            return neighbors.every(peer => peer.index < headerRows || keyOf(rows[peer.index]) === peer.key)
                ? rows[block.index] : null;
        }
        var useNode = node => node;
        for (var block of blocks) {
            if (block.node?.isConnected) { return block; }
            if (block.key === undefined) { continue; }
            var found;
            if (block.group) {
                // Two tables can have the same headers. Only choose an owner
                // that actually contains the record the reader was looking at.
                var neighbors = blocks.filter(peer => peer !== block && peer.group &&
                    peer.group.tag === block.group.tag && peer.group.index === block.group.index);
                var groups = collection(block.group.tag);
                if (block.group.tag === 'TABLE') {
                    found = rowAtUnchangedTableLocation(groups[block.group.index], block, neighbors);
                }
                if (!found) {
                    found = matching(groups, block.group, group => {
                        var items = group.tagName === 'TABLE' ? group.rows : group.children;
                        return matching(items, block, useNode, block.index + items.length - block.group.count, neighbors);
                    });
                }
            } else {
                found = matching(block.tag === 'IMG' ? collection('img') : main.children, block, useNode);
            }
            if (found) { block.node = found; return block; }
        }
        return null;
    }

    var referenceObserver, pinnedReference = null;
    function releaseReference() {
        if (referenceObserver) { referenceObserver.disconnect(); referenceObserver = null; }
        pinnedReference = null;
    }
    function currentPinnedReference() {
        if (pinnedReference && (!pinnedReference.node.isConnected ||
            Math.abs(window.scrollY - pinnedReference.expectedY) > 1)) {
            // A scrollbar movement may not deliver a page input gesture.
            releaseReference();
        }
        return pinnedReference;
    }
    window.__md2ChangeScrollSync = function (paused) {
        window.__md2ScrollSyncPaused = paused;
        clearTimeout(pending);
        pending = null;
        lastUserScrollIntentAt = 0;
        // A pending mode-entry pin belongs to the previous sync state.
        animatedPinEpoch++;
        suppressUntil = 0;
        releaseReference();
    };
    ['wheel', 'touchmove', 'mousedown', 'keydown'].forEach(function (type) {
        window.addEventListener(type, releaseReference, { passive: true, capture: true });
    });
    function pinReference(blocks, y) {
        releaseReference();
        // An edit to the partially visible paragraph above a table
        // replaces that paragraph. Keep the next surviving block.
        var block = resolveHeldReference(blocks);
        if (!block) { window.scrollTo(window.scrollX, y); return; }
        var node = block.node;
        var reference = {node: node, top: block.top, expectedY: window.scrollY, findGroup: block.findGroup};
        pinnedReference = reference;
        function restore() {
            if (pinnedReference !== reference || !currentPinnedReference()) { return; }
            var currentTop = block.measureTop ? block.measureTop() : node.getBoundingClientRect().top;
            if (!Number.isFinite(currentTop)) {
                releaseReference();
                return;
            }
            var delta = currentTop - reference.top;
            if (Math.abs(delta) > 0.5) { window.scrollBy(0, delta); }
            reference.expectedY = window.scrollY;
        }
        // Earlier diagrams and images can finish long after the body
        // swap. A user gesture or explicit navigation releases the pin.
        referenceObserver = new ResizeObserver(restore);
        referenceObserver.observe(document.querySelector('main'));
        if (node.nodeType === Node.ELEMENT_NODE) { referenceObserver.observe(node); }
        restore();
    }

    function captureHeldReference() {
        var blocks = visibleReferences().map(function (block) {
            return { tag: block.tag, key: heldKey(block.node), index: block.index,
                top: block.top, group: block.group };
        });
        return { y: window.scrollY, blocks: blocks, find: captureHeldFind() };
    }
    window.__md2CaptureReference = captureHeldReference;

    var outgoingReference = null;
    var scrollbarPressed = false;
    window.__md2BeginHeldReload = function (token, page) {
        if (location.href.split('#')[0] !== page) { return null; }
        outgoingReference = {token, y: window.scrollY, sequence: 0, userIntent: false};
        return window.__md2CaptureReference();
    };

    function publishOutgoingReference() {
        var outgoing = outgoingReference, y = window.scrollY;
        if (!outgoing?.userIntent || y === outgoing.y) { return; }
        outgoing.y = y;
        window.webkit.messageHandlers.\#(reloadMessageName).postMessage({
            token: outgoing.token, sequence: ++outgoing.sequence, place: captureHeldReference()
        });
    }

    window.__md2NoteHeldReloadScroll = function (event) {
        if (!outgoingReference || !event.isTrusted || (event.type === 'wheel' && event.deltaY === 0)) { return; }
        outgoingReference.userIntent = true;
        // WebKit can apply the wheel movement before delivering the DOM input.
        publishOutgoingReference();
    };

    window.__md2NoteHeldReloadScrollbarDrag = function (token) {
        if (outgoingReference?.token !== token || !scrollbarPressed) { return; }
        outgoingReference.userIntent = true;
        publishOutgoingReference();
    };

    function clearScrollbarPress() { scrollbarPressed = false; }
    window.addEventListener('mousedown', function (event) {
        if (!event.isTrusted || event.button !== 0) { return; }
        var root = document.documentElement, width = window.innerWidth, x = event.clientX;
        var clientWidth = root.clientWidth;
        // Overlay scrollbars leave no gutter. Their hit can target the page
        // background underneath, but should never depend on a press in prose.
        var onScrollbar = clientWidth < width ? x >= clientWidth :
            x >= width - \#(NSScroller.scrollerWidth(for: .regular, scrollerStyle: .overlay)) &&
            (event.target === root || event.target === document.body || event.target === document.querySelector('main'));
        scrollbarPressed = onScrollbar && x < width && root.scrollHeight > root.clientHeight;
    }, {capture: true, passive: true});
    // WebKit sends a drag to the scrollbar itself. A DOM move instead means
    // that a press in the possible overlay strip belonged to the document.
    window.addEventListener('mousemove', function (event) {
        if (event.isTrusted) { clearScrollbarPress(); }
    }, {capture: true, passive: true});
    window.addEventListener('mouseup', function (event) {
        // Releasing can follow a drag completed before the capture. A native
        // drag during this reload already armed any movement that arrives late.
        if (event.isTrusted && event.button === 0) { clearScrollbarPress(); }
    }, {capture: true, passive: true});
    window.addEventListener('blur', clearScrollbarPress);
    window.addEventListener('scroll', publishOutgoingReference, {passive: true});
    window.addEventListener('pagehide', function () {
        publishOutgoingReference();
        outgoingReference = null;
        clearScrollbarPress();
    });

    window.__md2RestoreReference = function (place) {
        pendingHeldFind = place.find || null;
        pinReference(place.blocks, place.y);
    };
    """#
}
