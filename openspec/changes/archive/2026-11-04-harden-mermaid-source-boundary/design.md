## Context

Author HTML goes through `HTMLSafety.sanitizeTag`, which keeps formatting tags and inert attributes and drops the rest. Diagram source does not: it reaches the page as escaped text and becomes live markup only when Mermaid renders it. Mermaid's own sanitizing is therefore the only boundary for that source, and the app decides how strong it is through `mermaid.initialize`.

The bundled engine's source shows why the level alone was not enough. Each label is sanitized on its way in at every level, but only a non-`loose` level sanitizes the finished SVG. A label that skips the per-label step therefore lands in the page intact at `loose`. In 10.9.1 the `$$…$$` measuring step in sequence diagrams also writes unsanitized text into a live element during rendering, before any final pass, so no level stops it.

## Decisions

### Change both the level and the bundle

Each change closes something the other leaves open. With only one of them applied, `MermaidLabelSecurityGUITests` fails:

| Applied | Failures | Still open |
| --- | --- | --- |
| Neither (10.9.1, `loose`) | 65 | All of the below |
| 10.9.8 only (`loose`) | 45 | `javascript:` targets, inline `onclick` |
| `strict` only (10.9.1) | 9 | `$$…$$` sequence labels |
| Both | 0 | |

### `strict`, not `antiscript` or `sandbox`

`strict` and `antiscript` gave the same security result in every case, and no rendering difference beyond the test URL's own length and the layout of labels holding a broken image. `strict` is the engine's default and the level most of its users run, so it is the better-exercised path.

`sandbox` is not usable here. Across 51 legitimate diagrams it produced 45 iframes, 6 render errors, and no inline SVG or link, and PDF sizing and the settle checks work on inline SVG.

### 10.9.8, not Mermaid 11

10.9.4 is the first release with the sequence-label fix. 10.9.8 also has the later fixes for `classDef` HTML and CSS injection, config CSS injection, prototype pollution, and two infinite loops, and it stays on the same line. Across 51 legitimate diagrams, 10.9.8 at `strict` matched 10.9.1 at `loose` in 48. The other three are a random Git commit ID, the dropped `target`, and the actor menu, which is the behavior change stated in the proposal.

### No tag allowlist on labels

An allowlist through `dompurifyConfig` would be the natural next step: it can drop `<img>`, media and SVG images from labels. It was tested and left out, because at `strict` on 10.9.8 these also reached the network:

- an inline `style` with `url()` in a label
- a state `classDef` with `url()`
- `themeCSS`
- a `fontFamily` that escapes its value

Closing those needs more than a tag list: removing `style` from labels breaks the common `<span style='color:red'>`, and `classDef` has no config switch at all. An allowlist would take `<img>` away from authors and still leave the limit in place.

It would also protect little. A Markdown image makes the same request, so a label image gives a document no new capability, and with script gone the request carries only what the author wrote. If the app ever needs a real offline guarantee, it has to be one page-level policy covering Markdown images too, which is a product decision.

### What this does not cover

- **`flow` engine links.** A `javascript:` link in a `flow` block still runs on click. It is a separate engine, and this level does not reach it.
- **Script-driven navigation.** `PreviewLinkRouter` still treats a scripted `a.click()` as a link activation. WebKit reports the same navigation type, and with no script in the page nothing can issue one.
- **CSS injection.** The CSS paths above survive. No script runs through them. `:has()`-based reading of page attributes, which the advisories describe, was not tested.

A Content-Security-Policy on rendered pages would address the first two without depending on any engine.

## Risks

- **A legitimate diagram renders differently.** The 51-diagram comparison and the existing Mermaid and PDF GUI suites cover this. CI runs them on macOS 15.
- **A later engine bump reopens a path.** The new suite runs on every PR and would fail, and `VERSIONS.md` says to run it after a bump.

## Verification

- `MermaidLabelSecurityGUITests` passes, and fails against each row of the table above. Its first test shows each surface detects a handler that does run, so the passing cases mean something.
- A packaged app with its own bundle identifier opened a document holding a Markdown image, a label image and a `$$…$$` payload. In Read mode, before the change, a local server received all three, with the document's text in the script's request. After it, only the two images arrived. In Write mode, the default, neither build made any request.
