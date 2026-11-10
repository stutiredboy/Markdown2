import MD2Core

enum ExportImageReadiness {
    /// Runs after diagram settling. Native WebKit image decoding is used only
    /// for image URLs already present in the rendered DOM/computed styles. The
    /// finite probe set never follows documents or recursively discovers URLs.
    static func script(policy: RemoteResourcePolicy) -> String {
        let allowRemote = policy == .allowRemoteImages ? "true" : "false"
        return #"""
        (function () {
            const allowRemote = \#(allowRemote);
            const state = window.__md2ExportImageReadiness || (window.__md2ExportImageReadiness = { probes: new Map() });
            let pending = false, failed = false;
            function remote(source) { return /^https?:/i.test(source) || /^\/\//.test(source); }
            function probe(source) {
                if (!source || source[0] === '#') return;
                if (!allowRemote && remote(source)) return;
                let absolute;
                try { absolute = new URL(source, document.baseURI).href; } catch (_) { failed = true; return; }
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
                    placeholder.textContent = 'Remote image blocked' + (image.alt ? ': ' + image.alt : '');
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
            document.querySelectorAll('svg image').forEach(function (image) {
                probe(image.getAttribute('href') || image.getAttributeNS('http://www.w3.org/1999/xlink', 'href'));
            });
            // getComputedStyle supplies canonical CSS serialization. Unsupported
            // resource expressions fail rather than being assumed settled.
            const properties = ['background-image', 'mask-image', '-webkit-mask-image', 'border-image-source', 'list-style-image', 'content'];
            const elements = document.querySelectorAll('main, main *');
            if (elements.length > 100000) return { ready: false, failed: true };
            function scan(style) {
                properties.forEach(function (property) {
                    const value = style.getPropertyValue(property);
                    if (!/url\(/i.test(value)) return;
                    const urls = /url\(\s*(?:"([^"\\]*)"|'([^'\\]*)'|([^\s)'"\\]+))\s*\)/gi;
                    let match, remainder = value;
                    while ((match = urls.exec(value))) {
                        probe(match[1] || match[2] || match[3]);
                        remainder = remainder.replace(match[0], '');
                    }
                    if (/url\(/i.test(remainder)) failed = true;
                });
            }
            elements.forEach(function (element) {
                scan(getComputedStyle(element));
                scan(getComputedStyle(element, '::before'));
                scan(getComputedStyle(element, '::after'));
            });
            return { ready: !pending && !failed, failed: failed };
        })();
        """#
    }
}
