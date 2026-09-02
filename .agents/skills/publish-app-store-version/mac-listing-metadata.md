# KeeForge Mac App Store listing and reviewer metadata

Package 9 local preparation record. This file is a paste-ready draft, not an
App Store Connect write. It was prepared 2026-09-02 while the ASC UI was
locked; do not mark package 9 complete until every field is verified and saved
on the Mac version page.

## Source of truth and scope

- The native Mac target is currently `MARKETING_VERSION: 1.15.0` and
  `CURRENT_PROJECT_VERSION: 2` in `project.yml`. The final version/build must
  come from the release handoff, not this draft.
- `KeeForgeMac/README.md` says the native Mac release supports local files and
  WebDAV. Its cloud OAuth surface deliberately excludes Dropbox and OneDrive.
  Do not copy the broader iOS README's Dropbox/OneDrive claims into the Mac
  listing.
- `KeeForgeMac/Info.plist` declares `ITSAppUsesNonExemptEncryption` as
  `false`, `LSApplicationCategoryType` as
  `public.app-category.utilities`, and the `otpauth` URL scheme. It has no
  Dropbox or OneDrive URL schemes or client-ID keys.
- The repository-known privacy URL is
  `https://keeforge.com/privacy`. The repository-known contact is
  `support@keeforge.com`; no dedicated support-page URL is established here.
  Never invent one or use the privacy URL as a support URL without confirmation.
- In-app shipped locales are English, German, French, Spanish, Simplified
  Chinese, and Traditional Chinese. The last-known ASC locale set for this
  listing is English (U.S.), French, German, Russian, and Spanish (Spain).
  Treat the Chinese drafts below as additions pending ASC confirmation; treat
  the ASC page as the source of truth for what must be saved.
- This is listing copy for the native macOS product. It must not imply that
  Dropbox or OneDrive work on Mac, that WebDAV is required, or that a user must
  sign in.

## English (U.S.) — exact copy ready to paste

Use these values only after confirming the corresponding field and locale on
the Mac version page.

**App name** (30-character limit):

```text
KeeForge
```

**Subtitle** (30-character limit):

```text
KeePass vault for Mac
```

**Promotional text** (170-character limit):

```text
A native KeePass manager for Mac: open local KDBX files, connect optional WebDAV, and use AutoFill—without a hosted password account.
```

**Description** (4,000-character limit):

```text
Keep your KeePass vault close. KeeForge is a native macOS app for opening and editing KDBX databases stored in local files and connecting to WebDAV servers you choose.

Unlock with a master password, key file, or both, with Touch ID when available. Search and edit entries and groups, create strong passwords, view attachments, use TOTP codes, and fill credentials with AutoFill. Passkey entries stored in the KeePassXC-compatible format are supported.

Your vault stays in the storage locations you choose. KeeForge has no analytics, background telemetry, or crash-reporting SDKs. WebDAV is optional—no account or sign-in is required to use local files.

The first native Mac release does not connect to Dropbox or OneDrive. To use a database, open its local KDBX file from Finder or another file location, or optionally connect a WebDAV server. To enable AutoFill, open System Settings → General → AutoFill & Passwords and enable KeeForge.
```

**Keywords** (100-byte limit; commas only, no spaces around commas):

```text
KeePass,KDBX,password,AutoFill,WebDAV,TOTP,passkeys,security
```

**Copyright / support / privacy:**

```text
Copyright: [ASC VERIFY: existing copyright value; do not invent]
Support URL: [ASC VERIFY: existing HTTPS support URL; repo only confirms support@keeforge.com]
Privacy Policy URL: https://keeforge.com/privacy
```

### English reviewer notes — exact copy ready to paste

```text
Reviewing KeeForge for Mac does not require an account or sign-in. The attached test.kdbx.zip is a compressed test database. Unzip it, then in KeeForge choose File → Open Database… and select test.kdbx; unlock with the database password testpassword123.

To test AutoFill, open System Settings → General → AutoFill & Passwords and enable KeeForge, then use Safari or another supported app. The Mac version supports local files and optional WebDAV connections. Dropbox and OneDrive are not available in the native Mac version. WebDAV testing is optional and requires a tester-provided server; no server or account is required for local-file testing.
```

## Faithful listing drafts for each locale

These are translation drafts, not evidence that ASC currently offers or
requires each locale. Keep product terms such as KeeForge, KeePass, KDBX,
AutoFill, WebDAV, TOTP, and passkeys recognizable. The English copy above is
the paste-ready source; have a human review any translation before saving.

