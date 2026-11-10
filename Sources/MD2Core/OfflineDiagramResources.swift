import Foundation

/// Portable HTML cannot validate images synthesized later by a diagram engine.
/// Conservatively omit those images and external CSS/SVG resource references,
/// retaining ordinary diagram geometry, fragment paint servers and hyperlinks.
enum OfflineDiagramResources {
    static func script(imageLabel: String) -> String {
        let label = String(decoding: try! JSONEncoder().encode(imageLabel), as: UTF8.self)
            .replacingOccurrences(of: "<", with: "\\u003c")
            .replacingOccurrences(of: ">", with: "\\u003e")
        return "var md2OfflineImageLabel = \(label);\n" + #"""
        function md2OfflineDiagram(root) {
            var omitted = false;
            // CSSOM decodes CSS tokens before this deliberately small value
            // grammar. Ambiguous escapes, URI separators and at-rules fail
            // closed; ordinary colors/metrics/fonts and url(#fragment) remain.
            function safeValue(value) {
                if (!/^[a-zA-Z0-9#.,%+\-\s()"'_]*$/.test(value)) { return false; }
                var urls = value.match(/\burl\s*\([^)]*\)/gi) || [];
                for (var i = 0; i < urls.length; i++) {
                    if (!/^url\(\s*["']?#[a-zA-Z0-9_-]+["']?\s*\)$/i.test(urls[i])) { return false; }
                }
                // Permit only scalar/color/geometry functions. In particular,
                // attr(), image-set(), src() and future resource functions do
                // not become a second URL grammar hidden inside a CSS value.
                var functions = value.match(/[a-zA-Z-]+\s*\(/g) || [];
                var safeFunctions = /^(url|var|env|calc|min|max|clamp|rgb|rgba|hsl|hsla|hwb|lab|lch|oklab|oklch|color|color-mix|light-dark|linear-gradient|radial-gradient|conic-gradient|repeating-linear-gradient|repeating-radial-gradient|scale|scaleX|scaleY|translate|translateX|translateY|rotate|skew|skewX|skewY|matrix|blur|brightness|contrast|drop-shadow|grayscale|hue-rotate|invert|opacity|saturate|sepia)\s*\($/i;
                return functions.every(function (name) { return safeFunctions.test(name); });
            }
            function declarations(style) {
                var result = '';
                for (var i = 0; i < style.length; i++) {
                    var name = style[i], value = style.getPropertyValue(name);
                    if (safeValue(value)) {
                        result += name + ':' + value + (style.getPropertyPriority(name) ? ' !important' : '') + ';';
                    } else { omitted = true; }
                }
                return result;
            }
            var styles = root.querySelectorAll('style');
            for (var s = 0; s < styles.length; s++) {
                try {
                    // A constructed stylesheet is never adopted. Its parser
                    // does not fetch @import, and every non-style rule is dropped.
                    var sheet = new CSSStyleSheet();
                    sheet.replaceSync(styles[s].textContent);
                    var clean = '';
                    for (var r = 0; r < sheet.cssRules.length; r++) {
                        var rule = sheet.cssRules[r];
                        if (rule.type === 1) { clean += rule.selectorText + '{' + declarations(rule.style) + '}'; }
                        else { omitted = true; }
                    }
                    if (/@import/i.test(styles[s].textContent)) { omitted = true; }
                    styles[s].textContent = clean;
                } catch (_) { styles[s].remove(); omitted = true; }
            }
            var images = root.querySelectorAll('img,image');
            for (var j = 0; j < images.length; j++) {
                var image = images[j], svg = image.namespaceURI === 'http://www.w3.org/2000/svg';
                var placeholder = svg ? document.createElementNS('http://www.w3.org/2000/svg', 'text') : document.createElement('span');
                placeholder.textContent = md2OfflineImageLabel + (image.getAttribute('alt') ? ': ' + image.getAttribute('alt') : '');
                placeholder.setAttribute('class', 'md2-offline-image');
                image.replaceWith(placeholder); omitted = true;
            }
            var active = root.querySelectorAll('script,iframe,object,embed,link,video,audio,source,track,base,meta,animate,set,animateMotion,animateTransform,mpath,feImage');
            for (var a = 0; a < active.length; a++) { active[a].remove(); omitted = true; }
            var nodes = root.querySelectorAll('*');
            for (var n = 0; n < nodes.length; n++) {
                var node = nodes[n], attrs = Array.from(node.attributes);
                for (var k = 0; k < attrs.length; k++) {
                    var attr = attrs[k], name = attr.name.toLowerCase(), value = attr.value;
                    if (name === 'style') { node.setAttribute('style', declarations(node.style)); continue; }
                    if (name === 'href' || name === 'xlink:href') {
                        if (node.localName.toLowerCase() === 'a') {
                            // Hyperlinks retain the existing CSP/activation
                            // boundary. They are not automatic subresources.
                            continue;
                        } else if (/^#[a-zA-Z0-9_-]+$/.test(value)) { continue; }
                        node.removeAttribute(attr.name); omitted = true; continue;
                    }
                    if (/^(src|srcset|poster|data|background|action|formaction)$/i.test(name) || /^on/i.test(name)) {
                        node.removeAttribute(attr.name); omitted = true; continue;
                    }
                    // SVG presentation attributes can also carry CSS resources.
                    if (/^(fill|stroke|filter|clip-path|mask|cursor|marker-start|marker-mid|marker-end)$/.test(name)
                        && !safeValue(value)) {
                        node.removeAttribute(attr.name); omitted = true;
                    }
                }
            }
            if (omitted) { window.__md2OfflineDiagramResourcesOmitted = true; }
        }
        """# + "\n"
    }
}
