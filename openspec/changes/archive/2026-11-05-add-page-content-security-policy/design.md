## Context

A rendered page has several boundaries, and each covers only part of it. `HTMLSafety` covers author HTML. Mermaid covers its own source at `securityLevel: "strict"`. Nothing covered `flow`, whose `javascript:` link ran on click, and every boundary was one bug away from letting script into a page that can reach `NSWorkspace` through a scripted click.

A Content-Security-Policy does not depend on any engine. It has to fit three pages: the preview and the PDF page are served from `md2-doc:` with engines on `md2-app:`, and an exported file is a `file:` page with everything inlined. The app also works in these pages from outside, through `WKUserScript`s and `evaluateJavaScript`.

## Goals / Non-Goals

**Goals:**

- Document content cannot run script on any engine, on any of the three pages, even when its markup reaches the page.
- Everything a page does today keeps working: math, every diagram type, the app's scripts, live updates, PDF overrides, images.

**Non-Goals:**

- Stopping remote image loads, or closing the CSS paths that the Mermaid change listed as a limit.

## Decisions

### A `<meta>` tag, not a response header

An exported file has no response. A header would need a second mechanism for that page, and the page that is hardest to test would be the one left out. The `<meta>` sits ahead of every stylesheet, script and document content, and a policy only covers what the parser reaches after it. Nothing a document writes can come first, and a second policy in the body could only tighten this one.

### Hashes, not a nonce

`MarkdownRenderer` is pure, and the preview decides whether a page changed by comparing its HTML. A random nonce would make every render differ and would put randomness into exported files. A hash needs neither, and a script that matches one is by definition one of the page's own.

The cost is that a hash covers every byte between the tags, so a script and its hash must never drift. `InlineScript` builds both from one place. The two things that could change the bytes were checked. HTML parsing rewrites CR and ends a script at `</script`, and no bundled engine holds either; a plain test pins that. `WebDocumentLoader`'s rewriters and `SelfContainedHTMLBuilder` run over pages with hashed scripts in them, but the loader only touches `<img>` and `<a>` tags that hold a resolvable local path, and the builder only works inside `<main>`. Macros are author data inside a hashed script, and they cannot leave it: they are JSON with `<` and `>` escaped.

### Exact URLs for served engines, not the `md2-app:` scheme

Each script contributes one source: its hash when inlined, its URL when served. Allowing the whole scheme would let injected markup load any bundled engine into a page that does not use it. Exact URLs are safe on the live path because `requiresNewEngine` already forces a full load when a body needs an engine the page lacks, and that page has its own policy.

### No `'unsafe-eval'`

Tested, not assumed. The bundles were expected to need it, but only Underscore has a real `new Function`, inside `_.template`, which nothing calls. Mermaid's two `Function("return this")` and Underscore's one sit behind a check for `self`, so they are never reached. KaTeX has none.

On a page where `eval` and `new Function` both throw `EvalError`, all 19 test diagrams and all the math rendered with no policy violation, on all three surfaces. The rendered `<main>` was identical to the same page with no policy, apart from Raphael's random marker IDs.

### `'unsafe-inline'` for styles only

Mermaid writes a `<style>` into each diagram, KaTeX and the engines set `style` attributes, and the app's user scripts add `<style>` elements. None of this can be hashed, so CSS stays as open as it was. A `url()` in an inline `style`, a state `classDef` or `themeCSS` made the same request with and without the policy.

### `default-src 'none'`, with images open

Raw HTML allows only formatting tags, so nothing Markdown produces needs anything else. The one thing that stops working is media in a Mermaid label: a `<video>` or `<audio>` made requests without the policy and makes none with it. `img-src` is `http: https: data:` plus one local source: `md2-local-image:` on app pages, and `file:` in exports, where a reference that could not be embedded stays as written and still resolves beside the file. `base-uri` and `form-action` do not fall back to `default-src`, so they are named.

### The link router has to refuse script URLs itself

A `flow` link can ask for a new window with `[blank]`. WebKit asks the navigation delegate about a new-window request first and applies the policy after, so with the policy in place `decidePolicyFor` still receives `javascript:window.pwned=1`, with no target frame. The router sent that to `.openExternal`, which reaches `NSWorkspace`. No app handles `javascript:` on a stock system, so nothing visible happened, but any app could register for it. The router now ignores the scheme.

A plain click needs no such rule: WebKit never asks the delegate about one, and the policy stops it.

### The broken-image listener moves to document start

The policy refuses a missing local image while the page is parsing, and the `error` event fires before document end. This is not new in kind. A missing image used to fail asynchronously in the scheme handler, and the same page gave 0, 1 or 2 placeholders from run to run, because the engine scripts after `<main>` hold up document end. The policy made a frequent miss a certain one.

Adding `'self'` to `img-src` was tested and does not help: the failure still beats a listener at document end. Sweeping for failed images at document end would need a guess about `naturalWidth`. A listener at document start hears every failure, so that is what the preview now uses. The placeholder's stylesheet stays at document end, because `document.head` does not exist at document start.

### Keep proving each layer on its own

With a policy in the page, `window.pwned` stays unset whether or not a sanitizer works, so `MermaidLabelSecurityGUITests` and `PreviewSecurityGUITests` would have passed without testing anything. They now load pages with the policy removed. `ContentSecurityPolicyGUITests` tests the policy with the sanitizers bypassed, by planting markup in a page that is already loaded.

## Risks / Trade-offs

- **A wrong hash loses a script silently.** The page shows no math or diagrams and nothing throws. → The GUI suite fails on any violation and on a page whose bootstrap never ran, and the plain suite recomputes every hash.
- **A later engine needs `eval`.** → The suite renders every diagram type on a page with `eval` off, and `VERSIONS.md` says to run it after a bump.
- **The `<a>` stays in a `flow` SVG.** It does nothing where the policy applies. A viewer that ignores `<meta>` policies would run it. → All current browsers honor them; this is what a second layer in the bootstrap would add, and it was left out to keep one boundary that does not depend on the engine.

## Verification

- Breaking each of 15 parts of the policy and the two fixes, one at a time, failed at least one test. Most fail in `ContentSecurityPolicyGUITests` and `PageContentSecurityPolicyTests` both. Using the whole `md2-app:` scheme is caught only by the plain suite, and dropping `md2-local-image:` only by the plain suite and the preview's image suites.
- Without the policy, the `flow` link runs from a real trusted mouse click and from a scripted one on every surface, and all 12 injected markup paths run. With it, none do.
- The same exported page in Chromium 156, served from localhost because the test tool refuses `file:`: every hash matched, math, diagrams and fonts loaded, `eval` was off, and a real click on the link ran nothing. On the same page without the policy, that click ran the script.
- The exported PDF holds no link annotations at all, so no `javascript:` link reaches it.