### fr — last-known ASC locale

**Subtitle:** `Coffre KeePass pour Mac`

**Promotional text:**

```text
Un gestionnaire KeePass natif pour Mac : ouvrez des fichiers KDBX locaux, connectez un WebDAV facultatif et utilisez AutoFill, sans compte de mots de passe hébergé.
```

**Description:**

```text
Gardez votre coffre KeePass à portée de main. KeeForge est une app macOS native pour ouvrir et modifier des bases KDBX stockées dans des fichiers locaux et se connecter aux serveurs WebDAV de votre choix.

Déverrouillez avec un mot de passe principal, un fichier de clé ou les deux, avec Touch ID si disponible. Recherchez et modifiez les entrées et les groupes, créez des mots de passe robustes, consultez les pièces jointes, utilisez les codes TOTP et remplissez vos identifiants avec AutoFill. Les entrées de passkey au format compatible KeePassXC sont prises en charge.

Votre coffre reste dans les emplacements de stockage que vous choisissez. KeeForge n'intègre ni analyse, ni télémétrie en arrière-plan, ni SDK de rapports de crash. WebDAV est facultatif : aucun compte ni aucune connexion n'est nécessaire pour utiliser des fichiers locaux.

La première version native pour Mac ne se connecte pas à Dropbox ni à OneDrive. Pour activer AutoFill, ouvrez Réglages Système → Général → Remplissage automatique et mots de passe, puis activez KeeForge.
```

**Keywords:** `KeePass,KDBX,mot de passe,AutoFill,WebDAV,TOTP,passkeys,sécurité`

### de — last-known ASC locale

**Subtitle:** `KeePass-Tresor für Mac`

**Promotional text:**

```text
Ein nativer KeePass-Manager für den Mac: lokale KDBX-Dateien öffnen, optional WebDAV verbinden und AutoFill nutzen – ohne gehostetes Passwortkonto.
```

**Description:**

```text
Ihr KeePass-Tresor bleibt griffbereit. KeeForge ist eine native macOS-App zum Öffnen und Bearbeiten von KDBX-Datenbanken in lokalen Dateien und zum Verbinden mit WebDAV-Servern Ihrer Wahl.

Entsperren Sie mit einem Hauptpasswort, einer Schlüsseldatei oder beidem, mit Touch ID, sofern verfügbar. Suchen und bearbeiten Sie Einträge und Gruppen, erstellen Sie starke Passwörter, zeigen Sie Anhänge an, verwenden Sie TOTP-Codes und füllen Sie Zugangsdaten mit AutoFill aus. Passkey-Einträge im KeePassXC-kompatiblen Format werden unterstützt.

Ihr Tresor bleibt an den von Ihnen gewählten Speicherorten. KeeForge enthält keine Analyse, Telemetrie im Hintergrund oder SDKs zur Absturzberichterstattung. WebDAV ist optional – für lokale Dateien ist kein Konto und keine Anmeldung erforderlich.

Die erste native Mac-Version verbindet sich nicht mit Dropbox oder OneDrive. Für AutoFill öffnen Sie Systemeinstellungen → Allgemein → Automatisches Ausfüllen & Passwörter und aktivieren KeeForge.
```

**Keywords:** `KeePass,KDBX,Passwort,AutoFill,WebDAV,TOTP,Passkeys,Sicherheit`

### ru — last-known ASC locale

**Subtitle:** `KeePass-хранилище для Mac`

**Promotional text:**

```text
Нативный KeePass-менеджер для Mac: открывайте локальные файлы KDBX, подключайте WebDAV по желанию и используйте AutoFill без учётной записи.
```

**Description:**

```text
Держите хранилище KeePass под рукой. KeeForge — нативное приложение macOS для открытия и редактирования баз KDBX в локальных файлах и подключения к выбранным вами серверам WebDAV.

Разблокируйте базу мастер-паролем, файлом ключа или обоими способами; при наличии доступен Touch ID. Ищите и редактируйте записи и группы, создавайте надёжные пароли, просматривайте вложения, используйте коды TOTP и заполняйте данные через AutoFill. Поддерживаются записи passkey в формате, совместимом с KeePassXC.

Ваше хранилище остаётся в выбранных вами местах хранения. В KeeForge нет аналитики, фоновой телеметрии и SDK для отчётов о сбоях. WebDAV необязателен — для локальных файлов не нужны учётная запись и вход.

Первая нативная версия для Mac не подключается к Dropbox или OneDrive. Чтобы включить AutoFill, откройте Системные настройки → Основные → Автозаполнение и пароли и включите KeeForge.
```

