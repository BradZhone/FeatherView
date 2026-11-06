# 参与开发

## 环境

- macOS 12 或更高版本
- Xcode Command Line Tools（`xcode-select --install`），不需要完整的 Xcode
- 可选：`rg`（ripgrep），装了以后工作区内容搜索会用它

## 常用命令

```bash
make            # 构建 build/FeatherView.app（本机架构，ad-hoc 签名）
make run        # 构建并以当前目录为工作区打开
make test       # 三组测试：逻辑 / Markdown / 真实视图
make install    # 安装到 /Applications（不可写时为 ~/Applications）
make release    # 先跑测试，再打 arm64 + x86_64 通用包到 dist/
scripts/bench.sh 3 20 > results.tsv   # 与 VS Code / Zed / Chrome 的资源占用对比
```

## 约定

- 代码风格跟随周围代码：ARC、四空格缩进、`static` C 函数处理纯计算、注释只写代码本身表达不了的约束。
- 新功能和修复都配测试。界面相关的放在 `tests/editor_tests.m`，用离屏窗口驱动真实视图；纯逻辑放在 `tests/tests.m`。
- 测试不能碰用户的真实数据：剪贴板用 `[NSPasteboard pasteboardWithUniqueName]`，删除用可注入的回收站处理器，文件放临时目录，假的应用包用 `.testapp` 扩展名（`.app` 会被 Launch Services 自动注册）。
- 不要让 FeatherView 成为任何文件类型的默认应用：Info.plist 里的文档类型必须是 `LSHandlerRank None`（`scripts/gen_doc_types.py` 生成，测试会检查）。
- 内存用 `footprint`（phys_footprint，活动监视器的“内存”列）衡量，不看 RSS。
- 动到性能敏感的路径（绘制、换行、搜索、大文件）时，留意 `make test` 打印的耗时。

## 发布

1. 更新 `Info.plist` 的 `CFBundleShortVersionString` / `CFBundleVersion` 和 `CHANGELOG.md`。
2. `make release`，得到 `dist/FeatherView-<版本>-macos-universal.zip` 和 `.sha256`。
3. 打 tag `v<版本>`，用 `gh release create` 上传这两个文件。
