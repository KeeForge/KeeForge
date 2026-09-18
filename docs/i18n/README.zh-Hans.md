<p align="center">
  <img src="../../.github/assets/KeeForge-iOS-Default-1024x1024@1x.png" alt="KeeForge 应用图标" width="128" />
</p>

<h1 align="center">KeeForge</h1>

<p align="center">
  <a href="../../README.md">English</a> | <a href="README.de.md">Deutsch</a> | <a href="README.fr.md">Français</a> | <a href="README.es.md">Español</a> | 简体中文 | <a href="README.zh-Hant.md">繁體中文</a> | <a href="README.ja.md">日本語</a>
</p>

<p align="center">
  一款适用于 iPhone、iPad 和 Mac 的免费开源 KeePass 管理器。
  <br />
  原生 SwiftUI、本地优先存储、自动填充、通行密钥、TOTP、云同步、KDBX 编辑和附件查看。
</p>

<p align="center">
  <a href="https://apps.apple.com/us/app/keeforge/id6759309295">
    <img alt="在 App Store 下载" src="https://img.shields.io/badge/App%20Store-Download-0D96F6?style=for-the-badge&logo=appstore&logoColor=white" />
  </a>
  <a href="https://testflight.apple.com/join/mPAT4f1a">
    <img alt="通过 TestFlight 加入公开测试版" src="https://img.shields.io/badge/TestFlight-Public%20Beta-1F8AF0?style=for-the-badge&logo=apple&logoColor=white" />
  </a>
  <img alt="需要 iOS 18.0 或更高版本" src="https://img.shields.io/badge/iOS-18.0%2B-000000?style=for-the-badge&logo=apple&logoColor=white" />
  <img alt="需要 macOS 15.0 或更高版本" src="https://img.shields.io/badge/macOS-15.0%2B-000000?style=for-the-badge&logo=apple&logoColor=white" />
  <img alt="Swift LoC" src="https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Ftokei.kojix2.net%2Fapi%2Fgithub%2FKeeForge%2FKeeForge%2Flanguages&query=%24.data.languages.Swift.code&label=swift%20loc&color=orange&style=for-the-badge" />
  <a href="../../LICENSE">
    <img alt="许可证：GPLv3" src="https://img.shields.io/badge/license-GPLv3-blue?style=for-the-badge" />
  </a>
</p>

## 为什么选择 KeeForge？

KeeForge 是一款适用于 iPhone、iPad 和 Mac 的原生 KeePass 客户端。本地文件和 WebDAV 在所有平台上均可使用；iCloud 云盘、Dropbox、OneDrive 和其他“文件”提供方可在 iPhone 和 iPad 上使用。你可以用主密码、密钥文件或生物识别管理保险库，无需交给托管密码服务。

## 公开测试版

