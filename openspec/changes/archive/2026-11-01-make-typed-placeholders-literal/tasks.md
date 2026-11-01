## 1. Protector

- [x] 1.1 Give `InlineProtector` a random per-instance nonce, and write it into every token.
- [x] 1.2 Make `token(at:in:)` and `firstToken(in:from:limit:)` instance methods that accept only that nonce, and switch the bare-URL cut, the continuation guard and `cutTailHTML` to them.

## 2. Tests

- [x] 2.1 Replace `sharedSentinelResolvesLeftmostToken` with `typedTokenSpellingsStayLiteral`; add `typedTokensCannotAmplifyTheOutput` and `typedTokenCannotRepeatALink`; rewrite the bare-URL test as `structuralTokenAfterTypedSpellingEndsBareURL`, including the canonical spelling.
- [x] 2.2 Confirm the new tests fail against `main`.

## 3. Verification

- [x] 3.1 Run `openspec validate make-typed-placeholders-literal --strict`.
- [x] 3.2 Run the full non-GUI suite in CI's three steps.
- [x] 3.3 Compare `swiftc -O` probes with and without this change (results in `design.md`).
- [x] 3.4 Compare timings with `Scripts/benchmark_inline.sh`.

## 4. Docs

- [x] 4.1 Remove the amplification item from `TODOS.md`.
