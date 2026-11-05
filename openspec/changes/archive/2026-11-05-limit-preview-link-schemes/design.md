## Context

`PreviewLinkRouter.route` decides what happens to every link activation in the preview. Both `decidePolicyFor` and `createWebViewWith` call it, and `Coordinator.dispatch` acts on the answer. It returned `.openExternal` for any scheme it did not recognize, which was safe only while links came from Markdown.

What a click can reach was measured with real clicks in the preview, not read from engine documentation:

| Source | What reaches the router |
| --- | --- |
| Markdown link, reference, autolink, raw `<a>` | `http`, `https`, `mailto`, `file`. A refused scheme leaves no link in the page. |
| `flow` link | Any scheme. WebKit tidies the spelling first: `SSH:`, a leading space and a tab inside the scheme all arrive as `ssh:`. |
| Mermaid `click` or `link` on a flowchart or class node, `<a>` in a label | The Markdown schemes that survive, plus `ftp`, `ftps`, `tel`, `callto`, `sms`, `cid`, `xmpp` and `matrix`. |
| Mermaid sequence actor `link` / `links` | Nothing. The `<a>` is in the page, but the menu does not open at `strict`. |
| Mermaid gantt `click` | Nothing, at any scheme, including `https`. The click lands on the task and never reaches the navigation delegate. |
| `sequence` engine | Nothing. It draws no links, and its bundle has no `href`. |

Mermaid has two filters. Its `sanitizeUrl` blocks only `javascript`, `data` and `vbscript`, so `strict` alone does not limit schemes. Its final DOMPurify pass then removes any `href` outside DOMPurify's default list. That pass is why `ssh://` and `file:` disappear from a Mermaid link, and why the eight schemes above do not.

## Goals / Non-Goals

**Goals:**

- A link in the preview cannot open what a Markdown link cannot, whichever engine drew it.
- Everything `preview-link-handling` promises for web and mail links keeps working, and a click on a refused scheme does nothing.

**Non-Goals:**

- Changing the Markdown rule, or what an exported file does with a link.

## Decisions

### The rule lives in the router

Every activation passes through it, on every engine, however the link was drawn. Filtering each engine's output instead would mean three engines and at least three ways of drawing a link, and it would miss the next engine. It would also change exported pages, which this change has no reason to touch.

The router sees what WebKit parsed, not what the document wrote, so odd spellings need no handling of their own.

### An allowlist, not a longer denylist

The risky schemes are whatever the reader's machine has handlers for, which no list can name. Refusing by default also removes the separate checks for `javascript:` and the app's own `md2-` schemes.

### One list, shared with Markdown

The goal is stated in terms of Markdown, so `safeURLSchemes` is defined once in `HTMLSafety` and read by both. If Markdown ever gains a scheme, diagram links gain it with no second edit. The cost is making `HTMLSafety` public, with only that one member exposed.

### `tel:`, `ftp:` and the like are refused

Mermaid's list is what DOMPurify happens to keep, not a decision this app made. Allowing any of it would mean a diagram can do what a Markdown link cannot, which is the gap being closed. If one of these should work, it should be added to the Markdown rule and reach both.

### `file` stays in the list

It keeps the list identical to Markdown's, and the router's file branch runs ahead of this check anyway. A `flow` link can name `file:`, but only as a Markdown link can.

### A refused click does nothing

It cancels the navigation and shows nothing. A prompt would turn a refused link into a question the document gets to ask the reader.

### A closure for the system open

`dispatch` called `NSWorkspace` directly, so a test of a real click would have started Terminal. `onOpenWithSystem` follows `onOpenMarkdownLink`. Its default is the real call, and the test harness defaults to doing nothing, so no GUI test can reach a real handler.

### How the GUI tests avoid proving nothing

"Nothing opened" also holds for a click that missed. Each test records the clicks the page saw, then ends on an allowed link that must open. Clicks arrive in order, so once that link has opened the refused one has had its chance, and no fixed wait is needed. Mermaid fixtures use schemes it keeps, because a `ssh://` fixture has no `href` and would pass with no router at all.

## Risks / Trade-offs

- A document that relied on a diagram link to `tel:`, `ftp:` or an app's own scheme loses it, silently. Accepted: it is what the rule is for, and such a link never worked from Markdown. The text of the link still shows the reader where it pointed.
- A link in an exported HTML file or PDF is not covered. It is outside the app, and whatever opens the file decides.

## Open Questions

**Local links do not reach the router.** A real click on a `file:` link, from Markdown or a diagram, never reaches `decidePolicyFor` on an `md2-doc:` page, in a saved or an untitled document, with or without the page policy. An `https` link in the same harness does. So `file` in the list changes nothing today, and the `preview-link-handling` requirements for local Markdown files and other local files are not met on a real click. `PreviewLinkRouterTests` still passes, because it calls the router directly.

This predates this change and is not fixed here. WebKit refusing a `file:` navigation from a non-file page is the likely cause, but that is not confirmed. A fix should still go through the router, and it has a decision to make first: `.openWithSystem` would launch an `.app` or run a `.command` from one click.