**[通过 TestFlight 加入 KeeForge 测试版](https://testflight.apple.com/join/mPAT4f1a)**

> [!WARNING]
> **请使用数据库的副本进行测试，不要使用你的主保险库。** 测试版构建未经审核，并且与 App Store 版本共用同一 bundle 标识符和容器——因此它们会打开你真实的 `.kdbx` 文件。

## 亮点

| 领域 | KeeForge 能做什么 |
| --- | --- |
| **KeePass 兼容性** | 读写采用 AES-256、ChaCha20 或 Twofish 加密及 AES-KDF、Argon2d 或 Argon2id 的 KDBX 4.x 数据库。也能以只读模式打开 KDBX 3.1 数据库。 |
| **本地优先编辑** | 创建、编辑、移动和删除条目与群组；保存时进行冲突检查、生成带时间戳的备份，并保留条目历史记录和未知 XML。 |
| **新建数据库** | 在所有平台上于本地或通过 WebDAV 创建 KDBX 4.x 数据库；Dropbox 和 OneDrive 可在 iPhone 和 iPad 上使用。 |
| **组合密钥** | 使用密码、密钥文件或两者组合解锁，支持二进制、十六进制、XML v1/v2（`.key`/`.keyx`）及任意密钥文件。 |
| **自动填充** | 在 App 和浏览器中原生自动填充，并支持生物识别解锁及全平台通行密钥注册；iPhone 和 iPad 还支持 QuickType 和从扩展创建密码条目。 |
| **通行密钥** | 检测并验证存储在 KeePassXC 兼容自定义字段中的 FIDO2/WebAuthn 通行密钥。 |
| **TOTP** | 在所有平台上实时显示、拷贝和倒计时，并在 iOS 18+ 和 Mac 上自动填充验证码。 |
| **云同步** | 所有平台均支持 WebDAV。Dropbox 和 OneDrive 目前可在 iPhone 和 iPad 上使用；Mac 可将其同步文件夹作为本地文件打开。 |
| **附件** | 查看 KeePass 条目附件，通过 QuickLook 预览支持的文件，并从短暂存在的受保护临时文件分享。暂不支持编辑附件。 |
| **每块屏幕都原生** | iPhone 上专注的导航、iPad 上分栏式工作区，以及带有菜单、命令和 Touch ID、为桌面优化的原生 Mac App。 |
| **安全** | AES-GCM 内存中机密加密、解锁失败退避、解压炸弹限制，以及恒定时间的 HMAC 比较。 |

## 隐私

KeeForge 没有分析统计、没有后台遥测、也没有崩溃报告 SDK。保险库数据只保留在设备上和你选择的存储位置。网络访问仅限于已连接的云服务商、可选启用的通过 DuckDuckGo 获取网站图标、可选的 App Store“打赏”内购、直接下载版 Mac App 的更新检查，以及你主动提交消息时使用的应用内反馈表单。

在 iPhone 和 iPad 上，拷贝的机密会标记为仅限本机，不会通过通用剪贴板传输。macOS 不提供这项排除能力，因此在 Mac 上可能会遵循你的系统设置；KeeForge 会将内容标记为机密，并在短时间后或锁定时清除。KeeForge 还会保护 iPhone 和 iPad 的 App 切换器预览。Mac 上的屏幕捕获阻止功能属于尽力保护，可能无法阻止所有截屏或录屏。

请阅读[隐私政策](https://keeforge.com/zh-hans/privacy)（[英文原文](https://keeforge.com/privacy)）。

## 数据安全

KeeForge 非常重视数据安全：密码管理器绝不能损坏你的保险库，也不能悄悄丢失其中的任何部分。每项更改在发布前，都要经过自动化测试验证：

- **保存时不会丢失任何内容。** 每一种编辑都会被保存并逐项读回验证——密码、备注、附件、条目历史记录，甚至 KeeForge 无法识别的来自其他 KeePass 应用的数据，都必须与写入时完全一致地读回。
- **文件在被触碰之前已受保护。** 如果文件在你打开期间被其他地方修改过，KeeForge 会拒绝覆盖；每次保存前都会写入带时间戳的备份；对已损坏的数据库直接拒绝打开，而不是加载不完整的数据。
- **有独立程序交叉验证。** 每个版本都必须通过一道验证关卡：由 KeePassXC——一款与 KeeForge 不共享任何代码、被广泛使用的 KeePass 应用——打开 KeeForge 写入的数据库、解密其中的密码，并确认附件逐位一致。同样，其他 KeePass 软件创建的数据库也必须能在 KeeForge 中打开，并在 KeeForge 保存后仍能被其他软件读取。

对技术细节感兴趣的话，测试套件的说明见 [`KeeForgeTests/AGENTS.md`](../../KeeForgeTests/AGENTS.md)，发布前验证关卡的说明见 [`ci_scripts/README.md`](../../ci_scripts/README.md)（均为英文）。

## 项目结构

```text
KeeForge/
├── App/              # App 入口、自适应根壳层、场景生命周期
├── Extensions/       # 共享的平台兼容辅助代码
├── Models/           # KDBX 解析器/写入器、加密、编辑草稿、TOTP、通行密钥
├── Resources/        # 字符串目录和资源目录
├── Services/         # 持久化、云同步、钥匙串、书签、附件、自动填充辅助
├── ViewModels/       # 数据库列表、解锁、保存、搜索、排序、TOTP 状态
├── Views/            # SwiftUI 界面、编辑器、设置、打赏、可复用控件
AutoFillExtension/    # 自动填充凭据提供方、通行密钥认证、凭据创建
KeeForgeMac/          # 原生 macOS 应用（正在准备首个版本）
KeeForgeMacUITests/   # macOS 应用的 XCUITest 覆盖
KeeForgeTests/        # 单元测试
KeeForgeUITests/      # XCUITest 覆盖
TestFixtures/         # 示例 .kdbx 数据库和密钥文件
Vendor/               # 内置的 KeeForgeTwofish Swift 包
ci_scripts/           # Xcode Cloud 引导脚本和发布关卡脚本
scripts/              # 本地开发工具
```

## 文档

- [`CHANGELOG.md`](../../CHANGELOG.md) - 版本历史
- [`ROADMAP.md`](../../ROADMAP.md) - 规划中的产品工作和当前优先事项
- [`AGENTS.md`](../../AGENTS.md) - 面向编码代理的上下文
- [`KeeForge/README.md`](../../KeeForge/README.md) - 应用 target 架构图
- [`AutoFillExtension/AGENTS.md`](../../AutoFillExtension/AGENTS.md) - 扩展的限制和共享源码说明
- [`SECURITY.md`](../../SECURITY.md) - 漏洞披露政策
- [`docs/`](../../docs/) - 实现规格、审计和较长篇幅的设计文档

除本 README 和 [`CONTRIBUTING.zh-Hans.md`](CONTRIBUTING.zh-Hans.md) 外，开发者文档仅以英文维护。

## 支持

- App Store：[App Store 上的 KeeForge](https://apps.apple.com/us/app/keeforge/id6759309295)
- 电子邮件：[support@keeforge.com](mailto:support@keeforge.com)
- 问题反馈：[GitHub Issues](https://github.com/KeeForge/KeeForge/issues)

## 参与贡献

构建要求、如何从源码构建、pull request 工作流程、Developer Certificate of Origin 签署要求以及许可条款，请参阅 [`CONTRIBUTING.zh-Hans.md`](CONTRIBUTING.zh-Hans.md)。先从 [`AGENTS.md`](../../AGENTS.md) 开始，再打开距离你要修改的代码最近的文件夹内 `README.md`。

## 许可证

KeeForge 采用 GPLv3 许可证。详情见 [`LICENSE`](../../LICENSE)。
