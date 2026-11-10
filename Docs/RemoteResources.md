# Remote resources in preview and exports

Markdown2 blocks automatic HTTP(S) resources from document content by default.
Local images and the bundled math, diagram, font and style assets keep working.
Ordinary links remain available when you choose to open them.

## Allow images for one document

Choose **Allow for This Document…** in the document's remote-image control,
read the explanation, then confirm **Allow Remote Images**. This permits HTTP(S)
images in that window's preview, PDF export and Print, including image resources
named by CSS and diagrams. It does not permit remote scripts, stylesheets, fonts,
frames, media or background API requests.

Image servers can learn your network address and request information. The grant
is for this document window and session; it is not a trusted-domain list. It can
reach any HTTP(S) image address the document names, including a local-network
address. It is not a LAN filter or DNS-rebinding firewall.

**Block Remote Images** revokes the grant and cancels obsolete preview/export
work. Requests already sent cannot be recalled. A different document, explicit
open, reload or recovered draft starts blocked. Normal edits and a rename of the
same document retain its current permission. Other windows do not inherit it.
The choice does not edit Markdown, mark the document dirty or add an Undo action;
it is not stored in preferences, front matter, recovery records or export presets.

WebKit contexts use temporary data stores and a no-referrer page policy. They do
not inherit browser login cookies or share a document's browser cache with another
document or export. These controls concern document resources; they do not promise
that macOS makes no DNS or other platform network requests.

## What each export includes

| Output | Remote-resource behavior |
| --- | --- |
| PDF / Print | Uses the document's current image permission captured when the operation starts. Supported image work must settle within the existing 30-second total deadline or the operation fails. Revocation, replacement or close cancels obsolete work; a failed or canceled operation preserves an existing destination. |
| HTML | Always offline, regardless of the preview grant. Validated local/data images are embedded. Remote images and local images that cannot be embedded become readable placeholders, with an export notice. No remote image downloader is used. |
| DOCX / EPUB backend | Pandoc conversion and version probes run with network access denied, including child processes. Conversion stops if confinement cannot be applied. Independent Word/EPUB readers are outside this policy and may load remote resources when opening the output. Use HTML or PDF for controlled offline sharing. These backend commands are not yet exposed in the app menus. |

HTML includes the bundled math and diagram engines. Images generated inside a
diagram are omitted; ordinary vector geometry and supported colors, fonts and
local fragment references are retained. Ambiguous CSS resource expressions or
SVG features outside the supported safe subset are omitted or rejected. Local
SVG files with external resources or active content cannot be embedded. This can
change the appearance of resource-dependent diagrams. The notice distinguishes
omissions from a fully embedded export; it does not claim to enumerate every
future image a diagram engine could create. User-activated hyperlinks remain links.

PDF/Print wait for supported HTML images and rendered CSS/SVG image references.
The latter may need an additional in-page image decode request, bounded to 256
unique URLs and the same total deadline. This is not a downloaded-byte quota.
Unsupported or unverifiable image work fails visibly rather than producing a
silently incomplete successful export.

## Implementation and verification

The trusted `RemoteResourcePolicy` argument is separate from source syntax.
`DocumentStore` owns a window-local policy/identity epoch; `DocumentRenderWorker`
captures it, and obsolete completions cannot publish after an epoch change.
`WebDocumentLoader` enforces native WebKit resource rules in addition to the page
CSP. Policy-only changes retire the old host even when the Markdown is identical.
HTML rendering forces the offline policy and validates embedded image bytes.

The Pandoc boundary uses a fixed local process sandbox. If that operating-system
facility is missing or rejects the launch, the backend fails closed. It does not
silently retry unrestricted and does not certify all relationships or resources
inside a DOCX/EPUB archive.

Regression coverage combines policy/state tests with counted HTTP canaries,
positive controls, delayed requests, real PDF/Print preparation and reopened HTML
artifacts. See [document loading](WebDocumentLoading.md) and the
[acceptance contract](Plans/remote-resources/PLAN.md) for the tested boundaries.
