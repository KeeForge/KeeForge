# KeeForge への貢献

<a href="../../CONTRIBUTING.md">English</a> | <a href="CONTRIBUTING.de.md">Deutsch</a> | <a href="CONTRIBUTING.fr.md">Français</a> | <a href="CONTRIBUTING.es.md">Español</a> | <a href="CONTRIBUTING.zh-Hans.md">简体中文</a> | <a href="CONTRIBUTING.zh-Hant.md">繁體中文</a> | 日本語

KeeForge の改善にご協力いただきありがとうございます。

## 始める前に

- 大きめの変更については、範囲と方針を相談できるよう、先に issue を作成してください。
- まず [`AGENTS.md`](../../AGENTS.md) を読み、次に変更する予定のコードに最も近いフォルダ内の `README.md` を読んでください。
- 変更は目的を絞ってください。セキュリティに関わるパーサ、ライタ、暗号処理、秘密情報の取り扱い、保存経路の変更には、的を絞ったテストが必要です。

## 必要な環境

- iOS 18 以降と macOS 15 以降
- Xcode 26 以降
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- Swift 6（strict concurrency 有効）
- Swift Package の依存関係: [argon2](https://github.com/P-H-C/phc-winner-argon2)、[SwiftyDropbox](https://github.com/dropbox/SwiftyDropbox)、[Microsoft Authentication Library](https://github.com/AzureAD/microsoft-authentication-library-for-objc)、[swift-psl](https://github.com/ameshkov/swift-psl)、および同梱の [KeeForgeTwofish](../../Vendor/KeeForgeTwofish) パッケージ

## ソースからのビルド

```bash
cp BuildConfig.local.example.xcconfig BuildConfig.local.xcconfig
# クラウドプロバイダを有効にしたビルドでは DROPBOX_APP_KEY と ONEDRIVE_CLIENT_ID を設定します。
xcodegen generate
open KeeForge.xcodeproj
```

iPhone と iPad では iOS 18 以降のシミュレータまたはデバイスで `KeeForge` スキームを実行します。Mac では macOS 15 以降で `KeeForgeMac` スキームを実行します。

コマンドラインで確認する場合は、関連する最小のテストスライスを選んでください。

```bash
xcodebuild test -project KeeForge.xcodeproj -scheme KeeForge \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:KeeForgeTests/DatabaseViewModelTests -quiet

xcodebuild test -project KeeForge.xcodeproj -scheme KeeForgeMac \
  -destination 'platform=macOS' \
  -only-testing:KeeForgeMacTests/DatabaseViewModelTests -quiet
```

## 開発の進め方

1. リポジトリをフォークし、`main` からトピックブランチを作成します。
2. 課題を解決する、まとまりのある最小限の変更を行います。
3. テストを追加または更新します。関連する最小のテストターゲットと `-only-testing:` を使ってください。
4. すべてのプラットフォームについて、ユーザー向けの機能とバグ修正の内容を [`CHANGELOG.md`](../../CHANGELOG.md) の `## Unreleased` に追記します。
5. 動作の変更点と、それをどのように検証したかを説明するプルリクエストを作成します。

すべてのプルリクエストは、マージ前にメンテナがレビューします。KeeForge は squash マージを使用しているため、プルリクエストは目的を絞り、わかりやすいタイトルを付けてください。

### どのブランチを対象にするか

原則としてすべて `main` を対象にしてください。

リリースの準備中は、TestFlight で検証中の `release/{major}.{minor}` ブランチも存在します。このブランチを対象にするのは、メンテナから依頼があった場合のみです。リリース候補で見つかった不具合の修正のために用意されたブランチであり、コミットが入るたびに新しいビルドが作成され、テスト期間がやり直しになります。メンテナはそれらの修正を別途 `main` に取り込むため、同じ変更を両方のブランチに対して作成しないでください。

プルリクエストをマージするには、3 つのステータスチェックに合格する必要があります。

- **unit-tests** — GitHub Actions で、iOS シミュレータ上の `KeeForgeTests` ユニットスイートを実行します。
- **macos-unit-tests** — 共有ユニットテストを macOS 上の `KeeForgeMacTests` として実行します。
- **DCO** — すべてのコミットに署名（sign-off）があることを検証します（下記参照）。

## Developer Certificate of Origin

KeeForge は [Developer Certificate of Origin 1.1](https://developercertificate.org/)（DCO）を採用しています。コミットに署名することで、そのコントリビューションをこのリポジトリのオープンソースライセンスのもとで提出する権利があることを証明します。

各コミットには Git の `-s` オプションで署名してください。

```bash
git commit -s -m "fix: describe the change"
```

これにより、次のようなトレーラーがコミットメッセージに追加されます。

```text
Signed-off-by: Your Name <your.email@example.com>
```

署名は証明であって、暗号的な署名ではありません。`git commit -s` と `git commit -S` は別物です。

署名のないコミットがすでにある場合は、現在の `main` ブランチにリベースする際にまとめて追加できます。

```bash
git fetch origin
git rebase --signoff origin/main
```

リベースはコミット履歴を書き換えるため、その後は必要に応じて `git push --force-with-lease` でコントリビュータのブランチを更新してください。

## ライセンス

コントリビューションを提出することで、それがこのリポジトリを対象とする GNU GPL と同じ条件でライセンスされることに同意したものとみなされます。また、そのコントリビューションを自ら作成したか、その他の方法でこれらの条件のもとで提出する権利があることを表明したことになります。

ライセンスの互換性がない出所からコピーしたコードは提出しないでください。第三者のコード、生成されたアセット、その他ライセンスや著作権表示の要件が別にある素材を含む場合は、プルリクエストでその旨を明記してください。

---

これ以外の開発者向けドキュメント（[`AGENTS.md`](../../AGENTS.md) と各フォルダ内の `README.md`）は英語のみで管理されています。解釈に迷う場合は、[本ドキュメントの英語版](../../CONTRIBUTING.md)が優先されます。
