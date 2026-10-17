# GitHub / Typora 常用语法

这份示例可用于检查阅读模式、深色模式、HTML 和 PDF 导出。
在「设置 → Markdown 语法」中分别开启高亮、上标、下标，再观察可选语法。

## 引用式链接

[完整式链接][docs]、[docs][]、[docs]，以及 [大小写与空白匹配][  PROJECT   HOME ]。
找不到定义的 [missing] 保留原文。

## 自动链接

https://example.com/a_(b).

(https://example.com/a_(b)).

**https://example.com/docs** / www.example.com / hello@example.com

代码 `https://example.com` 和公式 $x^2$ 保持独立解析。

## Alerts

> [!NOTE]
> 标题跟随 App 界面语言，正文支持 **加粗** 和 [引用式链接][docs]。

> [!TIP]
> 可以在设置中开启 ==高亮==。

> [!IMPORTANT]
> 这段信息需要特别留意。

> [!WARNING]
> 执行操作前检查输入。

> [!CAUTION]
> 注意操作可能产生的影响。

## 可选语法

==高亮文字==，x^2^，H~2~O，X~long\ text~。

~~删除线~~ 不受下标开关影响。`==代码==`、`x^2^`、`H~2~O` 保留原文。

[docs]: https://example.com/docs "文档"
[project home]: https://example.com "项目首页"
