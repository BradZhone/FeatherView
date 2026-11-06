# 更新记录

[English](CHANGELOG.md)

本文件记录 FeatherView 的所有重要变更。格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循[语义化版本](https://semver.org/lang/zh-CN/)。1.0 之前，次版本号的变化可能包含不兼容的改动。

## [0.16.0] — 尚未发布

### 新增

- 英文界面。开发语言改为英文，并提供简体中文翻译；macOS 根据系统的首选语言顺序选择界面语言。也可以在“系统设置 → 通用 → 语言与地区 → 应用程序”中单独为 FeatherView 指定语言。
- 英文中按数量正确使用单复数（“1 file”“2 files”）。
- `scripts/l10n.py`：由 `make test` 运行，检查每条界面文字都已翻译且格式说明符一致。
- 默认文档改为英文，并提供 README、资源占用对比、架构说明与贡献指南的简体中文版本。

### 变更

- 文档改写为更正式的风格。
- 为适应英文文字长度调整了布局：设置窗口增加了边距，默认打开方式面板加宽了名称列。

## [0.15.0] — 2026-11-06

首个打包发布的版本，项目更名为 **FeatherView**。

### 新增

- 编辑器自动换行，随窗口宽度实时重排。按词断行，中日韩字符之间可断行（右侧标点不出现在行首），续行保持原行缩进。可通过 ⌥Z 或设置切换，默认开启。超过 100 万行或 32 MB 的文件不换行，并在状态栏注明。
- 制表符按 4 列对齐（此前约为 3.6 列）。
- 命令行支持多个 `--open <文件>` 参数。
- `scripts/release.sh`（arm64 + x86_64 通用包）与 `scripts/bench.sh`（资源占用对比）。
- README、资源占用对比、架构说明、贡献指南与 MIT 许可证。

### 变更

- 应用、菜单与安装位置改为 FeatherView.app。bundle identifier 仍为 `local.feather.editor`，原有设置、会话、最近工作区和默认打开方式均保留。`make install` 会将旧的 Feather.app 移到废纸篓。
- 源码拆分为 `src/App`、`Editor`、`Files`、`Search`、`Preview`、`Viewers` 等模块。

## [0.14] — 2026-11-06

- CSV、TSV、JSON Lines 显示为可排序、可筛选的表格。
- JSON 与属性列表（含二进制格式）显示为可折叠的树；Jupyter Notebook 渲染为文档。
- 只读 SQLite 浏览器；压缩包内容列表，双击可解压并打开。
- 设置窗口（⌘,）：外观、隐藏文件、始终隐藏的名称、搜索排除、`.gitignore`、自动保存、小地图。

## [0.13]

- ⌘N 新建未命名文档，在关闭前作为草稿保留（与 VS Code 相同）。
- 浅色、深色与跟随系统的外观；最近工作区可单独移除。
- 默认打开方式面板说明：只有浏览器可以成为 `.html` 的默认应用。

## [0.12] 及更早

- 工作区搜索（全部 / 文件名 / 内容；区分大小写、全词匹配、正则表达式；包含与排除路径）。
- 文件树多选与批量操作；SVG 与 TypeScript 文件识别；新图标与配色。
- 原生 Markdown 渲染、HTML 预览、图片、PDF 与十六进制查看器、小地图、自动保存、会话恢复。

[0.16.0]: https://github.com/BradZhone/feather/compare/v0.15.0...HEAD
[0.15.0]: https://github.com/BradZhone/feather/releases/tag/v0.15.0
