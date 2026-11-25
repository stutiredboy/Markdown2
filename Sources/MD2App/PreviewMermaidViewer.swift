import Foundation

/// Installed only on the live preview, in WebKit's isolated client world.
enum PreviewMermaidViewer {
    static let stateMessage = "mermaidViewerOpen"

    static func labels(language: AppLanguage) -> String {
        let labels = [L10n.text(.viewDiagramAtActualSize, language: language), L10n.text(.close, language: language)]
        return String(decoding: try! JSONEncoder().encode(labels), as: UTF8.self)
    }

    static func script(language: AppLanguage) -> String {
        return #"""
        (() => {
            const main = document.querySelector('main');
            if (!main?.querySelector('.diagram-mermaid')) return;
            let [openLabel, closeLabel] = \#(labels(language: language));
            window.__md2SetMermaidViewerLabels = labels => {
                [openLabel, closeLabel] = labels;
                main.querySelectorAll('.md2-diagram-action').forEach(button => button.setAttribute('aria-label', openLabel));
                if (viewer) {
                    viewer.dialog.setAttribute('aria-label', openLabel);
                    viewer.canvas.setAttribute('aria-label', openLabel);
                    viewer.closeButton.setAttribute('aria-label', closeLabel);
                }
            };
            const style = document.createElement('style');
            style.textContent = `
                .md2-diagram-action, .md2-diagram-viewer button {
                    display: block; margin-left: auto; padding: 3px 8px; cursor: pointer;
                    font: 500 13px/1.4 -apple-system, sans-serif; color: var(--text);
                    border: 1px solid var(--border); border-radius: 5px; background: var(--code-bg);
                }
                .md2-diagram-action[hidden] { display: none; }
                .md2-diagram-action::before, .md2-diagram-viewer button::before { content: attr(aria-label); }
                html:has(.md2-diagram-viewer[open]) { overflow: hidden; }
                .md2-diagram-viewer[open] {
                    position: fixed; inset: 0; margin: 0; box-sizing: border-box;
                    width: 100%; height: 100%; max-width: none; max-height: none;
                    display: flex; flex-direction: column; gap: 8px; padding: 10px;
                    border: 0; color: var(--text); background: var(--page);
                }
                .md2-diagram-canvas {
                    flex: 1; overflow: auto; overscroll-behavior: contain;
                    cursor: grab; touch-action: pan-x pan-y; user-select: none;
                }
                .md2-diagram-canvas:active { cursor: grabbing; }
                .md2-diagram-canvas > svg {
                    display: block; margin: auto; max-width: none !important;
                    width: var(--diagram-width) !important; height: var(--diagram-height) !important;
                }
            `;
            document.head.appendChild(style);

            let viewer = null;
            // WebKit collapses live Ranges when their nodes are reparented.
            // Find stores one range per matching text fragment. Retain its
            // endpoints when the viewer moves this diagram into or out of view.
            function moveDiagram(svg, move) {
                const endpoints = [];
                for (const range of CSS.highlights.get('md2-find') || []) {
                    if (svg.contains(range.startContainer)) {
                        endpoints.push([range, range.startContainer, range.startOffset, range.endOffset]);
                    }
                }
                move();
                for (const [range, text, start, end] of endpoints) {
                    range.setStart(text, start);
                    range.setEnd(text, end);
                }
            }
            function openDiagram(block, svg, button) {
                if (viewer || !svg.isConnected) return;
                const size = svg.viewBox.baseVal;
                const x = window.scrollX;
                const blockViewportTop = block.getBoundingClientRect().top;
                const dialog = document.createElement('dialog');
                dialog.className = 'md2-diagram-viewer';
                dialog.setAttribute('aria-label', openLabel);
                const closeButton = document.createElement('button');
                closeButton.type = 'button';
                closeButton.setAttribute('aria-label', closeLabel);
                closeButton.addEventListener('click', () => dialog.close());
                const canvas = document.createElement('div');
                canvas.className = 'md2-diagram-canvas';
                canvas.tabIndex = 0;
                canvas.setAttribute('role', 'region');
                canvas.setAttribute('aria-label', openLabel);
                canvas.style.setProperty('--diagram-width', size.width + 'px');
                canvas.style.setProperty('--diagram-height', size.height + 'px');

                // Scrollbars, wheel/touch and keyboard use native scrolling.
                // Dragging blank space or a node also pans with a one-button mouse.
                let drag = null;
                canvas.addEventListener('pointerdown', event => {
                    if (event.pointerType !== 'mouse' || event.button !== 0 || event.target.closest('a')) return;
                    drag = {x: event.clientX, y: event.clientY, left: canvas.scrollLeft, top: canvas.scrollTop};
                    canvas.setPointerCapture(event.pointerId);
                });
                canvas.addEventListener('pointermove', event => {
                    if (drag) canvas.scrollTo(drag.left + drag.x - event.clientX, drag.top + drag.y - event.clientY);
                });
                canvas.addEventListener('lostpointercapture', () => { drag = null; });

                // Keep the inline footprint and use the one rendered SVG. Cloning
                // its subtree would duplicate IDs for markers, styles and labels.
                const rect = svg.getBoundingClientRect();
                const slot = document.createElement('span');
                slot.style.cssText = `display:inline-block;width:${rect.width}px;height:${rect.height}px`;
                dialog.append(closeButton, canvas);
                // Keeping the dialog in the originating block also keeps its
                // labels searchable under main during actual-size viewing.
                block.appendChild(dialog);
                moveDiagram(svg, () => {
                    svg.replaceWith(slot);
                    canvas.appendChild(svg);
                });
                viewer = {dialog, block, slot, canvas, closeButton};
                dialog.addEventListener('close', () => {
                    viewer = null;
                    if (slot.isConnected) moveDiagram(svg, () => slot.replaceWith(svg));
                    dialog.remove();
                    if (block.isConnected) update(block);
                    window.dispatchEvent(new Event('resize'));
                    if (button.isConnected) {
                        button.focus({preventScroll: true});
                        // Text preceding the diagram can reflow while the dialog
                        // is open. Restore the block to its original viewport row.
                        window.scrollTo(x, window.scrollY + block.getBoundingClientRect().top - blockViewportTop);
                    }
                    window.webkit.messageHandlers.\#(stateMessage).postMessage(false);
                }, {once: true});
                dialog.showModal();
                canvas.focus({preventScroll: true});
                window.webkit.messageHandlers.\#(stateMessage).postMessage(true);
            }
            window.__md2CloseMermaidViewer = () => viewer?.dialog.close();

            function update(block) {
                if (!block.isConnected) { sizes.unobserve(block); return; }
                if (viewer?.block === block) return;
                const svg = block.querySelector(':scope > svg');
                if (!svg || !(svg.viewBox.baseVal.width > 0 && svg.viewBox.baseVal.height > 0)) return;
                let button = block.querySelector(':scope > .md2-diagram-action');
                if (!button) {
                    button = document.createElement('button');
                    button.type = 'button';
                    button.className = 'md2-diagram-action';
                    // Generated text stays out of document searches and copies.
                    button.setAttribute('aria-label', openLabel);
                    button.setAttribute('aria-haspopup', 'dialog');
                    button.addEventListener('click', event => {
                        if (event.isTrusted) openDiagram(block, svg, button);
                    });
                    block.appendChild(button);
                    sizes.observe(block);
                }
                button.hidden = svg.getBoundingClientRect().width + 1 >= svg.viewBox.baseVal.width;
            }
            const sizes = new ResizeObserver(entries => entries.forEach(entry => update(entry.target)));
            main.querySelectorAll('.diagram-mermaid').forEach(update);
            // Mermaid replaces the block's text with the finished SVG, including
            // on live edits. Ignore mutations in its potentially large subtree.
            new MutationObserver(records => {
                if (viewer && !viewer.slot.isConnected) viewer.dialog.close();
                for (const record of records) {
                    if (record.target.matches('.diagram-mermaid')) update(record.target);
                }
            }).observe(main, {subtree: true, childList: true});
        })();
        """#
    }
}
