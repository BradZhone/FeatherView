# 资源占用对比：FeatherView、VS Code 与 Zed

[English](benchmark.md)

本文对比 FeatherView、Visual Studio Code 与 Zed 在打开同一工作区、同一组文件时的内存、CPU 时间和进程数量；查看 HTML 页面的场景另与 Google Chrome 对比。所有数据均可通过 [`scripts/bench.sh`](../scripts/bench.sh) 复现。

## 结果

内存取 3 次运行的中位数，括号内为最小值至最大值。CPU 为启动后前 20 秒内累计消耗的 CPU 时间。

| 场景 | FeatherView 0.15.0 | VS Code 1.107.1 | Zed 1.26.2 |
|---|---|---|---|
| 仅打开工作区 | **22 MB**（22–23）· 1 个进程 · 0.1 s | 535 MB（513–561）· 7 个进程 · 3.7 s | 109 MB（106–126）· 2 个进程 · 0.7 s |
| 打开 4 个文件：Objective-C 源码、Markdown、JSON、2 万行 CSV | **67 MB**（66–67）· 1 · 0.3 s | 706 MB（704–768）· 7 · 5.3 s | 121 MB（121–138）· 2 · 0.9 s |
| 打开 50 MB 日志 | **41 MB**（41–43）· 1 · 0.1 s | 716 MB（715–717）· 7 · 5.0 s | 255 MB（236–256）· 2 · 1.2 s |

| 场景 | FeatherView 0.15.0 | Chrome 157 |
|---|---|---|
| AI 生成的 HTML 报告（含样式、表格与 canvas 脚本） | **92 MB**（75–98）· 4 个进程 · 0.4 s | 194 MB（192–194）· 7 个进程 · 0.9 s |

| 应用体积 | FeatherView | VS Code | Zed | Chrome |
|---|---|---|---|---|
| `.app` 包 | 4 MB（通用二进制，arm64 + x86_64） | 659 MB | 176 MB | 1.4 GB |

在上述场景中，FeatherView 的内存占用约为 VS Code 的 1/10 至 1/25、Zed 的 1/2 至 1/6；查看 HTML 页面时约为 Chrome 的一半，并且同一窗口中还提供文件树和源码编辑。

每次运行的原始数据见 [benchmark-results.tsv](benchmark-results.tsv)。

## 结果解读

- **FeatherView 的功能更少。** 它没有语言服务器、扩展、Git 集成和终端。VS Code 的 7 个进程中包括扩展宿主、文件监视和终端宿主；如果安装了常用扩展，其内存占用会明显更高。本对比回答的是“查看与简单编辑需要付出多少资源”，而不是“哪个编辑器更好”。
- **Zed 在测试中未启动语言服务器。** 在全新配置下，Zed 在测量期间没有为 JSON 启动基于 Node 的语言服务器，只运行了主进程和崩溃处理进程。日常使用中语言服务器启动后，Zed 的占用会更高。
- **大文件场景差异最明显。** FeatherView 以内存映射方式打开文件而不复制，并且只排版可见的行，因此打开 50 MB 日志仅比空工作区多约 20 MB；Zed 和 VS Code 都会把整个文件读入各自的缓冲区。
- **HTML 场景中的 4 个进程**是 FeatherView 主进程，以及 WebKit 的 WebContent、GPU、Networking 三个辅助进程。只有打开 HTML 文件后才会出现这些进程；Markdown、表格与 JSON 均为原生渲染，不会启动 WebKit。
- **窗口是否可见会影响读数。** 原生窗口位于前台并被合成到屏幕上时，窗口缓冲区会计入内存（Retina 屏幕上的大窗口约 10–30 MB）。每次测量时被测应用均位于前台，条件一致，但各应用默认窗口尺寸不同，仍会带来数 MB 的差异。

## 测试环境

- MacBook Pro，Apple M4，16 GB 内存，macOS 15.5，内置 Liquid Retina XDR 显示屏（3024 × 1964）
- VS Code 1.107.1、Zed 1.26.2、Chrome 157.0.8103.38，均为官方发行版
- 工作区：本仓库的副本（208 个文件，53 MB），以及由脚本生成的文件：60 节的 Markdown 文档、2 万行 CSV、500 项的 JSON、一份 AI 风格的 HTML 报告和一个 50 MB 日志

## 测量方法

脚本为 [`scripts/bench.sh`](../scripts/bench.sh)：`scripts/bench.sh 3 20 > results.tsv` 表示运行 3 轮，每次等待 20 秒稳定。

- **内存**：`footprint` 报告的 `phys_footprint`，即活动监视器“内存”列显示的数值，按应用的整棵进程树求和。不使用 RSS，因为 RSS 包含共享库和可回收的映射。
- **WebKit 辅助进程**由 launchd 启动，而非应用的子进程。脚本将 FeatherView 启动后新出现的 WebKit 与 Quick Look 进程计入 FeatherView。测试期间未运行 Safari 等其他使用 WebKit 的应用。
- **隔离**：每个应用都使用临时目录中的全新配置——VS Code 使用 `--user-data-dir` 与 `--extensions-dir`，Zed 使用 `--user-data-dir`，Chrome 使用 `--user-data-dir`，FeatherView 使用修改了 bundle identifier 的副本，因而拥有独立的偏好设置域。测试不会读取或修改用户自己的设置、会话和扩展。脚本只结束由它启动的进程，退出时删除临时文件。
- **每次运行使用新的工作区路径**（APFS 克隆，不占用额外磁盘空间）。否则 VS Code 与 Zed 会恢复上一轮打开的标签页，导致读数偏高。
- **预热**：正式测量前，每个应用先完整启动一次，使首次运行的初始化（配置目录、缓存等）不计入结果。
- **对 VS Code 略为有利的设置**：关闭了遥测、更新检查和启动欢迎页。
- **Zed 必须通过 `Zed.app/Contents/MacOS/zed` 启动。** `cli` 包装程序会把请求交给已在运行的 Zed，并忽略 `--user-data-dir`。

## 复现

```bash
make
scripts/bench.sh 3 20 > results.tsv      # 约 20 分钟，期间各应用的窗口会依次出现
ONLY=Zed scripts/bench.sh 3 20           # 只测量一个编辑器
```

需要预先安装 VS Code、Zed 和 Chrome。脚本通过 Spotlight 查找它们，也可以通过 `ZED_APP=…` 或 `CHROME_APP=…` 指定路径。测试期间请勿操作电脑，并提前退出 Safari。
