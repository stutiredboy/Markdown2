# Vendored diagram engine assets

These minified builds are vendored so the Read-mode preview can render diagrams
fully offline (no CDN / network at runtime), mirroring the bundled KaTeX assets.
Update versions deliberately and re-test the preview after any bump.

| File                      | Library              | Version | Source |
| ------------------------- | -------------------- | ------- | ------ |
| `mermaid.min.js`          | Mermaid              | 10.9.8  | https://cdn.jsdelivr.net/npm/mermaid@10.9.8/dist/mermaid.min.js |
| `flowchart.min.js`        | flowchart.js         | 1.18.0  | https://raw.githubusercontent.com/adrai/flowchart.js/v1.18.0/release/flowchart.min.js |
| `sequence-diagram.min.js` | js-sequence-diagrams | 2.0.1   | https://raw.githubusercontent.com/bramp/js-sequence-diagrams/master/dist/sequence-diagram-min.js |
| `raphael.min.js`          | Raphael              | 2.3.0   | https://cdn.jsdelivr.net/npm/raphael@2.3.0/raphael.min.js |
| `underscore.min.js`       | Underscore           | 1.13.6  | https://cdn.jsdelivr.net/npm/underscore@1.13.6/underscore-umd-min.js |

## Dependency notes

- **Mermaid** is self-contained (no shared deps); load it standalone. Security
  fixes reach the 10.9 line as patch releases, so stay on its latest. 10.9.1 ran
  script from a `$$…$$` sequence label at every `securityLevel`
  (CVE-2025-54881). After a bump, run `MermaidLabelSecurityGUITests`.
- **flowchart.js** depends on **Raphael**; load `raphael.min.js` first.
- **js-sequence-diagrams** (`sequence-diagram.min.js`) depends on **Underscore**
  and **Raphael** for its `simple` theme. (Its `hand` theme additionally needs
  Snap.svg + WebFont, which are intentionally not vendored — we render with the
  `simple` theme.)
- Load order: `underscore` and `raphael` before `flowchart` and
  `sequence-diagram`; `mermaid` independently.
