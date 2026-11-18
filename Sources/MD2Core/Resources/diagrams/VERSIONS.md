# Vendored diagram engine assets

These minified builds are vendored so the Read-mode preview can render diagrams
fully offline (no CDN / network at runtime), mirroring the bundled KaTeX assets.
Update versions deliberately and re-test the preview after any bump.

| File                      | Library              | Version | Source |
| ------------------------- | -------------------- | ------- | ------ |
| `mermaid.min.js`          | Mermaid              | 10.9.8  | https://cdn.jsdelivr.net/npm/mermaid@10.9.8/dist/mermaid.min.js |
| `flowchart.min.js`        | flowchart.js         | 1.18.0  | https://raw.githubusercontent.com/adrai/flowchart.js/v1.18.0/release/flowchart.min.js |
| `sequence-diagram.min.js` | js-sequence-diagrams | 2.0.1   | https://raw.githubusercontent.com/bramp/js-sequence-diagrams/a6c252b2ed0d1e6b1d16be066f582afd2895e6c9/dist/sequence-diagram-min.js |
| `raphael.min.js`          | Raphael              | 2.3.0   | https://cdn.jsdelivr.net/npm/raphael@2.3.0/raphael.min.js |
| `underscore.min.js`       | Underscore           | 1.13.6  | https://cdn.jsdelivr.net/npm/underscore@1.13.6/underscore-umd-min.js |

See the [flowchart and sequence notices](THIRD-PARTY-NOTICES.txt) and
[Mermaid notices](MERMAID-NOTICES.txt) for upstream terms. The flowchart.js
release tag is 1.18.0. Markdown2 corrects the build banner from 1.17.1 to
1.18.0, with the rest of the file retained verbatim.

## Local modification to js-sequence-diagrams

The original 2.0.1 file has SHA-256
`0d4a8864fa0ff8c5c081c0759507453e0b0d39279db0c0b62c9d9a7e8ebebc15`.
Remove the first operand of the comma expression in
`if("undefined"!=typeof Raphael&&Raphael.registerFont({...}),"undefined"==typeof Raphael&&"undefined"==typeof Snap)`.
This removes the modified Daniel Bold glyphs. Keep the `if(` and its
remaining condition. The vendored build has SHA-256
`554f5e31d6a8e2b88f0c652cad9d7582771f77c0d0eabe2974df2efe0292ddc5`.
Keep the font out of subsequent versions while using the `simple` theme.

## Dependency notes

- **Mermaid** is self-contained (no shared deps); load it standalone. Security
  fixes reach the 10.9 line as patch releases, so stay on its latest. 10.9.1 ran
  script from a `$$…$$` sequence label at every `securityLevel`
  (CVE-2025-54881). After a bump, run `MermaidLabelSecurityGUITests`.
- **Every engine** runs under the page's Content-Security-Policy, with `eval` off.
  None needs it today. After bumping any engine, run
  `ContentSecurityPolicyGUITests`: an inlined bundle must also hold no CR and no
  `</script`, or its hash stops matching what the parser hands over.
- **flowchart.js** depends on **Raphael**; load `raphael.min.js` first.
- **js-sequence-diagrams** (`sequence-diagram.min.js`) depends on **Underscore**
  and **Raphael** for its `simple` theme. (Its `hand` theme additionally needs
  Snap.svg and WebFont or the Daniel font data, depending on the renderer.
  Markdown2 uses the `simple` theme.)
- Load order: `underscore` and `raphael` before `flowchart` and
  `sequence-diagram`; `mermaid` independently.
