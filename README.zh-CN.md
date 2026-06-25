<div align="center">
  <h1>Markdown2</h1>
  <p><strong>Markdown Editor Too</strong> — 轻量级 macOS 原生 Markdown 编辑器 & 阅读器</p>
  <p>[中文] <a href="README.md">[English]</a></p>

  <p>
    <a href="https://github.com/stutiredboy/md2/stargazers"><img src="https://img.shields.io/github/stars/stutiredboy/md2?style=social" alt="GitHub stars"></a>
    <a href="https://github.com/stutiredboy/md2/blob/main/LICENSE"><img src="https://img.shields.io/github/license/stutiredboy/md2" alt="License"></a>
    <a href="https://github.com/stutiredboy/md2/releases"><img src="https://img.shields.io/github/v/release/stutiredboy/md2" alt="Latest release"></a>
  </p>

  <p>受 Typora 极简写作体验启发，Markdown2 在一个紧凑的原生 macOS 应用中保留了无干扰的写作流程。使用 SwiftUI + AppKit 构建。</p>
</div>

## 功能

- **三种呈现模式** — 「编写」「阅读」和「双栏」（分栏编辑 + 实时预览）。
- **原生 AppKit 文本编辑**，附带轻量 Markdown 样式。
- **实时渲染 HTML** 阅读模式。
- **大纲侧边栏**，由标题自动生成。
- **标准 macOS 打开/保存面板**，已保存文档支持防抖自动保存，关闭/退出时对未保存更改进行确认。
- **多窗口支持** — 每个文档在独立窗口中打开；从 Finder 或打开面板打开文件时，会复用尚未编辑的空白窗口。
- **字数、字符数、行数与阅读时间**状态栏。
- **丰富的 Markdown 渲染** — 标题、段落、强调、链接、图片、引用、分隔线、有序/无序/任务列表、表格、围栏代码（带语法高亮）、YAML front matter 及 `[TOC]`。
- **数学公式** — 行内 `$...$` 与独占一行的 `$$...$$` TeX 公式，使用内置 [KaTeX](https://katex.org/) 离线渲染（无需联网），并内置 mhchem 扩展以支持化学式（`\ce{...}`）。
- **图表** — `mermaid`、`flow`（[flowchart.js](https://flowchart.js.org/)）与 `sequence`（[js-sequence-diagrams](https://bramp.github.io/js-sequence-diagrams/)）代码块，使用内置引擎离线渲染（无需联网）。
- **脚注** — `[^id]` 行内引用渲染为编号上标链接；`[^id]: 文本` 定义收集至文末脚注区并附带反向链接。支持命名标签、多行定义、重复引用，未定义标签保留为原文。离线渲染，明暗模式均可阅读。
- **图片附件** — 粘贴截图会将其保存到可配置的、相对于文档的文件夹（默认 `assets/`）；拖入或粘贴图片文件则直接链接到该文件的现有位置（不复制）。可用 Pandoc 风格的 `{width=480}` / `{width=320 height=180}` 属性控制尺寸；本地图片缺失时预览中会显示明确的损坏占位提示。
- **导出为 PDF** — 将渲染后的文档导出为分页 A4 PDF，采用窄边距（~0.5"）并生成可导航的标题大纲（书签树）。
- **快捷模式切换** — 编辑模式按 `Esc` 切换到预览，预览模式 `Cmd+双击` 切回编辑，或从工具栏选择「双栏」同时查看编辑和预览。
- **双向滚动同步** — 在双栏模式下，滚动任一窗格时另一窗格自动对齐到相同内容。
- **查找与替换** — `Cmd+F` 在编辑器或预览中打开查找栏；支持上一个/下一个导航、替换单个或全部匹配项。
- **应用设置** 支持语言、默认打开模式（编辑 / 双栏 / 预览）与默认大纲可见性。
- 打包时为 `.md` 和 `.markdown` 文件声明 **Markdown 文件类型**。

完整的 Markdown/Typora 支持矩阵见 [Docs/MarkdownSupport.md](Docs/MarkdownSupport.md)。

## 安装

从 [Releases](https://github.com/stutiredboy/md2/releases) 下载最新的 `Markdown2.app`，拖入 `/Applications` 即可。

> [!NOTE]
> 从 GitHub Release 下载的 app 未经 Apple 签名和公证，macOS Gatekeeper 会阻止打开并提示"已损坏"。运行以下命令即可解除：
>
> ```sh
> xattr -cr /Applications/Markdown2.app
> ```
>
> 然后在 **系统设置 → 隐私与安全性** 中点击"仍要打开"，或直接双击打开即可。

## 从源码运行

```sh
swift run Markdown2
```

直接打开文件：

```sh
swift run Markdown2 path/to/file.md
```

构建本地 macOS app 包：

```sh
Scripts/package_app.sh
open dist/Markdown2.app
```

运行完整本地验证套件：

```sh
Scripts/functional_test.sh
```

## 测试

```sh
swift test
```

## 许可证

Markdown2 基于 [MIT License](LICENSE) 开源。
