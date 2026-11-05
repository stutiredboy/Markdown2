# Mermaid 标签安全调查（2026-11-04）

**结论：** F01 的边界在 Mermaid 图表里有缺口。修复前，文档里的图表源码能运行脚本，读取并发出文档内容。本次把 Mermaid 升级到 10.9.8，并改用 `securityLevel: "strict"`，Mermaid 路径上的脚本执行已全部关闭。标签和图表 CSS 仍能加载远程资源，这与 Markdown 图片能力相同，保留为明确写出的限制。

> 2026-11-05 后续更新：下文“后续建议”第 2 条已完成。渲染页面现在都带 Content-Security-Policy，`flow` 的 `javascript:` 链接在预览、PDF 页面和导出文件里都不再执行，真实鼠标点击也测过，导出的页面在 Chromium 上结果相同。标签里的 `<video>`、`<audio>` 不再加载，标签和图表 CSS 里的远程图片不变。见 `WebDocumentLoading.md` 的“Page policy”。

已发布版本（含 `v0.7.2`）都带 10.9.1 和 `loose`，发布新版之前用户仍受影响。

## 脚本能否执行

在真实的 `MarkdownPreviewView` 里运行，覆盖全部图表类型、标签位置、`click` 和指令：10.9.8 上 204 个用例，10.9.1 上 125 个。

| 输入 | 10.9.1 `loose`（修复前） | 10.9.1 `strict` | 10.9.8 `loose` | 10.9.8 `strict`（修复后） |
| --- | --- | --- | --- | --- |
| `$$…$$` 序列图消息、参与者、备注带事件属性 | **显示即执行** | **显示即执行** | 不执行 | 不执行 |
| 状态图 `classDef` 注入带事件属性的元素 | **显示即执行** | 不执行 | 不执行 | 不执行 |
| 流程图、类图 `click`/`link` 的 `javascript:` 目标 | **点击后执行** | 不执行 | **点击后执行** | 不执行 |
| 其他标签里的事件属性（流程图、类图、状态图、ER、甘特图等） | 不执行 | 不执行 | 不执行 | 不执行 |
| `click A call eval(…)` | 不执行 | 不执行 | 不执行 | 不执行 |
| 指令或 front matter 降低级别、清空 `secure`、改 `dompurifyConfig` | 不适用 | 不起作用 | 不适用 | 不起作用 |

- `$$` 这一行就是 CVE-2025-54881（严重级别 critical，10.9.4 修复）。三个安全级别都拦不住，只有升级能修。
- `antiscript` 与 `strict` 的安全结果在所有用例里都相同。
- `click … call` 一直不起作用，因为应用没有调用 `bindFunctions`。

## 修复前脚本能做什么

使用 10.9.1 + `loose`，文档里放一段 `$$` 序列图标签。

| 场景 | 结果 |
| --- | --- |
| 真实 app bundle（独立 bundle ID），Read 模式打开 | 脚本运行，本地服务器收到带文档正文的请求 |
| 真实 app bundle，Write 模式打开 | 没有任何请求，切到显示预览的模式才会触发 |
| 真实预览 | 通过 `Image` 和 `fetch` 发出文档正文 |
| PDF 导出（真实 `PDFExporter`） | 导出过程中运行，同样发出正文 |
| 导出的 HTML | WebKit 和无头 Chromium 打开都会运行并发出正文 |
| 原生桥接 | `toggleTask`、`enterEdit`、`revealSourceLine`、`selectionChange` 都够不到，只有 `anchorChange` 可达 |
| 脚本里的 `a.click()`（无用户手势） | 外部 URL 以 `linkActivated` 进入导航决策 |
| 脚本发起的 `file:` 导航 | 没有进入导航决策 |

`Coordinator` 收到 `linkActivated` 会把外部 URL 交给 `NSWorkspace.open`，所以显示文档就可能拉起外部 URL 处理程序。这一条是根据观测到的类型和路由代码得出的：测试里用监听拦下了导航，没有真的打开任何东西。

