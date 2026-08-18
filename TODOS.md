# TODOS

Tracked work considered and explicitly deferred from in-flight changes. Each item carries its reasoning so a future picker-upper has the context.

## Headless-GUI CI lane for `MD2_RUN_GUI_TESTS`

**What:** Add a macOS GUI-capable CI runner that runs `MD2_RUN_GUI_TESTS=1 swift test` on every PR.

**Why:** All regression guards for the PDF/print Mermaid fix (and the existing offscreen/E2E tests in `Tests/MD2CoreTests/`) are GUI-gated and skipped by plain `swift test`. CI never runs them, so a silent regression — dark/inverted PDFs, disappearing Mermaid diagrams, clipped flow/sequence/KaTeX media — lands green unless a human ran the GUI suite. The fixes fail SILENTLY (no error thrown), which is exactly the failure class CI-blindness makes dangerous.

**Current state (the in-scope guard shipped with the fix):** A pre-ship checklist note in CLAUDE.md's testing section plus load-bearing comments at the two silent-failure lines in `PDFExporter.swift` (the `printStyleScript` selector and `hostWindow.appearance = .aqua`). These rely on humans following the note.

**Pros:** Every PR automatically runs the silent-failure guards; no reliance on human memory.
**Cons / cost:** Real macOS CI infra — a self-hosted runner with a window-server session, or a macOS-cloud runner; non-trivial setup and maintenance. (human: ~1-2 days / CC: ~30min)

**Depends on:** nothing blocking; pure CI infrastructure work, independent of any code fix.

**Start here:** pick a runner strategy (self-hosted mac with a `loginwindow`/`launchctl` GUI session vs. macOS-cloud), wire `MD2_RUN_GUI_TESTS=1` into the test step, and gate merge on it.
