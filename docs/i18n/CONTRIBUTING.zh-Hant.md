# 參與 KeeForge 貢獻

<a href="../../CONTRIBUTING.md">English</a> | <a href="CONTRIBUTING.de.md">Deutsch</a> | <a href="CONTRIBUTING.fr.md">Français</a> | <a href="CONTRIBUTING.es.md">Español</a> | <a href="CONTRIBUTING.zh-Hans.md">简体中文</a> | 繁體中文

感謝你協助改進 KeeForge。

## 開始之前

- 若是較大幅度的變更，請先開一個 Issue，讓範圍與做法可以先討論。
- 先閱讀 [`AGENTS.md`](../../AGENTS.md)，再閱讀離你打算修改的程式碼最近的資料夾內 `README.md`。
- 讓變更保持聚焦。涉及安全性的解析器、寫入器、加密、機密處理與儲存路徑變更，都必須附上針對性的測試。

## 需求

- iOS 18+
- Xcode 26+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- Swift 6 與嚴格並行檢查（strict concurrency）
- Swift 套件相依：[Argon2Swift](https://github.com/tmthecoder/Argon2Swift)、[SwiftyDropbox](https://github.com/dropbox/SwiftyDropbox)、[Microsoft Authentication Library](https://github.com/AzureAD/microsoft-authentication-library-for-objc)，以及內建的 [KeeForgeTwofish](../../Vendor/KeeForgeTwofish) 套件

## 從原始碼建置

```bash
cp BuildConfig.local.example.xcconfig BuildConfig.local.xcconfig
# Fill in DROPBOX_APP_KEY and ONEDRIVE_CLIENT_ID for provider-enabled builds.
xcodegen generate
open KeeForge.xcodeproj
```

選擇 iOS 18 以上的模擬器或裝置，然後建置並執行 `KeeForge` scheme。

若要透過指令列驗證，請優先執行最小的相關測試片段：

```bash
xcodebuild test -project KeeForge.xcodeproj -scheme KeeForge \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:KeeForgeTests/DatabaseViewModelTests -quiet
```

## 開發工作流程

1. Fork 這個儲存庫，並從 `main` 建立一個主題分支。
2. 進行能解決問題的最小、連貫的變更。
3. 新增或更新測試，並使用最小的相關測試目標搭配 `-only-testing:`。
4. 在 [`CHANGELOG.md`](../../CHANGELOG.md) 的 `## Unreleased` 之下加入功能與錯誤修正的說明。
5. 開一個 Pull Request，描述行為上的變更以及驗證方式。

Pull Request 至少需要一個核准的審查才能合併。KeeForge 使用 squash 合併，因此請讓 Pull Request 保持聚焦，並給它一個清楚的標題。

### 該以哪個分支為目標

預設情況下，一律以 `main` 為目標。

在準備發佈期間，還會有一個正在 TestFlight 上進行浸泡測試的 `release/{major}.{minor}` 分支。
只有在維護者要求時才以該分支為目標——它保留給修正發佈候選版中發現的錯誤，而且每個
進入該分支的 commit 都會強制產生新的建置並重新開始測試期。維護者會另行將這些修正
移植回 `main`；請勿對兩個分支提交相同的變更。

Pull Request 合併前必須通過兩項狀態檢查：

- **unit-tests** —— 透過 GitHub Actions 在 iOS 模擬器上執行 `KeeForgeTests` 單元測試套件。
- **DCO** —— 驗證每個 commit 都已簽署（見下文）。

## Developer Certificate of Origin

KeeForge 採用 [Developer Certificate of Origin 1.1](https://developercertificate.org/)（DCO）。簽署 commit 即表示你保證有權依本儲存庫的開源授權條款提交這項貢獻。

使用 Git 的 `-s` 選項簽署每個 commit：

```bash
git commit -s -m "fix: describe the change"
```

這會在 commit 訊息末尾附加類似這樣的標記：

```text
Signed-off-by: Your Name <your.email@example.com>
```

這個簽署是一種聲明，而不是密碼學簽章；`git commit -s` 與 `git commit -S` 是不同的東西。

如果已有未簽署的 commit，可在 rebase 到最新 `main` 分支時補上：

```bash
git fetch origin
git rebase --signoff origin/main
```

由於 rebase 會改寫 commit 歷史，必要時請在之後以 `git push --force-with-lease` 更新貢獻者分支。

## 授權

提交貢獻即表示你同意該貢獻以涵蓋本儲存庫的相同 GNU GPL 條款授權。你同時聲明這項貢獻是由你建立，或你以其他方式有權依這些條款提交。

請勿提交從不相容來源複製的程式碼。若包含第三方程式碼、產生的素材，或其他有獨立授權或署名要求的內容，請在 Pull Request 中明確說明。

---

其餘的開發者文件——[`AGENTS.md`](../../AGENTS.md) 與各資料夾內的 `README.md`——僅以英文維護。如有歧義，以[本文件的英文版本](../../CONTRIBUTING.md)為準。
