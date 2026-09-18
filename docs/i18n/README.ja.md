<p align="center">
  <img src="../../.github/assets/KeeForge-iOS-Default-1024x1024@1x.png" alt="KeeForge の App アイコン" width="128" />
</p>

<h1 align="center">KeeForge</h1>

<p align="center">
  <a href="../../README.md">English</a> | <a href="README.de.md">Deutsch</a> | <a href="README.fr.md">Français</a> | <a href="README.es.md">Español</a> | <a href="README.zh-Hans.md">简体中文</a> | <a href="README.zh-Hant.md">繁體中文</a> | 日本語
</p>

<p align="center">
  iPhone、iPad、Mac のための、無料でオープンソースの KeePass マネージャ。
  <br />
  ネイティブ SwiftUI、ローカルファーストの保存、自動入力、パスキー、TOTP、クラウド同期、KDBX の編集、添付ファイルの表示に対応しています。
</p>

<p align="center">
  <a href="https://apps.apple.com/us/app/keeforge/id6759309295">
    <img alt="App Store でダウンロード" src="https://img.shields.io/badge/App%20Store-Download-0D96F6?style=for-the-badge&logo=appstore&logoColor=white" />
  </a>
  <a href="https://testflight.apple.com/join/mPAT4f1a">
    <img alt="TestFlight の公開ベータに参加" src="https://img.shields.io/badge/TestFlight-Public%20Beta-1F8AF0?style=for-the-badge&logo=apple&logoColor=white" />
  </a>
  <img alt="iOS 18.0 以降が必要" src="https://img.shields.io/badge/iOS-18.0%2B-000000?style=for-the-badge&logo=apple&logoColor=white" />
  <img alt="macOS 15.0 以降が必要" src="https://img.shields.io/badge/macOS-15.0%2B-000000?style=for-the-badge&logo=apple&logoColor=white" />
  <img alt="Swift LoC" src="https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Ftokei.kojix2.net%2Fapi%2Fgithub%2FKeeForge%2FKeeForge%2Flanguages&query=%24.data.languages.Swift.code&label=swift%20loc&color=orange&style=for-the-badge" />
  <a href="../../LICENSE">
    <img alt="ライセンス: GPLv3" src="https://img.shields.io/badge/license-GPLv3-blue?style=for-the-badge" />
  </a>
</p>

## KeeForge を選ぶ理由

KeeForge は iPhone、iPad、Mac のためのネイティブ KeePass クライアントです。ローカルファイルと WebDAV はすべてのプラットフォームで利用でき、iCloud Drive、Dropbox、OneDrive、その他の「ファイル」プロバイダは iPhone と iPad で利用できます。保管庫をホスト型サービスに預けず、マスターパスワード、キーファイル、生体認証で管理できます。

## 公開ベータ

