# 资源占用对比：FeatherView、VS Code、Zed

同一台机器、同一个工作区、同样的文件，分别用三个编辑器打开，等 20 秒稳定后读取整棵进程树的内存和 CPU。查看 HTML 的场景另外与 Chrome 对比。

## 结果

内存是 3 次运行的中位数（括号里是最小值到最大值）。CPU 是启动后前 20 秒累计消耗的 CPU 时间。

| 场景 | FeatherView 0.15.0 | VS Code 1.107.1 | Zed 1.26.2 |
|---|---|---|---|
| 只打开工作区 | **22 MB**（22–23） · 1 个进程 · 0.1 s | 535 MB（513–561） · 7 个进程 · 3.7 s | 109 MB（106–126） · 2 个进程 · 0.7 s |
| 打开 4 个文件：.m 源码、Markdown、JSON、2 万行 CSV | **67 MB**（66–67） · 1 · 0.3 s | 706 MB（704–768） · 7 · 5.3 s | 121 MB（121–138） · 2 · 0.9 s |
| 打开 50 MB 日志 | **41 MB**（41–43） · 1 · 0.1 s | 716 MB（715–717） · 7 · 5.0 s | 255 MB（236–256） · 2 · 1.2 s |

| 场景 | FeatherView 0.15.0 | Chrome 157 |
|---|---|---|
| 查看 AI 生成的 HTML 报告（样式、表格、canvas 脚本） | **92 MB**（75–98） · 4 个进程 · 0.4 s | 194 MB（192–194） · 7 个进程 · 0.9 s |

| 安装体积 | FeatherView | VS Code | Zed | Chrome |
|---|---|---|---|---|
| .app 大小 | 4 MB（通用包，arm64 + x86_64） | 659 MB | 176 MB | 1.4 GB |

粗略地说：只看文件时，FeatherView 的内存约为 VS Code 的 1/10 到 1/25，约为 Zed 的 1/2 到 1/6；看一个 HTML 页面约为 Chrome 的一半，而且同一个窗口里还能看文件树、改源码。

各次运行的原始数据在 [benchmark-results.tsv](benchmark-results.tsv)。

## 这些数字说明什么，不说明什么

- **FeatherView 做的事更少。** 它没有语言服务器、扩展、Git 集成和终端。VS Code 的 7 个进程里有扩展宿主、文件监视、终端宿主；如果装了常用扩展，它的内存会明显更高。这份对比回答的是“只是看看和改两行时，要付出多少资源”，不是“哪个编辑器更好”。
- **Zed 这次没有启动语言服务器。** 在全新的配置下，它在测试期间没有为 JSON 拉起 Node 语言服务器（只有主进程和崩溃处理进程）。日常使用中语言服务器启动后，Zed 的占用会更高。
- **大文件差异最明显。** FeatherView 把文件映射进内存而不是复制，只排版屏幕上的几十行，所以 50 MB 日志只比空工作区多约 20 MB；Zed 和 VS Code 都会把整个文件读入自己的缓冲区。
- **HTML 场景的 4 个进程**是 FeatherView 主进程加 WebKit 的 WebContent、GPU、Networking 三个辅助进程。只有打开 HTML 时才会有它们；Markdown、表格、JSON 都是原生渲染，不会启动 WebKit。
- **窗口可见与否会影响读数。** 原生窗口在前台、被合成到屏幕上时，窗口缓冲区会计入内存（Retina 下一个大窗口约 10–30 MB）。每次运行都让被测应用在前台，三者条件相同，但不同的窗口默认大小仍会带来几 MB 到十几 MB 的差别。

## 环境

- MacBook Pro，Apple M4，16 GB 内存，macOS 15.5，内置 Liquid Retina XDR 显示屏（3024×1964）
- VS Code 1.107.1、Zed 1.26.2、Chrome 157.0.8103.38，均为官方发行版
- 工作区：本仓库的副本（208 个文件，53 MB），加上一份 60 节的 Markdown、2 万行 CSV、500 项的 JSON、一个 AI 风格的 HTML 报告和一个 50 MB 日志，均由脚本生成

## 方法

脚本：[`scripts/bench.sh`](../scripts/bench.sh)，用法 `scripts/bench.sh 3 20 > results.tsv`（3 轮，每次等待 20 秒）。

- **内存**：`footprint` 报告的 phys_footprint，也就是活动监视器“内存”一列的数字，对应用的整棵进程树求和。不用 RSS：RSS 会把共享库和可回收的映射也算进去。
- **WebKit 辅助进程**由 launchd 启动，不是应用的子进程。脚本把“FeatherView 启动后新出现的 WebKit / Quick Look 进程”算到它头上。测试时没有打开 Safari 等其他 WebKit 应用。
- **隔离**：每个应用都使用临时目录里的全新配置（VS Code `--user-data-dir` / `--extensions-dir`，Zed `--user-data-dir`，Chrome `--user-data-dir`，FeatherView 改了 bundle id 的副本，拥有独立的偏好设置域），不读写你自己的设置、会话和扩展。脚本只结束自己启动的进程，退出时删除临时文件。
- **每次运行使用新的工作区路径**（APFS 克隆，不占额外空间），否则 VS Code 和 Zed 会恢复上一轮打开的标签页，读数会偏高。
- **预热**：正式测量前，每个应用先完整启动一次，让首次运行的初始化（配置目录、缓存）不计入结果。
- **对 VS Code 稍有利的设置**：关闭了遥测、自动更新检查和启动欢迎页。
- **Zed 要直接运行 `Zed.app/Contents/MacOS/zed`**：`cli` 包装程序会把请求交给已经运行的 Zed，并忽略 `--user-data-dir`。

## 自己复现

```bash
make
scripts/bench.sh 3 20 > results.tsv      # 约 20 分钟，期间各应用的窗口会轮流弹出
ONLY=Zed scripts/bench.sh 3 20           # 只测一个编辑器
```

需要安装 VS Code、Zed 和 Chrome（脚本通过 Spotlight 查找，也可以用 `ZED_APP=… CHROME_APP=…` 指定路径）。测试期间不要操作电脑，并关闭 Safari。
