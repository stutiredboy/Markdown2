## Why

The `unify-token-grammar` differential run (2026-10-31) found two bare-URL bugs that reproduce on `main` with ordinary text. They were recorded in `TODOS.md` ("Pre-existing bare-URL bugs found by the token-grammar differential"):

- **A trailing entity after a bare URL was double-escaped.** `see https://a.com&amp; next` rendered `</a>&amp;amp; next`, so the reader saw `&amp;` instead of `&`. `protectBareAutolinks` moves the authored entity spelling out of the URL, then escapes that spelling as if it were plain text.
- **A combining mark right after the scheme made the URL a `mailto:` link.** `http://` + U+0301 + `x.com` rendered `<a href="mailto:http://…x.com">`. The scheme check used `Character`-level `hasPrefix`. A mark fused into the scheme's last character fails it, so the candidate fell through to the email branch.

Fixing them exposed two more problems of the same kind:

- **A `<` joined by a combining mark did not end the URL.** The `<` cut used `Character`-level `firstIndex(of:)`, so the anchor swallowed the `<` and the text after it.
- **The continuation guard would have misread the fixed entity.** Once a trailing entity renders as an entity, the guard must read it that way. It read the trailing text by its spelling, so `` https://evil.com&period;`trusted` `` would show `https://evil.com.trusted` with an anchor to `evil.com`.

## What Changes

- **Text cut from the URL tail renders as it would outside a URL.** Trailing punctuation, a trailing entity, and everything from `<` on are emitted as the candidate's own escaped text and literal tokens. They are no longer re-escaped from their authored spelling.
  - An entity stays an entity: `&amp;` shows `&`, and `&period;` shows `.`.
  - An entity name HTML does not define stays text (`&amp;hl;`). That is what the GFM reference renders, so GFM example 626 keeps its reference match.
  - When the cut falls inside a backslash escape (`\&amp;`), the tail keeps the old escaped spelling. That is what the author wrote.
- **The scheme, `www.` and `<` checks compare Unicode scalars,** so a combining mark cannot change how a candidate is classified or where it ends. A candidate whose host starts with a combining mark stays text, because a host label cannot start with a mark.
- **The continuation guard reads the cut text as it renders.** A trailing entity is decoded, as entities after the URL already are: `&period;` is a dot, and `&nbsp;` is a space that ends the authority. The guard fails closed when the named-entity table is missing.
- **`HTMLSafety.decodeEntities` compiles its pattern once** instead of on every call. Bare-URL linking calls it several times per URL, and the new tail check calls it once more.
- **Declare the behavior** in `cjk-autolink-boundaries`, in the `gfm-autolinks` matrix entry and in `Docs/MarkdownSupport.md`.
- **Add tests** that fail on `main`, and remove the TODO.

**Non-goals:**

- What the trailing rule removes is unchanged: ASCII punctuation, excess `)`, `&[A-Za-z0-9]+;`, and everything from `<`.
- A backslash escape left at the end of a URL (`https://a.com/x\.` links `https://a.com/x\`) is pre-existing and unchanged.
- The source-line attribute bug after a leading combining mark has its own TODO and is unchanged.
- Authored placeholder tokens are unchanged. The differential found that one can duplicate a bare-URL anchor next to arbitrary text. That reproduces on `main` with a typed no-break space, and it is recorded in the authored-token TODO.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `cjk-autolink-boundaries`: text cut from a bare URL renders as it would outside the URL, and the continuation guard reads it that way. The scheme and `<` checks compare Unicode scalars.

## Impact

- `Sources/MD2Core/MarkdownRenderer.swift`: `protectBareAutolinks`, plus two helpers (`cutTailHTML`, `isUndefinedNamedReference`).
- `Sources/MD2Core/HTMLSafety.swift`: `decodeEntities` keeps its pattern in a static.
- `Tests/MD2CoreTests/CommonSyntaxTests.swift`: new tests and spoof rows; the trailing-entity row of `bareLinks` now expects `&copy;`.
- `Tests/MD2CoreTests/Matrix/compatibility-matrix.json`, `Docs/CompatibilityMatrix.md` (generated) and `Docs/MarkdownSupport.md`.
- `TODOS.md`: the bare-URL item is removed, and a note is added to the authored-token item.
- Output changes only for bare URLs with cut-off text that contains an entity, a combining mark after the scheme or after `<`, or a trailing entity the guard now reads decoded. Output is byte-identical on every repository and local Markdown document and every CommonMark/GFM example. No public API, dependency, preview JavaScript/CSS, PDF/print, HTML-export or GUI-gated path changes.