**Keywords:** `KeePass,KDBX,пароль,AutoFill,WebDAV,TOTP,passkey,безопасность`

### es-ES — last-known ASC locale

**Subtitle:** `Bóveda KeePass para Mac`

**Promotional text:**

```text
Un gestor KeePass nativo para Mac: abre archivos KDBX locales, conecta WebDAV opcional y usa AutoFill sin una cuenta de contraseñas alojada.
```

**Description:**

```text
Ten tu bóveda KeePass siempre a mano. KeeForge es una app nativa para macOS que abre y edita bases de datos KDBX guardadas en archivos locales y se conecta a servidores WebDAV que elijas.

Desbloquea con una contraseña maestra, un archivo de clave o ambos, y usa Touch ID cuando esté disponible. Busca y edita entradas y grupos, crea contraseñas seguras, consulta archivos adjuntos, usa códigos TOTP y completa credenciales con AutoFill. Se admiten entradas passkey en el formato compatible con KeePassXC.

Tu bóveda permanece en las ubicaciones de almacenamiento que elijas. KeeForge no incluye analítica, telemetría en segundo plano ni SDK de informes de fallos. WebDAV es opcional: no necesitas una cuenta ni iniciar sesión para usar archivos locales.

La primera versión nativa para Mac no se conecta a Dropbox ni OneDrive. Para activar AutoFill, abre Ajustes del Sistema → General → Autorrelleno y contraseñas y activa KeeForge.
```

**Keywords:** `KeePass,KDBX,contraseña,AutoFill,WebDAV,TOTP,passkeys,seguridad`

### zh-Hans — addition pending ASC confirmation

**Subtitle:** `Mac 上的 KeePass 密库`

**Promotional text:**

```text
适用于 Mac 的原生 KeePass 管理器：打开本地 KDBX 文件，可选连接 WebDAV，并使用 AutoFill，无需托管密码账户。
```

**Description:**

```text
随时使用您的 KeePass 密库。KeeForge 是原生 macOS 应用，可打开和编辑保存在本地文件中的 KDBX 数据库，也可连接您选择的 WebDAV 服务器。

您可以使用主密码、密钥文件或两者解锁；设备支持时可使用 Touch ID。搜索和编辑条目及分组，生成强密码，查看附件，使用 TOTP 验证码，并通过 AutoFill 填充凭据。支持 KeePassXC 兼容格式的 passkey 条目。

密库始终保存在您选择的存储位置。KeeForge 不包含分析、后台遥测或崩溃报告 SDK。WebDAV 为可选功能：使用本地文件不需要账户或登录。

首个原生 Mac 版本不连接 Dropbox 或 OneDrive。要启用 AutoFill，请打开系统设置 → 通用 → 自动填充与密码，然后启用 KeeForge。
```

**Keywords:** `KeePass,KDBX,密码,AutoFill,WebDAV,TOTP,passkey,安全`

### zh-Hant — addition pending ASC confirmation

**Subtitle:** `Mac 上的 KeePass 保管庫`

**Promotional text:**

```text
適用於 Mac 的原生 KeePass 管理器：開啟本機 KDBX 檔案、選擇性連接 WebDAV，並使用 AutoFill，無需託管密碼帳戶。
```

**Description:**

```text
隨時使用您的 KeePass 保管庫。KeeForge 是原生 macOS App，可開啟及編輯儲存在本機檔案中的 KDBX 資料庫，也可連接您選擇的 WebDAV 伺服器。

您可以使用主密碼、金鑰檔案或兩者解鎖；裝置支援時可使用 Touch ID。搜尋及編輯項目與群組、建立強密碼、檢視附件、使用 TOTP 驗證碼，並透過 AutoFill 填入憑證。支援 KeePassXC 相容格式的 passkey 項目。

保管庫會留在您選擇的儲存位置。KeeForge 不包含分析、背景遙測或當機報告 SDK。WebDAV 是選用功能：使用本機檔案不需要帳戶或登入。

首個原生 Mac 版本不連接 Dropbox 或 OneDrive。若要啟用 AutoFill，請開啟系統設定 → 一般 → 自動填寫與密碼，然後啟用 KeeForge。
```

**Keywords:** `KeePass,KDBX,密碼,AutoFill,WebDAV,TOTP,passkey,安全`