**[TestFlight で KeeForge のベータに参加する](https://testflight.apple.com/join/mPAT4f1a)**

> [!WARNING]
> **普段お使いの保管庫ではなく、データベースのコピーでお試しください。** ベータ版は App Review を通っておらず、App Store 版と同じバンドル ID とコンテナを共有します。そのため、実際の `.kdbx` ファイルが開かれます。

## 主な特長

| 分野 | KeeForge でできること |
| --- | --- |
| **KeePass との互換性** | AES-256、ChaCha20、Twofish による暗号化と、AES-KDF、Argon2d、Argon2id に対応した KDBX 4.x データベースの読み書き。KDBX 3.1 データベースは読み取り専用で開けます。 |
| **ローカルファーストの編集** | エントリとグループの作成、編集、移動、削除。保存時には競合チェック、日時付きバックアップ、エントリ履歴と未知の XML の保持を行います。 |
| **新規データベース** | すべてのプラットフォームでローカルまたは WebDAV に作成できます。Dropbox と OneDrive は iPhone と iPad で利用できます。 |
| **複合キー** | パスワード、キーファイル、またはその両方でロックを解除。バイナリ、16 進数、XML v1/v2（`.key`/`.keyx`）、任意のキーファイルに対応します。 |
| **自動入力** | App とブラウザでのネイティブ自動入力と生体認証に加え、すべてのプラットフォームでパスキー登録に対応。QuickType と拡張機能からのパスワード項目作成は iPhone と iPad でも利用できます。 |
| **パスキー** | KeePassXC 互換のカスタムフィールドに保存された FIDO2/WebAuthn パスキーの検出と認証。 |
| **TOTP** | すべてのプラットフォームで表示、コピー、カウントダウンに対応し、iOS 18 以降と Mac では確認コードを自動入力できます。 |
| **クラウド同期** | WebDAV はすべてのプラットフォームで利用できます。Dropbox と OneDrive は現在 iPhone と iPad に対応し、Mac では同期済みフォルダをローカルファイルとして開けます。 |
| **添付ファイル** | KeePass エントリの添付ファイルの表示、対応形式の QuickLook プレビュー、保護された一時ファイル経由での共有。添付ファイルの編集にはまだ対応していません。 |
| **すべての画面でネイティブ** | iPhone の簡潔なナビゲーション、iPad の分割ワークスペース、メニュー、コマンド、Touch ID を備えたデスクトップ向けネイティブ Mac App。 |
| **セキュリティ** | AES-GCM によるメモリ内の秘密情報の暗号化、ロック解除失敗時のバックオフ、展開爆弾への上限、一定時間での HMAC 比較。 |

## プライバシー

KeeForge には、アナリティクスもバックグラウンドのテレメトリも、クラッシュレポート用の SDK もありません。保管庫のデータは、デバイス内と自分で選んだ保存先にとどまります。ネットワーク通信は、接続したクラウドプロバイダ、任意で有効にする DuckDuckGo 経由のファビコン取得、チップ用の App Store での購入（任意）、直接配布版 Mac App のアップデート確認、および自分でメッセージを送信したときの App 内フィードバックフォームに限られます。

iPhone と iPad では、コピーした秘密情報はローカル専用としてマークされ、ユニバーサルクリップボードには流れません。macOS にはこの除外機能がないため、Mac ではシステム設定に従って同期される場合があります。KeeForge は内容を秘匿扱いにし、短時間後またはロック時に消去します。さらに iPhone と iPad の App スイッチャー表示を保護します。Mac の画面キャプチャ防止はベストエフォートであり、すべてのスクリーンショットや録画を防げるとは限りません。

[プライバシーポリシー](https://keeforge.com/privacy)をご覧ください。

## データの安全性

KeeForge はデータの安全性を非常に重視しています。パスワードマネージャは、保管庫を壊したり、その一部を気づかないうちに失ったりしてはなりません。変更がリリースされる前に、次の点を自動テストで検証しています。

- **保存しても何も失われないこと。** あらゆる種類の編集を保存し、1 つずつ読み戻します。パスワード、メモ、添付ファイル、エントリ履歴、さらには KeeForge が認識しない他の KeePass App のデータも、すべて入力したとおりに戻る必要があります。
- **ファイルに手を加える前に保護されること。** KeeForge は、ファイルを開いている間に他の場所から加えられた変更を上書きすることを拒否し、保存のたびに日時付きのバックアップを作成し、破損したデータベースは部分的に読み込むのではなく、はっきりと拒否します。
- **独立したプログラムでも結果が一致すること。** 各リリースは、KeeForge とコードを共有しない広く使われている KeePass App の KeePassXC が、KeeForge の書き出したデータベースを開き、パスワードを復号し、添付ファイルがビット単位で一致することを確認するゲートに合格しなければなりません。他の KeePass ソフトウェアで作成されたデータベースも同様に KeeForge で開け、KeeForge で保存したあとも他のソフトウェアで読めることが求められます。

技術的な詳細に関心のある方向けに、テストスイートの構成は [`KeeForgeTests/AGENTS.md`](../../KeeForgeTests/AGENTS.md) に、リリース前の検証ゲートは [`ci_scripts/README.md`](../../ci_scripts/README.md) にまとめられています。

## プロジェクトの構成

```text
KeeForge/
├── App/              # App のエントリポイント、可変のルートシェル、シーンのライフサイクル
├── Extensions/       # 共有のプラットフォーム互換ヘルパー
├── Models/           # KDBX のパーサ/ライタ、暗号処理、編集ドラフト、TOTP、パスキー
├── Resources/        # 文字列カタログとアセットカタログ
├── Services/         # 永続化、クラウド同期、キーチェーン、ブックマーク、添付ファイル、自動入力のヘルパー
├── ViewModels/       # データベース一覧、ロック解除、保存、検索、並べ替え、TOTP の状態
├── Views/            # SwiftUI の画面、エディタ、設定、チップ、再利用可能なコントロール
AutoFillExtension/    # 自動入力の資格情報プロバイダ、パスキー認証、認証情報の作成
KeeForgeMac/          # ネイティブ macOS App（初回リリースを準備中）
KeeForgeMacUITests/   # macOS App の XCUITest カバレッジ
KeeForgeTests/        # ユニットテスト
KeeForgeUITests/      # XCUITest カバレッジ
TestFixtures/         # サンプルの .kdbx データベースとキーファイル
Vendor/               # 同梱の KeeForgeTwofish Swift パッケージ
ci_scripts/           # Xcode Cloud のブートストラップとリリースゲートのスクリプト
scripts/              # ローカル開発用ツール
```

## ドキュメント

- [`CHANGELOG.md`](../../CHANGELOG.md) - バージョン履歴
- [`ROADMAP.md`](../../ROADMAP.md) - 予定している開発内容と現在の優先事項
- [`AGENTS.md`](../../AGENTS.md) - コーディングエージェント向けのコンテキスト
- [`KeeForge/README.md`](../../KeeForge/README.md) - App ターゲットのアーキテクチャ図
- [`AutoFillExtension/AGENTS.md`](../../AutoFillExtension/AGENTS.md) - 拡張機能の制約と共有ソースに関する注記
- [`SECURITY.md`](../../SECURITY.md) - 脆弱性の開示方針
- [`docs/`](../../docs/) - 実装仕様、監査結果、詳細な設計ドキュメント

この README と [`CONTRIBUTING.ja.md`](CONTRIBUTING.ja.md) を除き、開発者向けドキュメントは英語のみで管理されています。

## サポート

- App Store: [App Store の KeeForge](https://apps.apple.com/us/app/keeforge/id6759309295)
- メール: [support@keeforge.com](mailto:support@keeforge.com)
- 不具合の報告: [GitHub Issues](https://github.com/KeeForge/KeeForge/issues)

## 貢献する

ビルドの要件、ソースからのビルド方法、プルリクエストの進め方、Developer Certificate of Origin の署名要件、ライセンス条項については [`CONTRIBUTING.ja.md`](CONTRIBUTING.ja.md) をご覧ください。まず [`AGENTS.md`](../../AGENTS.md) を読み、次に変更するコードに最も近いフォルダ内の `README.md` を開いてください。

## ライセンス

KeeForge は GPLv3 ライセンスで提供されています。詳細は [`LICENSE`](../../LICENSE) をご覧ください。
