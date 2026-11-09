# Container parsing limits

Each render shares one budget across link-reference collection, metadata/outline
scans, blockquote/list body rendering, and recursive list construction. The limit
is 64 active traversal frames and 16 MiB of cumulative scanned UTF-8 bytes (plus
list-item visits), not 16 MiB of source file size. Repeated scans of nested content
all debit the same budget. Cancellation is checked before entering and while
walking each recursive traversal.

If a pass exceeds either limit, the renderer discards partial metadata and HTML
and displays the entire original source as escaped text in a `pre` block. This
preserves the text following an excessive container and prevents hidden link or
footnote definitions from leaking into a partially rendered result. The source
file is never changed. The fallback has no outline, and its statistics describe
the literal source. Normal documents below the limits retain their output.

The limits bound the existing recursive parser; this is not an iterative parser
rewrite or a general time/memory limit on all inline syntax. Particularly large
or repeatedly nested documents can intentionally receive the literal fallback.

`MarkdownNestingSafetyTests` launches isolated XCTest child processes for quotes,
lists and mixed containers at 128, 512 and 1024 levels on a detached task. It also
checks a shallow but wide workload, escaping, text after the container, and that
a subsequent ordinary render does not inherit exhausted state. The conformance
baseline guards ordinary parser behavior independently.
