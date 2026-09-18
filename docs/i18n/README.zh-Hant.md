<p align="center">
  <img src="../../.github/assets/KeeForge-iOS-Default-1024x1024@1x.png" alt="KeeForge App 圖示" width="128" />
</p>

<h1 align="center">KeeForge</h1>

<p align="center">
  <a href="../../README.md">English</a> | <a href="README.de.md">Deutsch</a> | <a href="README.fr.md">Français</a> | <a href="README.es.md">Español</a> | <a href="README.zh-Hans.md">简体中文</a> | 繁體中文 | <a href="README.ja.md">日本語</a>
</p>

<p align="center">
  適用於 iPhone、iPad 與 Mac 的免費開源 KeePass 管理工具。
  <br />
  原生 SwiftUI、本機優先儲存、自動填寫、通行金鑰、TOTP、雲端同步、KDBX 編輯與附件檢視。
</p>

<p align="center">
  <a href="https://apps.apple.com/us/app/keeforge/id6759309295">
    <img alt="在 App Store 下載" src="https://img.shields.io/badge/App%20Store-Download-0D96F6?style=for-the-badge&logo=appstore&logoColor=white" />
  </a>
  <a href="https://testflight.apple.com/join/mPAT4f1a">
    <img alt="透過 TestFlight 加入公開測試版" src="https://img.shields.io/badge/TestFlight-Public%20Beta-1F8AF0?style=for-the-badge&logo=apple&logoColor=white" />
  </a>
  <img alt="需要 iOS 18.0 或以上版本" src="https://img.shields.io/badge/iOS-18.0%2B-000000?style=for-the-badge&logo=apple&logoColor=white" />
  <img alt="需要 macOS 15.0 或以上版本" src="https://img.shields.io/badge/macOS-15.0%2B-000000?style=for-the-badge&logo=apple&logoColor=white" />
  <img alt="Swift LoC" src="https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Ftokei.kojix2.net%2Fapi%2Fgithub%2FKeeForge%2FKeeForge%2Flanguages&query=%24.data.languages.Swift.code&label=swift%20loc&color=orange&style=for-the-badge" />
  <a href="../../LICENSE">
    <img alt="授權條款：GPLv3" src="https://img.shields.io/badge/license-GPLv3-blue?style=for-the-badge" />
  </a>
</p>

## 為什麼選擇 KeeForge？

KeeForge 是適用於 iPhone、iPad 與 Mac 的原生 KeePass 用戶端。本機檔案與 WebDAV 可在所有平台使用；iCloud 雲碟、Dropbox、OneDrive 與其他「檔案」提供者可在 iPhone 與 iPad 使用。你可以用主密碼、金鑰檔案或生物辨識管理保險庫，不必交給託管式密碼服務。

## 公開測試版

