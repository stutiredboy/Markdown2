# Remote resources in preview and exports

Markdown2 blocks automatic HTTP(S) resources from document content by default.
Local images and the bundled math, diagram, font and style assets keep working.
Ordinary links remain available when you choose to open them.

## Inspect declared image origins

Choose **Details…** in the document's **Remote Images** bar in Write, Split or
Read mode. The report shows the scheme, host and nondefault port of supported
absolute HTTP(S) image sources in the current rendered body. Markdown reference
images and supported HTML images count too. Each rendered image element counts
once, including repeated uses of the same address. Credentials, paths, queries
and fragments are excluded. Origins appear as selectable text.

Actual blocked-request counts and redirect destinations are unknown. Alternate
image sources, CSS resources, resources inside SVG and assets created by diagram
engines fall outside the inventory. The sheet marks the list incomplete when it
encounters an ambiguous or unsupported HTTP(S) address or reaches an inspection
limit (2 MiB of rendered body, 8,192 UTF-16 units per image source, or 128 origins).

Opening Details reads an existing render in memory. It issues no requests and
leaves the source, Undo history and permission intact. Reloading the document or
changing its image permission dismisses the sheet and invalidates its report.

## Allow images for one document

Choose **Allow for This Document…** in the document's remote-image control.
The document's confirmation dialog opens on **Cancel**. Review the explanation,
then choose **Allow Remote Images** to grant permission. This permits HTTP(S)
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
| DOCX / EPUB | Pandoc conversion and version probes run with network access denied, including child processes. Conversion stops if confinement cannot be applied. Independent Word and EPUB readers may load remote resources when opening the output. |

HTML includes the bundled math and diagram engines. Images generated inside a
diagram are omitted; ordinary vector geometry and supported colors, fonts and
local fragment references are retained. Ambiguous CSS resource expressions or
SVG features outside the supported safe subset are omitted or rejected. Local
SVG files with external resources or active content cannot be embedded. This can
change the appearance of resource-dependent diagrams. The notice distinguishes
omissions from a fully embedded export; it does not claim to enumerate every
future image a diagram engine could create. User-activated hyperlinks remain links.

PDF/Print wait for supported HTML images, video poster images and rendered
CSS/SVG image references, including SVG filter images.
The latter may need an additional in-page image decode request, bounded to 256
unique URLs and the same total deadline. This is not a downloaded-byte quota.
Unsupported or unverifiable image work fails visibly rather than producing a
silently incomplete successful export.

## Export to DOCX or EPUB

Choose **File → Export To → DOCX** or **EPUB**. With no Pandoc installed, the
command shows installation guidance. Install it yourself with the macOS
installer or `brew install pandoc`, then invoke the command again. Markdown2
checks `/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin` and absolute directories
on its process PATH. [Pandoc installation instructions](https://pandoc.org/installing.html)

The save panel explains the conversion limits before you choose a destination.
Pandoc converts the current Markdown with its own layout and syntax support.
Preview diagrams, styling and some Markdown extensions may look different or be
omitted. A saved document's relative images resolve from its folder. An
untitled document can export directly, with no document folder for relative
resources. Remote images cannot be downloaded during conversion.

Choose **Cancel** in the save panel or in the window's status bar while
conversion runs. Editing, reloading or closing the document also invalidates the
current export. A canceled or failed conversion preserves an existing
destination. Markdown2 checks for changes to the destination before publishing.
Word and EPUB readers apply their own resource policy after export.
For self-contained offline sharing, choose **HTML**.

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
