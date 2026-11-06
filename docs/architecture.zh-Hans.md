# 架构说明

[English](architecture.md)

FeatherView 是基于 AppKit 的 Objective-C 应用，没有第三方依赖，由 `make` 直接调用 clang 构建。设计围绕一个目标展开：**在单个原生进程中提供文件查看与简单编辑能力，并尽可能降低内存占用。** 以下各项设计取舍均由此而来。

## 源码结构

```
src/
  Support/   本地化（FTL / FTLP）
  App/       应用入口、窗口、菜单、标签页与文档管理（ContentController）、设置、欢迎页、默认打开方式
  Editor/    文本编辑器：PieceTable 缓冲区；TextEditorView（绘制、输入、自动换行、小地图、搜索）；
             语法高亮；标签栏
  Files/     文件树、目录遍历与过滤、文件操作、类型识别、文件图标
  Search/    工作区搜索（ripgrep 或内置遍历器）、搜索面板、快速打开
  Preview/   Markdown 解析与原生渲染、HTML 预览、表格 / 树形 / Notebook 视图及其数据模型
  Viewers/   图片、SVG、PDF、十六进制、SQLite、压缩包查看器
Resources/   各语言的 <lang>.lproj 字符串表
tests/       三个测试程序：纯 Foundation 逻辑、Markdown 解析、离屏窗口中的真实视图
tools/       以代码绘制的应用图标
scripts/     安装、发布打包、资源占用对比、本地化检查、Info.plist 文档类型生成
docs/        本文档与资源占用对比
```

模块之间直接引用彼此的头文件。Makefile 为每个模块添加 `-I` 参数，因此 `#import "FileKind.h"` 无需写路径。

## 设计取舍

**编辑器不使用 NSTextView。** `TextEditorView` 是自行管理滚动的 `CanvasView`，每一帧只用 CoreText 排版可见的行。文本存储在 `PieceTable` 中：原文件以内存映射方式读取而不复制，修改追加到 add buffer，并同时维护一张行首偏移表。因此打开 100 MB 的日志与打开 1 KB 的文件，内存开销几乎相同，参见[资源占用对比](benchmark.zh-Hans.md)。

**自动换行基于前缀和。** 开启换行时，`_rowStart[L]` 记录逻辑行 L 的第一个视觉行。行号与视觉行之间的换算均为二分查找；编辑时只重新测量受影响的行，再整体平移其后的数据，在 10 万行的文件中每次按键约 0.04 ms。断行规则（在空格以及 `-`、`/`、`,` 等字符之后断行；中日韩字符之间可断行；`，`、`。` 不出现在行首；续行保持原行的缩进）集中在 `rowsOf:width:` 一个函数中，由行表构建、绘制、点击定位和光标移动共用，因此显示内容与点击位置始终一致。窗口宽度变化时，以视图顶部的逻辑行为锚点重建行表，内容不会跳动。

**Markdown 原生渲染，仅 HTML 使用 WebKit。** WKWebView 会启动 GPU、WebContent、Networking 三个辅助进程（实测约 70 MB），并且这些进程会一直保留到应用退出。因此 Markdown 由 FeatherView 自带的解析器转换为 TextKit 富文本显示，只有在真正打开 `.html` 文件时才创建 WebView；不查看 HTML 的会话不会产生这部分开销。

**数据视图按需解析。** CSV 单元格以字节区间（`uint32` 数组）存储，而不是为每个单元格创建字符串。JSON 由自带的解析器读取，保留键的顺序和行号，以便“在源码中显示”能准确跳转。SQLite 文件以只读方式打开并分页查询。压缩包内容通过系统自带的 `bsdtar` 列出。

**图片按显示尺寸解码。** ImageIO 只解码当前缩放级别所需的像素，放大时重新解码，上限为 2400 万像素。

**不抢占默认打开方式。** `Info.plist` 中所有文档类型均使用 `LSHandlerRank None`。安装后 FeatherView 只会出现在“打开方式”菜单中，不会自行成为任何文件类型的默认应用；只有用户在“默认打开方式”面板中明确勾选时才会更改。`tests/tests.m` 会检查这一点。

**界面文字支持本地化。** 开发语言为英文，英文原文即为键：`FTL(@"Save All")`。与数量相关的文字使用 `FTLP(n, @"%lu file", @"%lu files")`，英文在数量恰好为 1 时选用单数形式。翻译存放在 `Resources/<lang>.lproj/Localizable.strings` 中，macOS 根据用户的首选语言顺序选择界面语言（`zh-Hans` 时为简体中文，其余为英文）。`scripts/l10n.py` 作为 `make test` 的一部分运行，若出现缺少翻译、键与译文的格式说明符不一致、存在未使用的翻译，或源码中在字符串表之外出现中文，测试即失败。

## 测试

```bash
make test
```

- `scripts/l10n.py`：翻译覆盖率与格式说明符一致性。
- `build/tests`：PieceTable、目录遍历与过滤、搜索参数，以及 CSV、JSON、Notebook 解析等逻辑测试。
- `build/markdown_tests`：54 个 Markdown 解析用例。
- `build/editor_tests`：在离屏窗口中驱动真实的编辑器、文件树、标签页、预览和各类查看器，检查行为、像素与性能，例如“10 万行文件中小地图每帧耗时低于 16 ms”“每次编辑后，增量维护的换行表与完整重建的结果一致”；并分别以两种语言渲染菜单和状态栏。

测试不会触及用户的剪贴板、废纸篓、未命名文档备份或真实设置：使用独立的剪贴板、可注入的回收站处理器和临时目录。
