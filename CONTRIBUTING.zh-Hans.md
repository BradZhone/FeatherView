# 参与开发

[English](CONTRIBUTING.md)

## 环境要求

- macOS 12 或更高版本
- Xcode Command Line Tools（`xcode-select --install`），无需安装完整的 Xcode
- Python 3（随 Command Line Tools 提供），用于本地化检查
- 可选：[ripgrep](https://github.com/BurntSushi/ripgrep)（`rg`），安装后工作区内容搜索将使用它

## 常用命令

```bash
make            # 构建 build/FeatherView.app（本机架构，ad-hoc 签名）
make run        # 构建，并以当前目录作为工作区打开
make test       # 本地化检查、逻辑测试、Markdown 测试、真实视图测试
make install    # 安装到 /Applications（不可写时安装到 ~/Applications）
make release    # 先运行测试，再将 arm64 + x86_64 通用包输出到 dist/
scripts/bench.sh 3 20 > results.tsv   # 与 VS Code、Zed、Chrome 的资源占用对比
```

## 开发约定

- **代码风格**：与周围代码保持一致，包括 ARC、四空格缩进、以 `static` C 函数处理纯计算；注释只用于说明代码本身无法表达的约束。
- **测试**：每项新功能和修复都应附带测试。界面相关的行为放在 `tests/editor_tests.m` 中，通过离屏窗口驱动真实视图；纯逻辑放在 `tests/tests.m` 中。
- **用户数据**：测试不得触及用户的真实数据。剪贴板使用 `[NSPasteboard pasteboardWithUniqueName]` 而非通用剪贴板，删除操作使用可注入的回收站处理器而非真实废纸篓，文件放在临时目录中。伪造的应用包使用 `.testapp` 扩展名，因为 Launch Services 会自动注册 `.app` 包。
- **默认打开方式**：FeatherView 不得自行成为任何文件类型的默认应用。`Info.plist` 中的所有文档类型必须使用 `LSHandlerRank None`；该列表由 `scripts/gen_doc_types.py` 生成，并由测试检查。
- **内存**：使用 `footprint`（`phys_footprint`，即活动监视器的“内存”列）衡量内存，而不是 RSS。
- **性能**：修改性能敏感的代码（绘制、自动换行、搜索、大文件处理）时，请对比 `make test` 输出的耗时。

## 界面文字

开发语言为英文，英文原文即为键。

1. 所有用户可见的字符串都用 `FTL(@"…")` 包裹。遵循 macOS 人机界面指南：菜单项与按钮使用标题式大写（Title Case），标签、提示与消息使用句子式大写（Sentence case）。
2. 含有数量的文字使用 `FTLP(count, @"%lu file", @"%lu files")`，英文在数量恰好为 1 时使用第一种形式。
3. 在 `Resources/zh-Hans.lproj/Localizable.strings` 中添加译文。`scripts/l10n.py --missing` 会以可直接填写的 `.strings` 格式列出尚未翻译的键。
4. 键与译文的格式说明符必须一致。若两种语言的参数顺序不同，请使用位置说明符（`%1$@`、`%2$@`）。
5. 运行 `make test`。如果缺少翻译、存在未使用的翻译、格式说明符不一致，或源码中在字符串表之外出现中文，`scripts/l10n.py` 会报错。

新增一种语言时，创建 `Resources/<语言代码>.lproj/Localizable.strings` 与 `InfoPlist.strings`，将语言代码加入 `Info.plist` 的 `CFBundleLocalizations`，然后运行 `make test`。

## 发布

1. 更新 `Info.plist` 中的 `CFBundleShortVersionString` 与 `CFBundleVersion`，并在 `CHANGELOG.md` 中添加对应条目。
2. 运行 `make release`，生成 `dist/FeatherView-<版本>-macos-universal.zip` 及其 `.sha256` 文件。
3. 为该提交打上 `v<版本>` 标签，并使用 `gh release create` 上传这两个文件。