## Reviewer-note translations (faithful drafts)

The English note is the ready-to-paste operational source. These translations
preserve the fixture path, password, platform limitation, optional WebDAV, and
the exact AutoFill settings path; do not change those facts during translation.

### fr

```text
L’examen de KeeForge pour Mac ne nécessite ni compte ni connexion. La pièce jointe test.kdbx.zip est une base de test compressée. Décompressez-la, puis dans KeeForge choisissez Fichier → Ouvrir la base de données… et sélectionnez test.kdbx ; déverrouillez-la avec le mot de passe testpassword123.

Pour tester AutoFill, ouvrez Réglages Système → Général → Remplissage automatique et mots de passe et activez KeeForge, puis utilisez Safari ou une autre app prise en charge. La version Mac prend en charge les fichiers locaux et les connexions WebDAV facultatives. Dropbox et OneDrive ne sont pas disponibles dans la version native pour Mac. Le test WebDAV est facultatif et nécessite un serveur fourni par le testeur ; aucun serveur ni compte n’est nécessaire pour tester les fichiers locaux.
```

### de

```text
Für die Prüfung von KeeForge für Mac ist kein Konto und keine Anmeldung erforderlich. Der Anhang test.kdbx.zip ist eine komprimierte Testdatenbank. Entpacken Sie ihn, wählen Sie in KeeForge Datei → Datenbank öffnen… und dann test.kdbx; entsperren Sie die Datenbank mit dem Passwort testpassword123.

Zum Testen von AutoFill öffnen Sie Systemeinstellungen → Allgemein → Automatisches Ausfüllen & Passwörter, aktivieren KeeForge und verwenden Sie anschließend Safari oder eine andere unterstützte App. Die Mac-Version unterstützt lokale Dateien und optionale WebDAV-Verbindungen. Dropbox und OneDrive sind in der nativen Mac-Version nicht verfügbar. Der WebDAV-Test ist optional und benötigt einen vom Tester bereitgestellten Server; für lokale Dateien sind weder Server noch Konto erforderlich.
```

### ru

```text
Для проверки KeeForge для Mac учётная запись и вход не требуются. Во вложении находится сжатая тестовая база test.kdbx.zip. Распакуйте её, затем в KeeForge выберите «Файл» → «Открыть базу данных…», укажите test.kdbx и разблокируйте базу паролем testpassword123.

Чтобы проверить AutoFill, откройте Системные настройки → Основные → Автозаполнение и пароли, включите KeeForge и используйте Safari или другое поддерживаемое приложение. Версия для Mac поддерживает локальные файлы и необязательные подключения WebDAV. Dropbox и OneDrive недоступны в нативной версии для Mac. Проверка WebDAV необязательна и требует сервера тестировщика; для проверки локальных файлов сервер и учётная запись не нужны.
```

### es-ES

```text
La revisión de KeeForge para Mac no requiere cuenta ni inicio de sesión. El archivo adjunto test.kdbx.zip es una base de datos de prueba comprimida. Descomprímelo, abre KeeForge, elige Archivo → Abrir base de datos… y selecciona test.kdbx; desbloquéala con la contraseña testpassword123.

Para probar AutoFill, abre Ajustes del Sistema → General → Autorrelleno y contraseñas, activa KeeForge y usa Safari u otra app compatible. La versión para Mac admite archivos locales y conexiones WebDAV opcionales. Dropbox y OneDrive no están disponibles en la versión nativa para Mac. La prueba de WebDAV es opcional y requiere un servidor proporcionado por el evaluador; para probar archivos locales no se necesitan servidor ni cuenta.
```

### zh-Hans

```text
审核 KeeForge for Mac 不需要账户或登录。附件 test.kdbx.zip 是压缩的测试数据库。请解压，在 KeeForge 中选择“文件”→“打开数据库…”，选取 test.kdbx，并使用数据库密码 testpassword123 解锁。

要测试 AutoFill，请打开系统设置 → 通用 → 自动填充与密码，启用 KeeForge，然后使用 Safari 或其他支持的应用。Mac 版本支持本地文件和可选的 WebDAV 连接。原生 Mac 版本不提供 Dropbox 或 OneDrive。WebDAV 测试为可选项，需要测试人员提供服务器；测试本地文件不需要服务器或账户。
```

### zh-Hant

