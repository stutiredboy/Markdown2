## Context

`DocumentStore.exportHTML()` renders the document with `assetMode: .inline`, so styles and the math and diagram engines are already in the page, then passes it to `SelfContainedHTMLBuilder.build`. The builder finds `<img>` tags with a regex and replaces each local image's `src` with a `data:` URI. A source it cannot inline stays as it was, and nobody hears about it.

In the page the builder reads, `<img src>` is the only thing that loads a resource. `HTMLSafety.sanitizeTag` rebuilds raw HTML from an allowlist: `<img>` keeps `src`, `alt`, `width`, `height` and `title`, and no allowed tag keeps `style`, `srcset`, or any other attribute that loads a resource. The fonts in the KaTeX stylesheet are all `data:` URIs. Links stay links, which is what a reader expects of them. The one exception appears only when the page is displayed: see "Images in diagram source are a stated limit".

## Decisions

### `build` returns the report with the HTML

`build(html:baseURL:)` returns `Output`, with `html`, `remoteImages` and `unembeddedLocalImages`. The report comes from the same loop that does the inlining, so it cannot disagree with what the file contains. A local image that passes every check but fails to read still lands in the report, because the test for "embedded" is that a `data:` URI was actually produced.

`DocumentStore` was the only production caller, so the test call sites take `.html` rather than keeping a `String` overload that only tests would use.

Sources fall into four cases:

| Source | Result |
|---|---|
| empty, or `data:` | nothing to embed, not reported |
| `http://`, `https://` | kept, `remoteImages` |
| local, embedded | replaced with a `data:` URI |
| anything else | kept, `unembeddedLocalImages` |

"Anything else" covers a missing or unreadable file, a file that is not an image, a relative path with no base URL (an untitled document), and sources the builder cannot read as a path. They share a group because the user does the same thing about all of them, and the notice says the image may not display rather than guessing at the reason.

Names are for reading. HTML escapes are undone for both groups, and percent escapes for local names, so `my%20pic.png` shows as `my pic.png`. Remote URLs keep their percent escapes, since those are part of the address. Each name appears once, in document order, so an image used ten times does not fill the list.

### The scan covers `<main>` only

The regex ran over the whole page, including the inlined engines. That did no harm while a non-matching source was silently skipped, because the bundled JavaScript has `<img src=` string literals that resolve to nothing:

- `katex.min.js`, in every export: `<img src="'+l.escape(this.src)+'" alt="…`
- `mermaid.min.js`, in documents with a Mermaid diagram: the same code from its bundled KaTeX

Reporting those would show every user a notice about an image that does not exist, on every export. The builder now scans the content of `<main>`, which is where `MarkdownRenderer.htmlDocument` puts the whole body. A document cannot end that range early: `main` is not in the raw HTML allowlist, so an authored `</main>` is escaped to text. A string with no `<main>`, which only tests pass, is scanned whole.

*Alternative considered:* skipping `<script>…</script>` and `<style>…</style>` inside the regex. It also works: on a page holding the Mermaid bundle it found the right images in 0.07 s. But the regex would gain an alternative whose matches the loop must throw away, to avoid depending on a marker that is already a contract: `RenderedDocument.body` is defined as the content of `<main>`, and the live preview relies on that too.

`exportHTMLWritesSelfContainedFileAndPreservesDocumentState` guards the coupling to the template: it exports a real page and requires no notice, so the notice appears and the test fails if `<main>` is ever renamed.

### One notice after the file is written

The export is a success, and the file is on disk, so the notice is not an error and does not stop anything. It uses the existing `alert` and `DocumentAlert` path, which needed no new UI. The title names the file; the detail has up to two groups:

```text
notes.html was exported, but some images are not embedded.

Remote images stay as links and need a network connection:
https://example.com/r.png

These local images could not be embedded and may not display:
missing.png
```

A failed write shows the existing "Could not export" alert and no notice, since there is no file to describe.

Each group lists at most five names, then "…and N more". The cap is per group so that a document with many remote images cannot push a missing local image out of the list, and the local group is usually the one the user can fix. Five names per group keeps the worst case at about a dozen lines. The count goes through the existing `%@` `alertText` helper as a string. Image names are joined after formatting, so a `%` in a name is never read as a format specifier.

### Images in diagram source are a stated limit

Mermaid runs with `securityLevel: "loose"`, so HTML in a label is live. In a real exported page, a label holding `<img>` tags requested a remote and a relative image when the page was displayed, and the builder reported neither. In the page the builder reads, that source is escaped text inside the diagram block. The `<img>` exists only after Mermaid has run.

This change does not detect those images. Doing so means reading diagram source, which is in languages the builder does not parse, so a heuristic would find some images and miss others. A notice that looks complete and is not is the problem this change exists to fix. Embedding them would also mean rewriting diagram source. The spec, `Docs/MarkdownSupport.md`, the matrix and both READMEs state the limit instead, and `imageInDiagramSourceIsNeitherInlinedNorReported` pins it.

Whether Mermaid should run at a stricter security level is a wider question, because it would also change what the preview renders, so it stays out of this change.

### Claims describe the behavior

The README entries now say local images are embedded, remote images stay links and need the network, the app lists the Markdown and HTML images it did not embed, and images from diagram source are neither embedded nor listed. `Docs/CompatibilityMatrix.md` is generated, so the change is made in `compatibility-matrix.json` and the page is regenerated.

The spec's first requirement keeps its name and now scopes "no network access" to everything except the images the export reports and images from diagram source. Its Purpose line, which an archive does not touch, is corrected by hand.

## Verification

- **New tests:** the report and the notice run in plain `swift test`. The `DocumentStore` cases go through the real renderer and write a real file, so they exercise the inlined engines that caused the false positive.
- **Mutation checks:** each of these was made on purpose and failed tests: scanning the whole page (12 failed expectations, including every no-notice case), showing the notice after a failed write, leaving the report in reverse order, counting `data:` URIs, and raising the cap.
- **Diagram source, in a browser:** the real renderer and builder produced a page with `<img>` tags in a Mermaid label, and headless Chromium loaded it from a local server. Mermaid created both images and requested both files, and the builder had reported nothing.
- **Not verified on screen.** The Mac's screen was locked for this work, so nobody saw the notice in a real window. The text is tested. Its layout is not, though it uses the same `.alert(item:)` as every other document alert and only the length of its text is new.

## Risks / Trade-offs

- **A notice on every export of a document with remote images.** Someone who keeps remote images on purpose sees it each time. The notice is one dismissal, and it is the only way to tell apart the exports that are complete, so it stays unconditional. A "don't show again" setting can follow if people ask for it.
- **The notice can include a very long URL.** The list caps the number of names, not their length, so a long URL wraps inside the alert.
- **A local name may not be exactly what the author typed.** It is read back from rendered HTML, so an entity the builder does not decode stays spelled as an entity in the notice. The image is still reported, and only the spelling differs.
