# Third-party software and data

Markdown2 has no external Swift package dependencies. The built app uses the
system's Swift and macOS frameworks and carries the files below in the
`MD2_MD2Core.bundle` resource bundle. The files needed by offline rendering
come from the checkout.

## App resources

Paths are relative to [`Sources/MD2Core/Resources`](../Sources/MD2Core/Resources).

| Files and version | Upstream source | License and attribution |
| --- | --- | --- |
| `katex/katex.min.js`, KaTeX 0.16.11 | [npm release, `dist/katex.min.js`](https://registry.npmjs.org/katex/-/katex-0.16.11.tgz) | MIT, Khan Academy and contributors |
| `katex/mhchem.min.js`, KaTeX 0.16.11's adaptation of mhchem 3.3.0 | [npm release, `dist/contrib/mhchem.min.js`](https://registry.npmjs.org/katex/-/katex-0.16.11.tgz) and [annotated source](https://github.com/KaTeX/KaTeX/blob/v0.16.11/contrib/mhchem/mhchem.js) | MIT for the KaTeX adaptation, Apache-2.0 for the MathJax Consortium and Martin Hensel code it adapts |
| `katex/katex.bundle.css`, KaTeX 0.16.11 stylesheet with 20 embedded WOFF2 files (font version 1.1) | [npm release, `dist/katex.min.css` and `dist/fonts/*.woff2`](https://registry.npmjs.org/katex/-/katex-0.16.11.tgz) | MIT for CSS, SIL OFL 1.1 for fonts by Design Science and Khan Academy. Markdown2 embeds the unchanged WOFF2 bytes as data URIs and drops the WOFF and TTF fallbacks. |
| `diagrams/mermaid.min.js`, Mermaid 10.9.8 | [npm release, `dist/mermaid.min.js`](https://registry.npmjs.org/mermaid/-/mermaid-10.9.8.tgz) | MIT, Knut Sveidqvist. The standalone build includes dependencies, including DOMPurify 3.4.2, ELK.js 0.9.2, and KaTeX 0.16.45. See the [Mermaid notices](../Sources/MD2Core/Resources/diagrams/MERMAID-NOTICES.txt) and the [release's dependency lockfile](https://github.com/mermaid-js/mermaid/blob/v10.9.8/pnpm-lock.yaml). |
| `diagrams/flowchart.min.js`, flowchart.js 1.18.0 | [Pinned release file](https://github.com/adrai/flowchart.js/blob/v1.18.0/release/flowchart.min.js) | MIT, Adriano Raiano. Markdown2 corrects the embedded version banner to 1.18.0, matching the release tag. |
| `diagrams/sequence-diagram.min.js`, js-sequence-diagrams 2.0.1 | [Pinned upstream file](https://github.com/bramp/js-sequence-diagrams/blob/a6c252b2ed0d1e6b1d16be066f582afd2895e6c9/dist/sequence-diagram-min.js) | BSD-2-Clause, Andrew Brampton. Markdown2 removes the modified Daniel Bold glyph data, which the supported `simple` theme does not use. See the [diagram version notes](../Sources/MD2Core/Resources/diagrams/VERSIONS.md). |
| `diagrams/raphael.min.js`, Raphaël 2.3.0 with Eve 0.5.0 | [npm release, `raphael.min.js`](https://registry.npmjs.org/raphael/-/raphael-2.3.0.tgz) and [Eve source package](https://registry.npmjs.org/eve-raphael/-/eve-raphael-0.5.0.tgz) | MIT for Raphaël, Dmitry Baranovskiy. Apache-2.0 for Eve, Adobe Systems Incorporated. |
| `diagrams/underscore.min.js`, Underscore 1.13.6 | [npm release, `underscore-umd-min.js`](https://registry.npmjs.org/underscore/-/underscore-1.13.6.tgz) | MIT, Jeremy Ashkenas, Julian Gonggrijp, and DocumentCloud and Investigative Reporters & Editors |
| `html-entities.json`, 2,125 named HTML references | Extracted from [CPython's `html.entities.html5`](https://github.com/python/cpython/blob/v3.10.22/Lib/html/entities.py), based on the [WHATWG HTML Living Standard](https://html.spec.whatwg.org/entities.json). The original Python patch version was unrecorded. CPython 3.10.22 reproduces the mapping by retaining semicolon-terminated keys and stripping their semicolons. | PSF License 2.0 and WHATWG's BSD-3-Clause terms for data incorporated into source |

The app and DMG ship the full [math notices](../Sources/MD2Core/Resources/katex/THIRD-PARTY-NOTICES.txt),
[flowchart and sequence notices](../Sources/MD2Core/Resources/diagrams/THIRD-PARTY-NOTICES.txt),
[Mermaid notices](../Sources/MD2Core/Resources/diagrams/MERMAID-NOTICES.txt), and
[entity data notice](../Sources/MD2Core/Resources/html-entities.LICENSE.txt).
Standalone HTML embeds the math notices and carries the diagram notices when it
embeds a diagram engine. View the HTML source to read them.

## Test fixtures and tools

- The CommonMark 0.31.2 and GFM 0.29 example corpora are CC BY-SA 4.0.
  Their exact sources, attribution, and the GFM extraction changes are in the
  [test corpus README](../Tests/MD2CoreTests/Corpus/README.md).
- Build, test and release tools are listed in the
  [contributor guide](../CONTRIBUTING.md) and
  [verification workflow](../.github/workflows/verify.yml). GitHub Actions
  dependencies use the references in the [workflow files](../.github/workflows).
- [Pandoc](https://github.com/jgm/pandoc) is a separately installed executable
  that the DOCX/EPUB conversion backend can use. Its version follows
  the user's installation and its [GPL-2.0-or-later license](https://github.com/jgm/pandoc/blob/main/COPYRIGHT)
  accompanies Pandoc. The normal build, tests, preview, and PDF/HTML export
  need no Pandoc installation.

## Update alongside the asset

1. Pin the upstream release or commit and record which published file was
   copied. Describe any local changes and cross-check the bytes against upstream.
2. Review the version's upstream license files, in-bundle attributions and
   transitive code and fonts. Update this inventory and the notices beside the
   assets together. For diagram updates, also follow the
   [diagram version notes](../Sources/MD2Core/Resources/diagrams/VERSIONS.md).
3. Run the [verification gates](../CONTRIBUTING.md) and check that the
   packaged app and any standalone HTML that embeds the asset carry the
   corresponding notices.
