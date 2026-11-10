import Foundation
import MD2Core

enum ExportImageReadiness {
    /// Runs after diagram settling. Native WebKit image decoding is used only
    /// for image URLs already present in the rendered DOM/computed styles. The
    /// finite probe set never follows documents or recursively discovers URLs.
    static func script(policy: RemoteResourcePolicy, blockedImageLabel: String = "Remote image blocked") -> String {
        let allowRemote = policy == .allowRemoteImages ? "true" : "false"
        let label = String(decoding: try! JSONEncoder().encode(blockedImageLabel), as: UTF8.self)
        return #"""
        (function () {
            const allowRemote = \#(allowRemote);
            const blockedImageLabel = \#(label);
            const state = window.__md2ExportImageReadiness || (window.__md2ExportImageReadiness = { probes: new Map() });
            let pending = false, failed = false;
            function remote(source) { return /^https?:/i.test(source) || /^\/\//.test(source); }
            function probe(source) {
                if (!source || source[0] === '#') return;
                if (!allowRemote && remote(source)) { state.blocked = true; return; }
                let absolute;
                try { absolute = new URL(source, document.baseURI).href; } catch (_) { failed = true; return; }
                if (absolute.includes('#') && absolute.split('#')[0] === document.baseURI.split('#')[0]) return;
                if (!/^(https?:|data:|md2-local-image:)/i.test(absolute)) { failed = true; return; }
                if (!state.probes.has(absolute)) {
                    if (state.probes.size >= 256) { failed = true; return; }
                    const record = { ready: false, failed: false, image: new Image() };
                    state.probes.set(absolute, record);
                    record.image.onload = function () {
                        record.image.decode().then(function () { record.ready = true; }, function () { record.failed = true; });
                    };
                    record.image.onerror = function () { record.failed = true; };
                    record.image.src = absolute;
                }
                const record = state.probes.get(absolute);
                if (record.failed) failed = true;
                else if (!record.ready) pending = true;
            }
            Array.from(document.images).forEach(function (image) {
                const source = image.currentSrc || image.getAttribute('src') || '';
                if (!allowRemote && remote(source)) {
                    const placeholder = document.createElement('span');
                    placeholder.className = 'md2-export-image-placeholder';
                    placeholder.textContent = blockedImageLabel + (image.alt ? ': ' + image.alt : '');
                    image.replaceWith(placeholder);
                    return;
                }
                if (!source) return;
                if (!image.complete) { pending = true; return; }
                if (!image.naturalWidth) { failed = true; return; }
                if (!image.__md2Decoded) {
                    if (!image.__md2Decoding) {
                        image.__md2Decoding = true;
                        image.decode().then(function () { image.__md2Decoded = true; }, function () { image.__md2DecodeFailed = true; });
                    }
                    if (image.__md2DecodeFailed) failed = true;
                    else pending = true;
                }
            });
            document.querySelectorAll('svg image, svg feImage').forEach(function (image) {
                probe(image.getAttribute('href') || image.getAttributeNS('http://www.w3.org/1999/xlink', 'href'));
            });
            // getComputedStyle supplies canonical CSS serialization. Unsupported
            // resource expressions fail rather than being assumed settled.
            const properties = ['background-image', 'mask-image', '-webkit-mask-image', 'border-image-source',
                '-webkit-mask-box-image-source', 'list-style-image', 'shape-outside', 'content'];
            const elements = document.querySelectorAll('main, main *');
            if (elements.length > 100000) return { ready: false, failed: true };
            function withoutContentStrings(value) {
                let result = '', depth = 0;
                for (let i = 0; i < value.length; i++) {
                    const character = value[i];
                    if (character === '(') depth++;
                    else if (character === ')') depth--;
                    if (!depth && (character === '"' || character === "'")) {
                        const quote = character;
                        for (i++; i < value.length; i++) {
                            if (value[i] === '\\') { i++; continue; }
                            if (value[i] === quote) break;
                        }
                    } else result += character;
                }
                return result;
            }
            function scan(style) {
                properties.forEach(function (property) {
                    let value = style.getPropertyValue(property);
                    // Text that happens to spell url(...) is not an image URL.
                    if (property === 'content') value = withoutContentStrings(value);
                    const urls = /url\(\s*(?:"([^"\\]*)"|'([^'\\]*)'|([^\s)'"\\]+))\s*\)/gi;
                    let match, remainder = value, sources = [];
                    while ((match = urls.exec(value))) {
                        sources.push(match[1] || match[2] || match[3]);
                        remainder = remainder.replace(match[0], '');
                    }
                    if (/url\(/i.test(remainder) || /[\\@]/.test(remainder)) { failed = true; return; }
                    // A finite computed-value grammar, not a CSS parser. In
                    // particular image-set/cross-fade/paint and future image
                    // functions cannot silently become "nothing to await".
                    const functions = remainder.match(/[a-zA-Z-]+\s*\(/g) || [];
                    const supported = /^(linear-gradient|radial-gradient|conic-gradient|repeating-linear-gradient|repeating-radial-gradient|repeating-conic-gradient|rgb|rgba|hsl|hsla|hwb|lab|lch|oklab|oklch|color|color-mix|light-dark|calc|min|max|clamp|circle|ellipse|inset|polygon|path|counter|counters)\s*\($/i;
                    if (functions.some(name => !supported.test(name))) { failed = true; return; }
                    const keywords = ['', 'none', 'normal', 'open-quote', 'close-quote', 'no-open-quote', 'no-close-quote', 'margin-box', 'border-box', 'padding-box', 'content-box'];
                    if (!functions.length && !remainder.split(',').every(part => keywords.includes(part.trim()))) {
                        failed = true; return;
                    }
                    sources.forEach(probe);
                });
            }
            elements.forEach(function (element) {
                scan(getComputedStyle(element));
                scan(getComputedStyle(element, '::before'));
                scan(getComputedStyle(element, '::after'));
            });
            if (state.blocked && !document.getElementById('md2-export-blocked-resources')) {
                const note = document.createElement('p');
                note.id = 'md2-export-blocked-resources';
                note.className = 'md2-export-image-placeholder';
                note.textContent = blockedImageLabel;
                (document.querySelector('main') || document.body).prepend(note);
            }
            return { ready: !pending && !failed, failed: failed };
        })();
        """#
    }
}