```text
審核 KeeForge for Mac 不需要帳戶或登入。附件 test.kdbx.zip 是壓縮的測試資料庫。請解壓縮，在 KeeForge 中選擇「檔案」→「開啟資料庫…」，選取 test.kdbx，並使用資料庫密碼 testpassword123 解鎖。

若要測試 AutoFill，請開啟系統設定 → 一般 → 自動填寫與密碼，啟用 KeeForge，然後使用 Safari 或其他支援的 App。Mac 版本支援本機檔案和選用的 WebDAV 連線。原生 Mac 版本不提供 Dropbox 或 OneDrive。WebDAV 測試為選用項目，需要測試人員提供伺服器；測試本機檔案不需要伺服器或帳戶。
```

## Field limits, unknowns, and do-not-invent rules

The limits above are the standard App Store Connect text limits and should be
checked against the current ASC UI before saving. Keywords are a byte limit,
not a character limit; recheck UTF-8 byte length for every translated keyword
set. If ASC displays a different limit, its UI wins.

- **Support URL:** unknown. Verify the existing Mac record or obtain an
  approved HTTPS support page. Do not fabricate a URL; the repo only establishes
  `support@keeforge.com`.
- **Privacy URL:** repo-known `https://keeforge.com/privacy`; verify that ASC
  accepts and displays it for the Mac locale/version.
- **Category:** the plist-derived category is Utilities
  (`public.app-category.utilities`). Verify the ASC primary/secondary category;
  do not infer or change it from the plist alone.
- **Age rating:** exact ASC rating answers are not established in the repo.
  Verify the existing rating and choose **Keep Existing Rating** unless the user
  explicitly directs a change. Do not invent an age rating.
- **France:** verify the current availability/compliance setting. The recorded
  export-compliance precedent in the publish skill is “No” for availability in
  France, but this draft is not authorization to change it.
- **Export compliance:** verify `ITSAppUsesNonExemptEncryption = false` resolves
  on the Mac build. If ASC asks for the legal questionnaire, use the prior
  accepted declaration only after action-time confirmation; do not silently
  save a new answer.
- **Release controls:** verify **Manually release this version** for the Mac
  record (and iOS if coordinated), and preserve the existing rating. Do not
  select automatic release.
- **Locales:** last-known ASC locales are en-US, fr, de, ru, and es-ES. Confirm
  the Mac page's actual list; zh-Hans and zh-Hant are additions pending that
  confirmation.
- **Screenshots/build:** not part of this local metadata draft. The final Mac
  screenshots and exact soaked RC build remain required before submission.

## Final RC release-notes rule (bounded template only)

Do not claim final RC release notes in this package 9 draft. At submission
time, use only the matching version heading in `CHANGELOG.md` (for example,
`## v1.15.0`), select concise user-facing changes, and translate the same
meaning into every locale ASC actually lists. Exclude `## Unreleased`, the
macOS package checklist, implementation/audit details, issue numbers unless
user-facing, and any feature not present in the exact soaked RC. Keep each
locale within ASC's current What's New limit (normally 4,000 characters).

```text
What's New in This Version (template — do not paste yet)
[Final marketing version: verify against release manifest]
- [User-facing change from the matching versioned CHANGELOG section]
- [User-facing fix or improvement from that same section]
```

## Pre-submission checklist

- [ ] Mac version page exists for the exact final marketing version; no
  duplicate version was created.
- [ ] Exact soaked Mac build is processed and attached; final RC screenshots
  are the Mac captures for that build.
- [ ] English listing copy is approved, then translated faithfully into every
  locale shown on the Mac version page.
- [ ] Support URL is verified (not invented); privacy URL is
  `https://keeforge.com/privacy` and is verified in ASC.
- [ ] Contact information is populated; reviewer note includes the attached
  `/Users/tan/Documents/test.kdbx.zip` and password `testpassword123`.
- [ ] Attachment visibly shows `test.kdbx.zip`; upload only that exact file if
  it is absent.
- [ ] Reviewer note says local files and optional WebDAV work, Dropbox and
  OneDrive are unavailable on native Mac, no sign-in is required, and AutoFill
  is enabled at System Settings → General → AutoFill & Passwords.
- [ ] Export compliance resolves as `ITSAppUsesNonExemptEncryption = false`;
  France setting is checked for consistency.
- [ ] **Manually release this version** and **Keep Existing Rating** are
  verified; no automatic release is selected.
- [ ] Final RC release notes are derived from the matching versioned changelog
  section only, and saved for every locale ASC lists.
- [ ] Add for Review is staged and reaches Ready for Review. Do not click
  Submit for Review without explicit action-time confirmation.