默认模式是 Write，所以默认设置下脚本要等用户打开预览或导出才运行，不需要点击图表本身。

## 远程资源

修复后（10.9.8 + `strict`）下面这些仍会发起请求：

- 标签元素：`<img>`、`srcset`、`<picture>`、`<video>`、`<audio>`、`<input type=image>`、SVG `<image>`、`feImage`、`<table background>`
- CSS：内联 `style` 的 `url()`、状态图 `classDef`、`themeCSS`、`fontFamily`

`feImage`、`<table background>` 和 CSS 路径只在 10.9.8 上测过，其余标签元素在 10.9.1 的三个级别下结果相同。

对照组：普通 Markdown 图片和原始 HTML `<img>` 也会发起同样的请求。真实 app 里，标签图片和 Markdown 图片都到达了本地服务器。标签里的相对路径图片在预览中加载不到，`file:` 地址会被净化器移除。

所以预览从标签加载远程图片是真实的网络请求，但不是新能力。脚本关闭后，请求只能带作者写死的内容。

## `strict` 对合法图表的影响

对比 51 个合法图表，10.9.1 + `loose` 对 10.9.8 + `strict`：48 个完全一致。

| 差异 | 影响 |
| --- | --- |
| gitGraph 的 commit ID | 本来就是随机值，不是回归 |
| `click` 的 `_blank` 目标丢失 | 预览里外链本来就交给默认浏览器；导出的 HTML 里会在当前标签页打开 |
| 序列图参与者的 `link`/`links` 菜单打不开 | 真实的功能损失，菜单靠内联 `onclick` 打开 |

换行、`wrapLongLabels` 的中英文换行、行内格式、`$$` 公式、`http(s)` 链接都不变。`sandbox` 不可用：51 个图表没有一个输出内联 SVG（45 个 iframe，6 个渲染失败）。

## 为什么不加标签白名单

`dompurifyConfig` 白名单能去掉标签里的 `<img>`，但关不住上面的 CSS 路径。要关住就得去掉 `style`，这会破坏常见的 `<span style='color:red'>`，而 `classDef` 根本没有配置开关。结果是用户失去 `<img>`，限制却还在。

## 修复的两部分缺一不可

用 `MermaidLabelSecurityGUITests` 分别还原：

| 状态 | 失败数 | 还开着的问题 |
| --- | --- | --- |
| 都不改（10.9.1 + `loose`） | 65 | 全部 |
| 只升级（10.9.8 + `loose`） | 45 | `javascript:` 目标、内联 `onclick` |
| 只改级别（10.9.1 + `strict`） | 9 | `$$` 序列图标签 |
| 两者都改 | 0 | |

## 未覆盖的部分

- `flow` 引擎的 `javascript:` 链接在点击后仍会执行，任何 Mermaid 级别都管不到它。
- 点击测试用的是合成事件，不是真实鼠标点击。
- 没有用 Safari 打开导出的 HTML，WebKit 用的是 `WKWebView`。
- 公告提到的 CSS `:has()` 读取页面属性没有测试。
- 这次早期对 CSS 路径的“没有请求”结果无效：`wrapLongLabels` 把长 `url(...)` 拆开了。上面的 CSS 结论来自避开换行后的重测。

## 后续建议

1. **尽快发布新版。** 已发布版本在这之前仍受影响。
2. **给渲染页面加 Content-Security-Policy。** 不依赖任何引擎，能挡住 `flow` 的 `javascript:` 链接，也是未来净化器漏洞的第二道防线。
3. **决定是否需要真正的离线保证。** 如果要，应在页面层统一拦截远程加载，并同时覆盖 Markdown 图片，这是产品决定。
4. **修 `wrapLongLabels`。** 它会改写 `style` 指令里的长 `url(...)`，与 `diagram-rendering` 规格不符。
