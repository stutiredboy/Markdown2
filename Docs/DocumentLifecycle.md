# 文件生命周期与恢复

本轮采用增量方案，继续由 AppKit 创建窗口、SwiftUI 承载内容。文件读写仍由 `DocumentStore` 管理；未迁移到 `NSDocument`，也不提供系统版本浏览。

## 文件身份

- 打开、保存及外部重载后记录 URL bookmark，并在进程内保留文件描述符以确认原文件身份。监听事件处理和每次保存之前都先解析文件身份，再检查磁盘内容指纹。
- Finder 改名或移动后更新标题、represented URL、相对图片/链接的基础目录及监听目标。旧路径出现另一份文件时，优先跟随原文件的身份。
- 原子替换仍按原位置的新内容处理；外部内容冲突继续要求用户选择。
- 文件真正删除或进入废纸篓时保留内存与恢复副本，暂停自动保存。手动保存重新选择位置，取消不会重建旧文件。

## 编码与换行

BOM 明确的 UTF-8、UTF-16 LE/BE、UTF-32 LE/BE 优先；无 BOM 时依次严格尝试 UTF-8、GBK、GB18030。每种格式都要求解码后可无损编码回原字节。纯 ASCII 无法区分 UTF-8 和 GBK，按 UTF-8 处理。

保存沿用编码、BOM 及 LF/CRLF/CR。统一换行格式的文件中新输入的换行也使用原格式；混合换行保留编辑缓冲区中的每一种换行，不主动统一。状态栏显示编码、BOM 和换行格式。

GBK 等格式遇到无法表示的字符时，原文件不变。自动保存只提示一次是否转为 UTF-8，取消后继续保留编辑和恢复副本；手动保存可以再次选择转换。恢复文件的 JSON 使用 Unicode，因此能保留原文件编码无法表示的内容。

## 保存与恢复

- 已命名文档：停止输入 5 秒后保存；连续输入最多等待 30 秒（从第一笔未保存编辑开始计时）。
- 所有窗口：编辑后的恢复快照按 1 秒节流写入，持续输入不会延后。打开、保存、改名、外部重载及退出时也会写快照。
- 路径：`~/Library/Application Support/<当前 App 的 bundle identifier>/Document Recovery/`，每个窗口一个 UUID 命名的 JSON，原子替换，目录权限 0700、文件权限 0600。
- 快照包含完整文本、原文件 URL/bookmark、格式、上次读写指纹、脏标记及窗口位置大小；直接启动应用时恢复这些状态。撤销历史、光标、阅读/编辑模式和原生标签组不跨进程恢复。
- 退出时立即写回可以安全保存的已命名文档，并保留窗口和未命名草稿，不要求先选择文件名；冲突或待确认编码的内容留在恢复副本中。快照写入失败时提示并取消退出；明确关闭窗口仍询问保存/丢弃/取消，完成关闭时删除对应快照并取消待执行的保存任务。
- 恢复脏文档时，若磁盘已改变，保留草稿并提示冲突；干净文档读取磁盘最新版本。丢失的文件保留恢复文本。损坏或不支持的恢复记录不会删除，其他有效记录仍可恢复。
- 从 Finder 或启动参数指定打开文件时，只打开指定文件，不附带恢复其他文件或未命名窗口。指定文件有恢复记录时使用最新的一份，保留其未保存编辑；其他记录原样留在磁盘，直接启动应用时仍可恢复。在同一进程内稍后打开被延后恢复的文件，也会取回它的草稿并跟随改名。
- 重复打开已打开的文件会选中对应窗口，激活应用及点击 Dock 图标保留当前可见文档的选择。
- 异常终止能恢复最后成功写入的快照；崩溃前尚未到达 1 秒写入点的最新输入可能未落盘。

## 验证

```sh
swift test
MD2_RUN_GUI_TESTS=1 swift test --filter UndoHistoryGUITests --filter SettingsWindowPresentationGUITests
```

`DocumentLifecycleTests.swift` 覆盖真实文件改名/移动、监听前立即保存、旧路径复用、自动保存期限、格式字节往返、GBK 不可编码字符、删除、恢复冲突和关闭时取消写入。窗口测试用独立 bundle identifier 启动真实 App，验证正常退出、强制终止后的恢复和启动参数去重，不读取开发者的恢复数据。Finder 打开测试还检查当前聚焦的窗口，覆盖带恢复记录的冷启动、连续打开不同文件、重新选中已打开文件和 Dock 激活。

连带开窗回归：预置一个未命名草稿和两个旧文件的恢复记录，再从 Finder 或启动参数打开第四个文件。修复前会出现四个窗口；测试要求只出现目标窗口，其他三个记录在退出后仍逐字节不变，随后直接启动应用仍能恢复。另覆盖目标文件自身的未保存草稿、同文件多份记录、多文件选择，以及稍后打开已改名的恢复文件。

启动判定使用显式打开请求与 AppKit 的 [`launchIsDefaultUserInfoKey`](https://developer.apple.com/documentation/appkit/nsapplication/launchisdefaultuserinfokey)，不靠延迟定时器猜测 Finder 事件是否已送达。

实现参考：[Apple 文件身份与 bookmark 文档](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/AccessingFilesandDirectories/AccessingFilesandDirectories.html)。旧路径复用场景另用描述符确认，因为单独的 bookmark 在该回归测试中会优先解析路径；Apple 已将 [`preferFileIDResolution`](https://developer.apple.com/documentation/foundation/nsurl/bookmarkcreationoptions/preferfileidresolution) 标为无效选项。
