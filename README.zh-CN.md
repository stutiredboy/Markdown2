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
- **Markdown 感知编辑** — 回车续写列表、任务项和引用，空项回车退出；`Shift+Return` 按内容列软换行，`Tab` / `Shift+Tab` 调整列表层级。括号、引号和反引号自动配对，支持跳过闭合符号与成对退格。
- **源码表格编辑** — 在支持的顶层表格中，用 `Tab` / `Shift+Tab` 切换单元格，在末格按 Tab 新增一行。「格式 > 表格操作」支持增删行列，保留既有单元格文字和对齐方式，每次修改可一步撤销。
- **显式粘贴** — 在「编辑」中选择粘贴为纯文本（`Option+Shift+Cmd+V`）、将支持的 HTML/RTF 转为 Markdown，或将 TSV 粘贴为表格。普通 `Cmd+V` 保持原有行为。富文本转换不加载剪贴板中的资源；不支持的内容仅在可安全插入的位置回退为字面文字，并明确提示。详见[粘贴规则与限制](Docs/MarkdownEditing.md#explicit-paste)。
- **实时渲染 HTML** 阅读模式。
- **大纲侧边栏**，由标题自动生成，并根据编辑、预览或双栏中顶部可见的源码行跟随当前章节。
- **文档恢复与原格式保存**：跟随 Finder 改名/移动，保留编码、BOM 和换行符；停止输入 5 秒或连续编辑 30 秒后自动保存，直接启动应用时恢复窗口与未命名草稿。指定打开文件时只恢复该文件的草稿，其他恢复记录继续保留。明确关闭窗口仍确认未保存更改。详见[文件生命周期](Docs/DocumentLifecycle.md)。
- **创建副本** — 将当前编辑文本保存为原稿同目录下的新 Markdown 文件，保留编码和换行符，并可独立打开。原稿保留自己的编辑状态与撤销记录。副本共享现有附件，不复制附件文件。
- **多窗口支持** — 每个文档在独立窗口中打开；从 Finder 或打开面板打开文件时，会复用尚未编辑的空白窗口。
- **字数、字符数、行数与阅读时间**状态栏。按渲染正文统计，每个汉字计 1 字，其余文字按词计数；在编辑或预览中选中文字时显示「选区 / 全文」字数。
- **缩放与排版** — 支持 `⌘+` / `⌘=`、`⌘−` 和 `⌥⌘0`，设置中可分别选择编辑、阅读字体，调整基础字号及四档阅读宽度。预览默认宽度为 800px，显示偏好会持久保存，不影响导出。详见[阅读设置](Docs/ReadingPreferences.md)。
- **丰富的 Markdown 渲染** — 标题、段落、强调、链接、图片、引用、分隔线、有序/无序/任务列表、表格、围栏代码（带语法高亮）、YAML front matter 及 `[TOC]`。
- **数学公式** — 行内 `$...$` 与独占一行的 `$$...$$` TeX 公式，使用内置 [KaTeX](https://katex.org/) 离线渲染（无需联网），并内置 mhchem 扩展以支持化学式（`\ce{...}`）。
- **图表** — `mermaid`、`flow`（[flowchart.js](https://flowchart.js.org/)）与 `sequence`（[js-sequence-diagrams](https://bramp.github.io/js-sequence-diagrams/)）代码块，使用内置引擎离线渲染（无需联网）。
- **脚注** — `[^id]` 行内引用渲染为编号上标链接；`[^id]: 文本` 定义收集至文末脚注区并附带反向链接。支持命名标签、多行定义、重复引用，未定义标签保留为原文。离线渲染，明暗模式均可阅读。
- **可携带的图片附件** — 粘贴截图、拖入或粘贴图片文件，默认复制到相对于文档的附件文件夹（默认 `assets/`）；设置中也可选择链接图片原位置。“收集本地图片”会收集可安全识别的 Markdown 图片引用，并报告缺失、无效和不支持的资源，详见[收集范围](Docs/PortableAttachments.md)。可用 Pandoc 风格的 `{width=480}` / `{width=320 height=180}` 属性控制尺寸；本地图片缺失时预览中会显示明确的损坏占位提示。
- **导出与打印** — 将渲染后的文档导出为分页 PDF（含可导航的标题大纲/书签树），或直接打印。可配置的**导出预设**控制页面大小（A4 / Letter / Legal）、方向（纵向 / 横向）、页边距（正常 / 窄 / 宽 / 无，或自定义），以及可选的页码与页眉/页脚文本（支持 `{title}`、`{date}`、`{page}`、`{pageCount}` 占位符）——默认仍为 A4 纵向窄边距，保持原有输出不变。导出与打印结果中的图表与预览一致。
- **导出为 HTML** — 导出为单个 `.html` 文件，样式、数学/图表引擎与本地图片全部内联，无需附带文件。远程 `http(s)` 图片保留为链接，需要联网才能显示。导出后，Markdown2 会列出所有未嵌入的 Markdown 或 HTML 图片。图表源码加载的图片既不会嵌入，也不会列出。DOCX/EPUB 转换后端已为后续版本保留，但当前不会在菜单中暴露这些命令。
- **快捷模式切换** — 编辑模式按 `Esc` 切换到预览，预览模式 `Cmd+双击` 切回编辑，或从工具栏选择「双栏」同时查看编辑和预览。
- **双向滚动同步** — 在双栏模式下，滚动任一窗格时另一窗格自动对齐到相同内容。
- **精确查找与替换** — 编辑器和预览支持区分大小写、整词查找；源码替换可限定在锁定的选区内，显示范围与数量，全部替换可一次撤销。关闭查找栏后，`Cmd+G` / `Shift+Cmd+G` 继续上次查询。详见[匹配与选区规则](Docs/MarkdownEditing.md)。
- **行号** — 可选择在编辑模式、预览模式或两者中显示源码行号。编辑模式在正文左侧的行号栏中标注每一行（软换行的行只标注一次）；预览模式在每个渲染块以及跨多行的列表项左侧显示其起始源码行号，因此阅读时看到的行号就是在编辑器中要打开的行。点击行号即可选中该行：在编辑模式的行号栏中点击（按住 Shift 点击或拖动可选中多行）；在预览中点击，双栏模式会在旁边的编辑器中选中该行，预览模式会切换到编辑器并选中该行。两种范围都可在工具栏或设置中开关；行号不会出现在导出的 PDF、打印或 HTML 中。
- **应用设置** 支持语言、默认打开模式（编辑 / 双栏 / 预览）、默认大纲可见性、行号（编辑与预览），以及导出预设（页面大小、方向、页边距、页码、页眉/页脚）。
- 打包时为 `.md` 和 `.markdown` 文件声明 **Markdown 文件类型**。

完整的 Markdown/Typora 支持矩阵见 [Docs/MarkdownSupport.md](Docs/MarkdownSupport.md)。

「格式」「段落」菜单提供 `Cmd+B` 粗体、`Cmd+I` 斜体、`Cmd+K` 链接（可读取剪贴板 URL）、`Option+Cmd+1–6` 标题、`Cmd+0` 正文、`Option+Cmd+C` 代码块和 `Option+Cmd+T` 表格。`Cmd+1/2/3` 保留用于模式切换。行为说明与回归测试见 [Markdown 感知编辑](Docs/MarkdownEditing.md)。

## 安装

需要 macOS 15 或更高版本。

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

构建本地 macOS app 包（仅生成 `dist`，不安装、不改变默认打开程序）：

```sh
Scripts/package_app.sh
open dist/Markdown2.app
```

默认包使用独立的 `dev.codex.md2.development` 身份，设置和恢复草稿与正式版分开。`swift run` 继续使用自己的 debug 身份。需要正式版身份时使用 `--release`；安装和设置默认程序均需明确指定：

```sh
# 安装开发版到指定位置，保留正式版
Scripts/package_app.sh --install '/Applications/Markdown2 Development.app'
# 明确替换正式安装，并设为默认 Markdown 编辑器
Scripts/package_app.sh --release --install /Applications/Markdown2.app --set-default
```

`--set-default` 必须与 `--install` 一起使用；安装目录的父目录须已存在。旧 `MARKDOWN2_INSTALL_APP` 环境变量不会触发安装。CI 仅使用 `--release` 打包，拒绝安装参数。签名仍沿用临时签名，本次不要求开发者账号或公证。

运行本地验证（默认测试、独立性能检查、工作流测试及开发包校验）：

```sh
Scripts/functional_test.sh
# 另启用原生窗口/WebKit 测试，需要可用的桌面会话及相应辅助功能权限
Scripts/functional_test.sh --gui
```

GUI 跳过项会按现有清单检查，跳过不计为实际通过。脚本不再终止日常使用的应用、改写应用偏好或要求修改系统默认编辑器。

## 测试

```sh
swift test
```

用 release 构建测量行内渲染的扩展性工作负载，或与旧版本对比，见 [Docs/Benchmarks/inline](Docs/Benchmarks/inline/README.md)：

```sh
bash Scripts/benchmark_inline.sh
```

## 许可证

Markdown2 基于 [MIT License](LICENSE) 开源。