**[透過 TestFlight 加入 KeeForge 測試版](https://testflight.apple.com/join/mPAT4f1a)**

> [!WARNING]
> **請用資料庫的副本測試，不要使用你的主要保險庫。** 測試版建置未經審查，且與 App Store 版 App 共用相同的 bundle identifier 與容器——因此會開啟你真正的 `.kdbx` 檔案。

## 功能亮點

| 領域 | KeeForge 能做什麼 |
| --- | --- |
| **KeePass 相容性** | 讀取與寫入採用 AES-256、ChaCha20 或 Twofish 加密，以及 AES-KDF、Argon2d 或 Argon2id 的 KDBX 4.x 資料庫。也能以唯讀模式開啟 KDBX 3.1 資料庫。 |
| **本機優先編輯** | 建立、編輯、移動與刪除項目與群組；儲存時進行衝突檢查、產生帶時間戳記的備份，並保留項目歷史記錄與未知的 XML 內容。 |
| **新資料庫** | 在所有平台於本機或透過 WebDAV 建立 KDBX 4.x 資料庫；Dropbox 與 OneDrive 可在 iPhone 與 iPad 使用。 |
| **複合金鑰** | 以密碼、金鑰檔案或兩者搭配解鎖，支援二進位、十六進位、XML v1/v2（`.key`/`.keyx`）與任意格式的金鑰檔案。 |
| **自動填寫** | 在 App 與瀏覽器中原生自動填寫，並支援生物辨識解鎖及全平台通行金鑰註冊；iPhone 與 iPad 另支援 QuickType 與從延伸功能建立密碼項目。 |
| **通行金鑰** | 偵測並驗證儲存在 KeePassXC 相容自訂欄位中的 FIDO2/WebAuthn 通行金鑰。 |
| **TOTP** | 在所有平台即時顯示、拷貝與倒數計時，並在 iOS 18 以上與 Mac 自動填寫驗證碼。 |
| **雲端同步** | 所有平台都支援 WebDAV。Dropbox 與 OneDrive 目前可在 iPhone 與 iPad 使用；Mac 可將其同步資料夾當成本機檔案開啟。 |
| **附件** | 檢視 KeePass 項目附件、以 QuickLook 預覽支援的檔案，並透過短暫存在的受保護暫存檔分享。目前尚不支援編輯附件。 |
| **每個螢幕都原生** | iPhone 上專注的導覽、iPad 上分割顯示的工作區，以及具備選單、指令與 Touch ID、針對桌面最佳化的原生 Mac App。 |
| **安全性** | AES-GCM 記憶體內機密加密、解鎖失敗後的退避延遲、解壓縮炸彈防護上限，以及恆定時間的 HMAC 比對。 |

## 隱私權

KeeForge 沒有任何分析工具、背景遙測或當機回報 SDK。保險庫資料只會留在裝置上，以及你自己選擇的儲存位置。網路存取僅限於已連接的雲端服務、選擇性啟用的 DuckDuckGo 網站圖示擷取、自願的 App Store 小費購買、直接下載版 Mac App 的更新檢查，以及你主動送出訊息時的 App 內回饋表單。

在 iPhone 與 iPad 上，拷貝的機密會標示為僅限本機，不會經由通用剪貼簿傳送。macOS 不提供這項排除能力，因此在 Mac 上可能會依照你的系統設定同步；KeeForge 會將內容標示為機密，並在短時間後或鎖定時清除。KeeForge 也會保護 iPhone 與 iPad 的 App 切換器預覽。Mac 上的螢幕擷取阻擋功能屬於盡力保護，可能無法阻止所有截圖或螢幕錄影。

請參閱[隱私權政策](https://keeforge.com/zh-hant/privacy)（[英文原文](https://keeforge.com/privacy)）。

## 資料安全

KeeForge 非常重視資料安全：密碼管理工具絕不能損毀你的保險庫，也不能悄悄遺失其中任何一部分。每項變更出貨前，自動化測試都會驗證：

- **儲存時不會遺失任何內容。** 每一種編輯都會被儲存後逐項讀回比對——密碼、備註、附件、項目歷史記錄，甚至是 KeeForge 無法識別、來自其他 KeePass App 的資料，都必須與寫入時完全一致。
- **檔案在被動到之前就已受到保護。** 若檔案在你開啟期間曾在其他地方被修改，KeeForge 會拒絕覆寫；每次儲存前都會先寫入帶時間戳記的備份；遇到損毀的資料庫則直接拒絕開啟，而不是載入不完整的資料。
- **由獨立程式交叉驗證。** 每個版本都必須通過一道關卡：由 KeePassXC——一款廣泛使用、與 KeeForge 不共用任何程式碼的 KeePass App——開啟 KeeForge 寫入的資料庫、解密其中的密碼，並確認附件逐位元完全相符。反過來，其他 KeePass 軟體建立的資料庫也必須能在 KeeForge 中開啟，且經 KeeForge 儲存後仍能在其他軟體中正常讀取。

想深入了解技術細節的話，測試套件的說明在 [`KeeForgeTests/AGENTS.md`](../../KeeForgeTests/AGENTS.md)，發佈前的驗證關卡則在 [`ci_scripts/README.md`](../../ci_scripts/README.md)（皆為英文）。

## 專案地圖

```text
KeeForge/
├── App/              # App 進入點、自適應根殼層、場景生命週期
├── Extensions/       # 共用的平台相容輔助工具
├── Models/           # KDBX 解析器/寫入器、加密、編輯草稿、TOTP、通行金鑰
├── Resources/        # 字串目錄與素材目錄
├── Services/         # 持久化、雲端同步、鑰匙圈、書籤、附件、自動填寫輔助工具
├── ViewModels/       # 資料庫列表、解鎖、儲存、搜尋、排序、TOTP 狀態
├── Views/            # SwiftUI 畫面、編輯器、設定、小費頁面、可重複使用的控制項
AutoFillExtension/    # 自動填寫憑證提供者、通行金鑰驗證、憑證建立
KeeForgeMac/          # 原生 macOS App（正在準備首個版本）
KeeForgeMacUITests/   # macOS App 的 XCUITest 覆蓋
KeeForgeTests/        # 單元測試
KeeForgeUITests/      # XCUITest 覆蓋
TestFixtures/         # 範例 .kdbx 資料庫與金鑰檔案
Vendor/               # 內建的 KeeForgeTwofish Swift 套件
ci_scripts/           # Xcode Cloud 啟動與發佈關卡指令碼
scripts/              # 本機開發工具
```

## 文件

- [`CHANGELOG.md`](../../CHANGELOG.md) - 版本歷史
- [`ROADMAP.md`](../../ROADMAP.md) - 規劃中的產品工作與待辦優先事項
- [`AGENTS.md`](../../AGENTS.md) - 給編碼代理程式的背景資訊
- [`KeeForge/README.md`](../../KeeForge/README.md) - App 目標的架構地圖
- [`AutoFillExtension/AGENTS.md`](../../AutoFillExtension/AGENTS.md) - 延伸功能限制與共用程式碼說明
- [`SECURITY.md`](../../SECURITY.md) - 弱點揭露政策
- [`docs/`](../../docs/) - 實作規格、稽核與較長篇的設計文件

除了本 README 與 [`CONTRIBUTING.zh-Hant.md`](CONTRIBUTING.zh-Hant.md) 之外，開發者文件僅以英文維護。

## 支援

- App Store：[App Store 上的 KeeForge](https://apps.apple.com/us/app/keeforge/id6759309295)
- 電子郵件：[support@keeforge.com](mailto:support@keeforge.com)
- 問題回報：[GitHub Issues](https://github.com/KeeForge/KeeForge/issues)

## 參與貢獻

請參閱 [`CONTRIBUTING.zh-Hant.md`](CONTRIBUTING.zh-Hant.md)，了解建置需求、如何從原始碼建置、Pull Request 工作流程、Developer Certificate of Origin 簽署要求與授權條款。先從 [`AGENTS.md`](../../AGENTS.md) 開始，再開啟離你要修改的程式碼最近的資料夾內 `README.md`。

## 授權條款

KeeForge 以 GPLv3 授權。詳情請見 [`LICENSE`](../../LICENSE)。
