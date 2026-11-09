# Portable image attachments

Markdown2 copies dropped or pasted image files into `assets` beside the current
Markdown document by default. Screenshots pasted from the clipboard are saved as
PNG there too. Save an untitled document first when prompted; canceling that save
inserts nothing.

In Settings, **Dropped / Pasted Image Files** offers **Link Original Location**.
That choice inserts an absolute path and leaves the image in its current folder.
It applies to future file drops/pastes; it does not move existing files or change
previous references. **Image Attachment Folder** changes the relative directory
used by new copies. Paths outside the document directory are not implicit write
permission: a symlink leading outside it requires approval of that exact resolved
directory. Images in an external directory are not carried by moving the document
folder alone.

Choose **File > Collect Local Images…** to copy supported local images already
referenced by the document and replace their destinations with relative paths.
Move the Markdown file and its attachment folder together. The command reports
copied files, processed references, excluded block count and reasons for references
it could not collect. A maximum of eight detailed issues is shown, followed by the
remaining count. Repeated paths share one copy, and images already in the attachment
folder are validated and retained without making another copy.

The first version safely rewrites simple, single-line inline Markdown images such
as `![caption](../pictures/plot.png "title"){width=480}` or
`![caption](<../pictures/图片 sample.png> "title")` in ordinary top-level text.
Only destination ranges change: angle delimiters, surrounding spaces, alt text,
titles, figure attributes, line endings
and surrounding source remain intact. Percent-encoded paths and Chinese filenames
are supported. Its deliberately conservative source scanner does not collect:

- Reference-style images (`![caption][figure]`, `![figure][]`, `![figure]`), or their
  shared definitions. Ordinary links sharing those definitions remain unchanged.
- Blocks containing list/quote containers, indented or fenced code, inline code,
  HTML, math, YAML front matter, or definition syntax. This includes potentially
  ordinary images in the same excluded block; the report names this limitation.
- Complex inline destinations such as escaped punctuation,
  nested parentheses, multiline images, images nested in link labels/titles, or single-quoted titles.
- Remote URLs, embedded data URLs, unknown schemes, diagram-internal resources,
  or resource links inside an SVG. No network resources are downloaded. A copied
  SVG with its own external dependencies may still require those dependencies.

Missing, unreadable, invalid or over-budget images remain unchanged. File suffixes
alone are not trusted: copying and HTML export share full image validation, bounded
file reads and decoding limits (32 MiB per input, 128 MiB per operation, dimensions
up to 16,384, 40 million pixels per image, 256 frames and 160 million decoded pixels
per operation). Collection scans at most 4 million UTF-16 units and 10,000 image
candidates; larger input is rejected without partial source edits.

Validation and copying run in the background. The source edit is one Undo action.
Undo restores the original text but keeps copied files, because other documents
may use them. If the document, path, selection or input state changes while the
operation runs, Markdown2 refuses the delayed source edit and reports any completed
copies. A closed document likewise cannot receive a delayed edit. Existing image
files and attachment filenames are never overwritten.

中文：默认将拖入或粘贴的图片复制到文档旁的附件文件夹；可在设置中改为链接原位置。
“文件 > 收集本地图片…”仅处理可安全定位的简单顶层行内图片，并报告未处理范围。
移动资料时须连同文档和附件文件夹一起移动；引用式图片、列表或引用块、代码、HTML、
公式、图表内部资源及网络图片不保证已收集。撤销只恢复文本，不删除已复制的附件。
