# 更新记录

版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。1.0 之前，次版本号变化可能包含不兼容的改动。

## 0.15.0 — 2026-11-06

首个对外打包的版本，项目更名为 **FeatherView**。

新增
- 编辑器自动换行：随窗口宽度实时重排，按词断行，中文按字断行且标点不出现在行首，续行保持缩进；⌥Z 或设置里切换，默认开启。超过 100 万行或 32 MB 的文件不换行，状态栏会注明。
- 制表符按 4 列对齐（之前约 3.6 列）。
- 命令行可传多个 `--open <文件>`。
- 发布脚本 `scripts/release.sh`（arm64 + x86_64 通用包）和对比测试脚本 `scripts/bench.sh`。
- 文档：README、资源占用对比（`docs/benchmark.md`）、架构说明（`docs/architecture.md`）、贡献指南、MIT 许可。

变更
- 应用名、菜单和安装位置改为 FeatherView.app。bundle id 仍是 `local.feather.editor`，原有的设置、会话、最近工作区和默认打开方式都会保留。`make install` 会把旧的 Feather.app 移到废纸篓。
- 源码按模块拆分到 `src/App`、`Editor`、`Files`、`Search`、`Preview`、`Viewers`。

## 0.14 — 2026-11-06

- CSV / TSV / JSON Lines 显示为可排序、可筛选的表格。
- JSON、plist（含二进制 plist）显示为可折叠的树，Jupyter Notebook 渲染为文档。
- 只读 SQLite 浏览器，压缩包内容列表（双击解压并打开）。
- 设置窗口（⌘,）：外观、显示隐藏文件、始终隐藏列表、搜索跳过列表、.gitignore、自动保存、小地图。

## 0.13

- ⌘N 新建未命名文档，像 VS Code 一样暂存，关闭时才询问保存位置。
- 浅色 / 深色 / 跟随系统；最近工作区可单个删除。
- 默认打开方式面板说明 .html 只能由浏览器做默认应用。

## 0.12 及更早

- 工作区搜索（全部 / 文件名 / 内容，大小写、全词、正则，包含 / 排除路径）。
- 文件树多选与批量操作，SVG、TypeScript 文件识别，新图标与配色。
- 原生 Markdown 渲染、HTML 预览、图片、PDF、十六进制查看，小地图，自动保存，会话恢复。
