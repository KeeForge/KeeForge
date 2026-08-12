# 为 KeeForge 做贡献

<a href="../../CONTRIBUTING.md">English</a> | <a href="CONTRIBUTING.de.md">Deutsch</a> | <a href="CONTRIBUTING.fr.md">Français</a> | <a href="CONTRIBUTING.es.md">Español</a> | 简体中文 | <a href="CONTRIBUTING.zh-Hant.md">繁體中文</a>

感谢你帮助改进 KeeForge。

## 开始之前

- 对于较大的改动，请先开一个 issue，以便讨论范围和实现方式。
- 先阅读 [`AGENTS.md`](../../AGENTS.md)，再阅读距离你计划修改的代码最近的文件夹内 `README.md`。
- 保持改动聚焦。涉及安全的解析器、写入器、加密、机密处理和保存路径的改动，需要配套有针对性的测试。

## 环境要求

- iOS 18+
- Xcode 26+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- Swift 6，启用严格并发检查
- Swift 包依赖：[Argon2Swift](https://github.com/tmthecoder/Argon2Swift)、[SwiftyDropbox](https://github.com/dropbox/SwiftyDropbox)、[Microsoft Authentication Library](https://github.com/AzureAD/microsoft-authentication-library-for-objc)，以及内置的 [KeeForgeTwofish](../../Vendor/KeeForgeTwofish) 包

## 从源码构建

```bash
cp BuildConfig.local.example.xcconfig BuildConfig.local.xcconfig
# 如需启用云服务商功能，请填入 DROPBOX_APP_KEY 和 ONEDRIVE_CLIENT_ID。
xcodegen generate
open KeeForge.xcodeproj
```

选择一台 iOS 18+ 的模拟器或设备，然后构建并运行 `KeeForge` scheme。

在命令行验证时，优先运行最小的相关测试切片：

```bash
xcodebuild test -project KeeForge.xcodeproj -scheme KeeForge \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:KeeForgeTests/DatabaseViewModelTests -quiet
```

## 开发流程

1. Fork 本仓库，并从 `main` 创建一个主题分支。
2. 做出能解决问题的最小的连贯改动。
3. 添加或更新测试，使用最小的相关测试 target 并配合 `-only-testing:`。
4. 在 [`CHANGELOG.md`](../../CHANGELOG.md) 的 `## Unreleased` 下添加功能和 bug 修复说明。
5. 开一个 pull request，描述行为上的变化以及如何验证。

Pull request 在合并前需要至少一个批准的审阅。KeeForge 使用 squash 合并，因此请保持 pull request 聚焦，并起一个清晰的标题。

### 应该以哪个分支为目标

默认情况下，一切都以 `main` 为目标。

在准备发布期间，还会有一个正在 TestFlight 上进行浸泡测试的 `release/{major}.{minor}` 分支。只有在维护者要求时才以该分支为目标——它专门用于修复在候选版本中发现的 bug，而且每个落到该分支的提交都会强制产生新的构建并重新开始测试窗口。维护者会另行把这些修复移植到 `main`；请不要向两个分支提交同一份改动。

Pull request 合并前必须通过两项状态检查：

- **unit-tests** —— 通过 GitHub Actions 在 iOS 模拟器上运行 `KeeForgeTests` 单元测试套件。
- **DCO** —— 验证每个提交都已签署（见下文）。

## Developer Certificate of Origin

KeeForge 使用 [Developer Certificate of Origin 1.1](https://developercertificate.org/)（DCO）。签署提交即表示你确认自己有权在本仓库的开源许可证下提交该贡献。

使用 Git 的 `-s` 选项签署每个提交：

```bash
git commit -s -m "fix: describe the change"
```

这会在提交信息末尾追加类似这样的一行：

```text
Signed-off-by: Your Name <your.email@example.com>
```

签署是一种声明确认，不是加密签名；`git commit -s` 与 `git commit -S` 是两回事。

如果已有提交缺少签署，可以在变基到当前 `main` 分支时补上：

```bash
git fetch origin
git rebase --signoff origin/main
```

由于变基会重写提交历史，之后请在必要时用 `git push --force-with-lease` 更新贡献者分支。

## 许可

提交贡献即表示你同意该贡献采用覆盖本仓库的同一 GNU GPL 条款进行许可。你同时声明该贡献由你本人创作，或你以其他方式有权在这些条款下提交它。

请勿提交从许可证不兼容的来源复制的代码。如包含第三方代码、生成的素材或其他有单独许可或署名要求的材料，请在 pull request 中说明。

---

其余开发者文档——[`AGENTS.md`](../../AGENTS.md) 和各文件夹内的 `README.md`——仅以英文维护。如有歧义，以[本文档的英文版本](../../CONTRIBUTING.md)为准。
