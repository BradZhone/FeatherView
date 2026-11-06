# 架构说明

FeatherView 是一个 Objective-C / AppKit 应用，没有第三方依赖，`make` 直接调用 clang 构建。设计目标只有一个：**在一个原生进程里把“看”和“简单改”做好，内存尽量少**。下面的取舍都从这里出发。

## 目录

```
src/
  App/       应用入口、窗口、菜单、标签页与文档管理（ContentController）、设置、欢迎页、默认打开方式
  Editor/    文本编辑器：PieceTable 缓冲区、TextEditorView（绘制 / 输入 / 换行 / 小地图 / 搜索）、语法高亮、标签栏
  Files/     文件树、目录遍历与过滤、文件操作、类型识别、文件图标
  Search/    工作区搜索（ripgrep 或内置遍历）、搜索面板、快速打开
  Preview/   Markdown 解析与原生渲染、HTML 预览、表格 / 树 / Notebook 视图及其数据模型
  Viewers/   图片、SVG、PDF、十六进制、SQLite、压缩包
tests/       三个测试程序：纯 Foundation 逻辑、Markdown 解析、真实视图（离屏窗口）
tools/       用代码绘制应用图标
scripts/     安装、发布打包、资源占用对比、Info.plist 文档类型生成
docs/        本文档和对比测试结果
```

各模块之间通过头文件直接引用，Makefile 为每个模块加 `-I`，所以 `#import "FileKind.h"` 不需要写路径。

## 关键设计

**编辑器不用 NSTextView。** `TextEditorView` 是一个自己滚动的 `CanvasView`，每帧只用 CoreText 排版可见的行。文本存放在 `PieceTable` 里：原文件内容用 mmap 映射、不复制，修改追加到 add buffer，再加一张行首偏移表。所以打开 100 MB 的日志和打开 1 KB 的文件内存相差无几，见 [资源占用对比](benchmark.md)。

**自动换行用前缀和。** 开启换行时，`_rowStart[L]` 记录第 L 行从第几个视觉行开始。行号和视觉行互查都是二分，编辑时只重新测量改动的那几行再整体平移，10 万行文件每次按键约 0.04 ms。断行规则（空格后、`-` `/` `,` 等之后、中日韩字符之间，不让 `，。` 落在行首，续行保持缩进）只在 `rowsOf:width:` 一个函数里，表格构建、绘制、点击和光标移动共用，所以不会出现“画的和点的不一致”。宽度改变时以顶部的逻辑行为锚点重建，内容不会跳。

**Markdown 原生渲染，只有 HTML 用 WebKit。** WKWebView 会启动 GPU / WebContent / Networking 三个辅助进程（实测约 70 MB），而且它们会一直留到应用退出。所以 Markdown 由自己的解析器转成 TextKit 富文本显示，只有真正打开 `.html` 时才创建 WebView：不看 HTML 的会话不付这笔内存。

**数据视图按需解析。** CSV 的单元格只记录字节区间（uint32 数组），不为每个单元格建字符串；JSON 用自己的解析器，保留键顺序和行号，所以能“在源码中显示”；SQLite 只读打开、分页查询；压缩包调用系统 `bsdtar` 列目录。

**图片按显示尺寸解码。** ImageIO 只解码到当前缩放需要的像素，放大时再重新解码，24 MP 封顶。

**默认打开方式不抢占。** Info.plist 里所有文档类型都是 `LSHandlerRank None`：安装后 FeatherView 只出现在“打开方式”里，不会悄悄成为任何文件的默认应用；用户在“默认打开方式…”面板里明确勾选才会改。`tests/tests.m` 会检查这一点。

## 测试

```
make test
```

- `build/tests`：PieceTable、文件遍历与过滤、搜索参数、CSV / JSON / Notebook 解析等纯逻辑。
- `build/markdown_tests`：Markdown 解析的 54 个用例。
- `build/editor_tests`：在离屏窗口里驱动真实的编辑器、文件树、标签页、预览和各类查看器，检查行为、像素和性能（例如“10 万行文件小地图一帧 < 16 ms”“自动换行的行表在每次编辑后都等于完整重建的结果”）。

测试不碰你的剪贴板、废纸篓、未命名文档备份或真实设置（使用独立的 pasteboard、可注入的回收站处理器和临时目录）。
