## Why

The inline renderer swaps each protected construct for a placeholder token, `\u{E000}MD2-<n>\u{E000}`, and restores the tokens at the end. A document could type the same spelling, and the resolver accepted it as the token it spelled.

The D4 boundary (`fix-quadratic-inline-rendering`) declared this on purpose. It had two costs, both recorded in `TODOS.md` ("Authored placeholder-token output amplification"):
- **Output amplification.** Each typed spelling re-inserted the whole fragment it named, so output grew as spellings × fragment size. A 7.5 KB input could render about 1 MB.
- **A repeated link.** A typed spelling could name a fragment protected later in the same pass, such as a bare URL's anchor. `https://a.comm`, U+00A0, a typed spelling and `x.trusted.com` then rendered a second `https://a.comm` anchor that reads as `https://a.commx.trusted.com`.

The product decision (2026-11-01) is to show typed placeholder text literally.

## What Changes

- **Unforgeable tokens.** Each `InlineProtector` draws a random nonce of three private-use scalars (about 38 bits, never the sentinel), and its tokens become `\u{E000}<nonce><n>\u{E000}`. The nonce replaces the fixed `MD2-`, so tokens are one scalar shorter than before. The one grammar (`token(at:in:)`, `firstToken(in:from:limit:)`) accepts only its own protector's nonce, so it becomes an instance method. Its three outside readers, the bare-URL cut, the continuation guard and the tail renderer, already hold the protector.
- **Typed spellings are text everywhere.** The nonce never reaches the output, so a typed spelling is never a token for the resolver, the cut or the guard. That covers canonical and malformed spellings, spellings that share a sentinel, and spellings restored from an escape. It holds even inside a fragment rebuilt from authored source, such as a bare-URL anchor.
- **Declare it** in `inline-render-performance`. Both requirements that described the D4 boundary are modified.
- **Tests:**
  - Replace the D4 resolution test with `typedTokenSpellingsStayLiteral`.
  - Add `typedTokensCannotAmplifyTheOutput` and `typedTokenCannotRepeatALink`.
  - Rewrite the shared-sentinel bare-URL test so a typed spelling, now including a canonical one, sits right before a real token.
- **Remove the TODO.**

**Non-goals:**

- Private-use text other than the token spelling is unchanged: it was already literal.
- No change to how real tokens nest, restore, or feed `isLiteral` and authored-spelling recovery.
- No output-size cap. With typed tokens literal, output grows with input again, and the amplification test pins that.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `inline-render-performance`: tokens carry a per-protector nonce, so typed token spellings are literal text instead of naming fragments. This replaces the D4 boundary.

## Impact

- `Sources/MD2Core/MarkdownRenderer.swift`: `InlineProtector` (nonce, token creation, grammar methods), `protectBareAutolinks`, `visibleContinuation`, `cutTailHTML`.
- `Tests/MD2CoreTests/InlineRenderingPerformanceTests.swift`.
- `TODOS.md`.
- Output changes only for documents that type U+E000 token spellings. It is byte-identical on every repository and local Markdown document and every CommonMark/GFM example. No public API, preview, export or GUI path changes.
