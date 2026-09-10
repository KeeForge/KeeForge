# KeeForge Mac App Store listing and reviewer metadata

Package 9 record. As of 2026-09-09 this is **what is saved on the live macOS
version page**, not a draft. It was written back from App Store Connect after
saving, so the copy below matches the record byte for byte. Change it here only
alongside a matching ASC edit.

Saved state of the macOS version record (app `6759309295`, version id
`7056fb7a-8e4a-4485-b816-5c04fbe09088`):

- Version `1.16.0`, state `PREPARE_FOR_SUBMISSION`, release type `MANUAL`.
- Copyright `© 2026 Jia Tan`; Support URL
  `https://github.com/KeeForge/KeeForge?tab=readme-ov-file#support`; Marketing
  URL `https://keeforge.com/` — all seven locales.
- Reviewer contact populated, **Sign-in required** off, reviewer notes saved,
  attachment `test.kdbx.zip` uploaded.
- Locales exposed on the Mac page: en-US (primary), zh-Hans, zh-Hant, fr, de,
  ru, es-ES — exactly the iOS set.
- Still empty by design: `What's New in This Version` (package 14, from the
  matching `## v{version}` changelog section), screenshots (package 11), and
  the attached build (package 10).

## Source of truth and scope

- The final version/build comes from the release handoff. `project.yml` carries
  `MARKETING_VERSION: 1.16.0` / `CURRENT_PROJECT_VERSION: 4`; the version record
  was corrected from the auto-created 1.15.0 because the iOS 1.15.0 train is
  closed.
- `KeeForgeMac/README.md` and `CloudSyncModels.isAvailableOnCurrentPlatform`
  agree: the native Mac release supports local files and WebDAV, and hides
  Dropbox/OneDrive. The listing must not imply otherwise.
- `KeeForgeMac/Info.plist` declares `ITSAppUsesNonExemptEncryption=false`,
  `LSApplicationCategoryType=public.app-category.utilities`, and the `otpauth`
  URL scheme.
- Name, Subtitle, Category and Age Rating are **app-level and shared with iOS**
  (App Information, "Any changes will be released with your next app version").
  There is no Mac-specific subtitle to write. Current values: name
  `KeeForge: KeePass Manager`, subtitle `Native Password Vault`, categories
  Productivity / Utilities, age rating 4+ in 172 regions with Brazil/Korea/
  Vietnam variants. Preserve them; choose **Keep Existing Rating**.
- Availability is 175 countries including France, base country United States.
- The macOS platform is on the record, which *is* the universal purchase; Apple
  offers no separate toggle and a platform cannot be removed once added.
- The listing copy mirrors each locale's own shipped iOS description structure,
  with every iOS-only claim corrected: Touch ID for Face ID, local files and
  WebDAV for iCloud/Dropbox/OneDrive, the System Settings AutoFill path for the
  QuickType bar, screen-capture blocking for screen-recording blur, and clipboard
  clearing for Universal Clipboard. The stale `github.com/crazytan/KeeForge`
  support URL that four iOS locales still carry was **not** copied over; every
  Mac locale uses `github.com/KeeForge/KeeForge`.

## English (U.S.) — saved

**Promotional text** (157/170):

```text
A native Mac password manager for KeePass databases. Open local .kdbx files or connect WebDAV, AutoFill with Touch ID, and keep every secret on your own Mac.
```

**Description** (2,125/4,000):

```text
KeeForge is a native macOS password manager for KeePass (.kdbx) databases. Open vaults from local files or a WebDAV server you choose. AutoFill passwords, passkeys, and TOTP codes with Touch ID. No accounts, no tracking, no subscription — fully open source under GPLv3.

Why KeeForge:
- Native Mac app built in Swift — not a web wrapper
- Your vault stays encrypted on your Mac; we never see it
- Zero accounts, zero telemetry, zero ads
- Compatible with KeePassXC, KeePass 2.x, KeePassium, and Strongbox

Vault Management
- Open .kdbx databases from anywhere in Finder, or from a WebDAV server
- Manage multiple databases from one window with Quick Launch
- Create new KDBX 4.x databases locally or on WebDAV
- Browse groups and entries with instant search

Editing & Saving
- Create, edit, and delete entries with built-in password generation
- Autosave with timestamped backups and save-conflict detection
- Entry history, unknown fields, and third-party extensions preserved — no data loss when round-tripping with KeePassXC or other clients
- Read-only mode for shared databases

AutoFill
- AutoFill passwords, passkeys, and TOTP codes in Safari and other apps
- Turn it on in System Settings > General > AutoFill & Passwords
- Save new credentials directly from AutoFill

Security
- Touch ID unlock with an auto-lock inactivity timer
- Key file support — all KeePass formats (.key, .keyx, binary, hex)
- Screen capture blocking keeps your vault out of screenshots and recordings
- Exponential lockout after failed unlock attempts
- Argon2 KDF, AES-GCM in-memory encryption of secrets
- Clipboard clears automatically and never leaves this Mac

Open Source
- Fully open source under GPLv3
- Source on GitHub: github.com/KeeForge/KeeForge
- No network calls except your own WebDAV server, optional website icon lookup, and the optional in-app feedback form

This first Mac release opens local files and connects to WebDAV. Dropbox and OneDrive are not available on Mac yet — open your synced folder as a local file instead.

Tip jar available if you'd like to support development. No subscription, no accounts, no upsell.
```

**Keywords** (90/100):

```text
kdbx,totp,2fa,passkey,fido2,touchid,otp,offline,encrypted,sync,webdav,strongbox,keepassium
```

`keepass` is omitted deliberately — the app name already carries it, and the
approved iOS en-US set omits it for the same reason. `faceid`, `icloud` and
`onedrive` were dropped as untrue on Mac.

### English reviewer notes — saved

```text
Reviewing KeeForge for Mac does not require an account or sign-in. The attached test.kdbx.zip is a compressed test database. Unzip it, then in KeeForge choose File > Open Database... and select test.kdbx; unlock it with the password testpassword123.

To test AutoFill, open System Settings > General > AutoFill & Passwords and enable KeeForge, then use Safari or another app. The Mac version supports local files and optional WebDAV connections; Dropbox and OneDrive are not available in the Mac version. WebDAV testing is optional and needs a server you provide — no server or account is required to test local files.
```

The reviewer note is one field on the version record, shared by every locale;
ASC does not offer a per-locale reviewer note.

## fr — saved

**Promotional text:**

```text
Un gestionnaire KeePass natif pour Mac : ouvrez des fichiers .kdbx locaux ou connectez WebDAV, remplissez avec Touch ID, et gardez chaque secret sur votre Mac.
```

**Description:**

```text
KeeForge est un gestionnaire de mots de passe macOS natif pour les bases KeePass (.kdbx). Ouvrez des coffres depuis des fichiers locaux ou un serveur WebDAV de votre choix. Remplissez automatiquement les mots de passe, passkeys et codes TOTP avec Touch ID. Aucun compte, aucun suivi, aucun abonnement - entièrement open source sous GPLv3.

Pourquoi KeeForge :
- Application Mac native développée en Swift - pas un habillage web
- Votre coffre reste chiffré sur votre Mac ; nous ne le voyons jamais
- Aucun compte, aucune télémétrie, aucune publicité
- Compatible avec KeePassXC, KeePass 2.x, KeePassium et Strongbox

Gestion des coffres
- Ouvrez des bases .kdbx depuis n'importe quel emplacement du Finder ou depuis un serveur WebDAV
- Gérez plusieurs bases dans une seule fenêtre avec le lancement rapide
- Créez de nouvelles bases KDBX 4.x en local ou sur WebDAV
- Parcourez groupes et entrées avec une recherche instantanée

Modification et sauvegarde
- Créez, modifiez et supprimez des entrées avec un générateur de mots de passe intégré
- Sauvegarde automatique avec copies horodatées et détection des conflits
- Historique des entrées, champs inconnus et extensions tierces conservés - pas de perte de données lors des allers-retours avec KeePassXC ou d'autres clients
- Mode lecture seule pour les bases partagées

AutoFill
- Remplissez automatiquement mots de passe, passkeys et codes TOTP dans Safari et les autres apps
- Activez-le dans Réglages Système > Général > Remplissage automatique et mots de passe
- Enregistrez de nouveaux identifiants directement depuis AutoFill

Sécurité
- Déverrouillage Touch ID avec verrouillage automatique après inactivité
- Prise en charge des fichiers clé - tous les formats KeePass (.key, .keyx, binaire, hex)
- Le blocage de capture d'écran garde votre coffre hors des captures et des enregistrements
- Verrouillage exponentiel après échecs de déverrouillage
- KDF Argon2 et chiffrement AES-GCM des secrets en mémoire
- Le presse-papiers s'efface automatiquement et ne quitte jamais ce Mac

Open Source
- Entièrement open source sous GPLv3
- Code source sur GitHub : github.com/KeeForge/KeeForge
- Aucun appel réseau sauf vers votre propre serveur WebDAV, la recherche facultative d'icônes de sites et le formulaire de commentaires optionnel dans l'app

Cette première version Mac ouvre des fichiers locaux et se connecte à WebDAV. Dropbox et OneDrive ne sont pas encore disponibles sur Mac - ouvrez plutôt votre dossier synchronisé comme un fichier local.

Un pourboire est disponible si vous souhaitez soutenir le développement. Aucun abonnement, aucun compte, aucune vente forcée.
```

**Keywords:** `kdbx,keepass,motdepasse,totp,2fa,passkey,fido2,touchid,otp,horsligne,chiffré,sync,webdav`

## de — saved

**Promotional text:**

```text
Ein nativer KeePass-Manager für den Mac: lokale .kdbx-Dateien öffnen, optional WebDAV verbinden, mit Touch ID ausfüllen - alle Geheimnisse bleiben auf deinem Mac.
```

**Description:**

```text
KeeForge ist ein nativer macOS-Passwortmanager für KeePass-Datenbanken (.kdbx). Öffne Tresore aus lokalen Dateien oder von einem WebDAV-Server deiner Wahl. Fülle Passwörter, Passkeys und TOTP-Codes per Touch ID automatisch aus. Keine Konten, kein Tracking, kein Abo - vollständig Open Source unter GPLv3.

Warum KeeForge:
- Native Mac-App, in Swift entwickelt - kein Web-Wrapper
- Dein Tresor bleibt verschlüsselt auf deinem Mac; wir sehen ihn nie
- Keine Konten, keine Telemetrie, keine Werbung
- Kompatibel mit KeePassXC, KeePass 2.x, KeePassium und Strongbox

Tresorverwaltung
- Öffne .kdbx-Datenbanken von überall im Finder oder von einem WebDAV-Server
- Verwalte mehrere Datenbanken in einem Fenster mit Schnellstart
- Erstelle neue KDBX-4.x-Datenbanken lokal oder auf WebDAV
- Durchsuche Gruppen und Einträge sofort

Bearbeiten & Speichern
- Erstelle, bearbeite und lösche Einträge mit integriertem Passwortgenerator
- Automatisches Speichern mit zeitgestempelten Backups und Erkennung von Speicherkonflikten
- Eintragsverlauf, unbekannte Felder und Erweiterungen von Drittanbietern bleiben erhalten - kein Datenverlust beim Roundtrip mit KeePassXC oder anderen Clients
- Schreibgeschützter Modus für gemeinsam genutzte Datenbanken

AutoFill
- Fülle Passwörter, Passkeys und TOTP-Codes in Safari und anderen Apps automatisch aus
- Aktiviere es in Systemeinstellungen > Allgemein > Automatisches Ausfüllen & Passwörter
- Speichere neue Zugangsdaten direkt aus AutoFill

Sicherheit
- Entsperren mit Touch ID und automatischer Sperre bei Inaktivität
- Schlüsseldatei-Unterstützung - alle KeePass-Formate (.key, .keyx, binär, hex)
- Der Schutz vor Bildschirmaufnahmen hält deinen Tresor aus Screenshots und Aufzeichnungen heraus
- Exponentielle Sperre nach fehlgeschlagenen Entsperrversuchen
- Argon2-KDF, AES-GCM-Verschlüsselung von Geheimnissen im Arbeitsspeicher
- Die Zwischenablage wird automatisch geleert und verlässt diesen Mac nie

Open Source
- Vollständig Open Source unter GPLv3
- Quellcode auf GitHub: github.com/KeeForge/KeeForge
- Keine Netzwerkaufrufe außer zu deinem eigenen WebDAV-Server, der optionalen Website-Icon-Suche und dem optionalen Feedbackformular in der App

Diese erste Mac-Version öffnet lokale Dateien und verbindet sich mit WebDAV. Dropbox und OneDrive sind auf dem Mac noch nicht verfügbar - öffne stattdessen deinen synchronisierten Ordner als lokale Datei.

Eine Trinkgeld-Option ist verfügbar, wenn du die Entwicklung unterstützen möchtest. Kein Abo, keine Konten, kein Upselling.
```

**Keywords:** `kdbx,keepass,passwort,totp,2fa,passkey,fido2,touchid,otp,offline,verschlüsselt,sync,webdav`

## ru — saved

**Promotional text:**

```text
Нативный менеджер паролей KeePass для Mac: открывайте локальные файлы .kdbx или подключайте WebDAV, заполняйте с Touch ID — все секреты остаются на вашем Mac.
```

**Description:**

```text
KeeForge - нативный менеджер паролей для macOS для баз данных KeePass (.kdbx). Открывайте хранилища из локальных файлов или с выбранного вами сервера WebDAV. Автоматически заполняйте пароли, passkeys и TOTP-коды с Touch ID. Без аккаунтов, без отслеживания, без подписки - полностью open source под GPLv3.

Почему KeeForge:
- Нативное приложение для Mac, написано на Swift - не веб-обертка
- Ваше хранилище остается зашифрованным на вашем Mac; мы его никогда не видим
- Никаких аккаунтов, телеметрии и рекламы
- Совместимо с KeePassXC, KeePass 2.x, KeePassium и Strongbox

Управление хранилищами
- Открывайте базы .kdbx из любого места в Finder или с сервера WebDAV
- Управляйте несколькими базами в одном окне с быстрым запуском
- Создавайте новые базы KDBX 4.x локально или на WebDAV
- Просматривайте группы и записи с мгновенным поиском

Редактирование и сохранение
- Создавайте, редактируйте и удаляйте записи со встроенным генератором паролей
- Автосохранение с резервными копиями по времени и обнаружением конфликтов
- История записей, неизвестные поля и сторонние расширения сохраняются - без потери данных при обмене с KeePassXC и другими клиентами
- Режим только для чтения для общих баз

AutoFill
- Автоматически заполняйте пароли, passkeys и TOTP-коды в Safari и других приложениях
- Включите его в Системных настройках > Основные > Автозаполнение и пароли
- Сохраняйте новые учетные данные прямо из AutoFill

Безопасность
- Разблокировка Touch ID и автоблокировка при неактивности
- Поддержка ключевых файлов - все форматы KeePass (.key, .keyx, binary, hex)
- Блокировка снимков экрана не дает хранилищу попасть в скриншоты и записи
- Экспоненциальная блокировка после неудачных попыток разблокировки
- KDF Argon2 и AES-GCM-шифрование секретов в памяти
- Буфер обмена очищается автоматически и никогда не покидает этот Mac

Open Source
- Полностью open source под GPLv3
- Исходный код на GitHub: github.com/KeeForge/KeeForge
- Сетевых запросов нет, кроме вашего сервера WebDAV, необязательного поиска значков сайтов и необязательной формы обратной связи в приложении

Эта первая версия для Mac открывает локальные файлы и подключается к WebDAV. Dropbox и OneDrive пока недоступны на Mac - откройте синхронизированную папку как обычный локальный файл.

Есть возможность оставить чаевые, если вы хотите поддержать разработку. Без подписки, без аккаунтов, без навязанных покупок.
```

**Keywords:** `kdbx,keepass,пароли,totp,2fa,passkey,fido2,touchid,otp,офлайн,sync,webdav,strongbox`

Cyrillic keywords are byte-expensive; `шифрование` was dropped to stay clear of
the limit while keeping `fido2` and `strongbox`.

## es-ES — saved

**Promotional text:**

```text
Un gestor KeePass nativo para Mac: abre archivos .kdbx locales o conecta WebDAV, rellena con Touch ID y guarda cada secreto en tu propio Mac.
```

**Description:**

```text
KeeForge es un gestor de contraseñas nativo para macOS para bases de datos KeePass (.kdbx). Abre bóvedas desde archivos locales o desde un servidor WebDAV que tú elijas. Rellena automáticamente contraseñas, passkeys y códigos TOTP con Touch ID. Sin cuentas, sin seguimiento, sin suscripción - completamente open source bajo GPLv3.

Por qué KeeForge:
- App nativa para Mac, creada en Swift - no es un envoltorio web
- Tu bóveda permanece cifrada en tu Mac; nunca la vemos
- Cero cuentas, cero telemetría, cero anuncios
- Compatible con KeePassXC, KeePass 2.x, KeePassium y Strongbox

Gestión de bóvedas
- Abre bases .kdbx desde cualquier lugar del Finder o desde un servidor WebDAV
- Gestiona varias bases en una sola ventana con inicio rápido
- Crea nuevas bases KDBX 4.x en local o en WebDAV
- Explora grupos y entradas con búsqueda instantánea

Edición y guardado
- Crea, edita y elimina entradas con generador de contraseñas integrado
- Autoguardado con copias de seguridad con fecha y detección de conflictos
- Se conservan el historial de entradas, campos desconocidos y extensiones de terceros - sin pérdida de datos al intercambiar archivos con KeePassXC u otros clientes
- Modo de solo lectura para bases compartidas

AutoFill
- Rellena contraseñas, passkeys y códigos TOTP en Safari y otras apps
- Actívalo en Ajustes del Sistema > General > Autorrelleno y contraseñas
- Guarda nuevas credenciales directamente desde AutoFill

Seguridad
- Desbloqueo con Touch ID y bloqueo automático por inactividad
- Compatibilidad con archivos clave - todos los formatos KeePass (.key, .keyx, binario, hex)
- El bloqueo de captura mantiene tu bóveda fuera de capturas y grabaciones de pantalla
- Bloqueo exponencial tras intentos fallidos de desbloqueo
- KDF Argon2 y cifrado AES-GCM de secretos en memoria
- El portapapeles se borra automáticamente y nunca sale de este Mac

Open Source
- Completamente open source bajo GPLv3
- Código fuente en GitHub: github.com/KeeForge/KeeForge
- Sin llamadas de red salvo a tu propio servidor WebDAV, la búsqueda opcional de iconos de sitios y el formulario opcional de comentarios en la app

Esta primera versión para Mac abre archivos locales y se conecta a WebDAV. Dropbox y OneDrive aún no están disponibles en Mac - abre tu carpeta sincronizada como un archivo local.

Hay una opción de propina si quieres apoyar el desarrollo. Sin suscripción, sin cuentas, sin ventas forzadas.
```

**Keywords:** `kdbx,keepass,contraseña,totp,2fa,passkey,fido2,touchid,otp,offline,cifrado,sync,webdav`

## zh-Hans — saved

**Promotional text:**

```text
适用于 Mac 的原生 KeePass 管理器：打开本地 .kdbx 文件或连接 WebDAV，使用 Touch ID 自动填充，所有密码都留在您自己的 Mac 上。
```

**Description:**

```text
KeeForge 是一款原生 macOS KeePass（.kdbx）密码管理器。可从本地文件或您选择的 WebDAV 服务器打开密码库，并通过 Touch ID 在 Safari 和各类 App 中自动填充密码、passkey 和 TOTP 验证码。无需账户、没有跟踪、没有订阅，采用 GPLv3 完全开源。

为什么选择 KeeForge
• 使用 Swift 为 Mac 原生打造，不是网页套壳
• 密码库始终在您的 Mac 上保持加密；我们无法查看其中内容
• 无账户、无遥测、无广告
• 兼容 KeePassXC、KeePass 2.x、KeePassium 和 Strongbox

密码库管理
• 支持访达中任意位置的本地文件，以及 WebDAV 服务器
• 可在单一窗口中管理多个数据库，并使用快速启动
• 可在本地或 WebDAV 中创建 KDBX 4.x 数据库
• 支持即时搜索、标签浏览及按文件夹整理

编辑与保存
• 创建、编辑和删除条目，并使用内置密码生成器
• 自动保存、时间戳备份和保存冲突检测
• 保留条目历史、未知字段和第三方扩展，确保与其他 KeePass 客户端往返编辑时不丢失数据
• 支持共享数据库的只读模式

AutoFill
• 在 Safari 和其他 App 中填充密码、passkey 与 TOTP 验证码
• 在“系统设置”→“通用”→“自动填充与密码”中启用 KeeForge
• 可直接从 AutoFill 新建凭据

安全
• Touch ID 解锁及闲置自动锁定
• 支持所有 KeePass 密钥文件格式（.key、.keyx、二进制和十六进制）
• 屏幕捕捉阻止功能让密码库不会出现在截屏和录屏中
• 多次解锁失败后采用指数退避锁定
• 使用 Argon2 KDF，并以 AES-GCM 在内存中加密敏感信息
• 剪贴板会自动清除，且绝不离开这台 Mac

开源
• 采用 GPLv3 完全开源
• 源代码：github.com/KeeForge/KeeForge
• 除您自己的 WebDAV 服务器、可选的网站图标查询和 App 内可选的反馈表单外，没有任何网络请求

首个 Mac 版本支持本地文件和 WebDAV。Mac 上暂不支持 Dropbox 和 OneDrive，请将同步文件夹中的文件作为本地文件打开。

无账户、无订阅、无推销。若您愿意支持开发，可使用小费功能。
```

**Keywords:** `密码,密码库,密码管理器,自动填充,验证码,双重验证,加密,离线,密钥文件,通行密钥,WebDAV,kdbx`

`访达` is Apple's Simplified Chinese name for Finder; Traditional Chinese keeps
"Finder" untranslated. Do not "fix" one to match the other.

## zh-Hant — saved

**Promotional text:**

```text
適用於 Mac 的原生 KeePass 管理器：開啟本機 .kdbx 檔案或連接 WebDAV，使用 Touch ID 自動填入，所有密碼都留在您自己的 Mac 上。
```

**Description:**

```text
KeeForge 是一款原生 macOS KeePass（.kdbx）密碼管理器。可從本機檔案或您選擇的 WebDAV 伺服器開啟密碼庫，並透過 Touch ID 在 Safari 和各類 App 中自動填入密碼、passkey 和 TOTP 驗證碼。無需帳號、沒有追蹤、沒有訂閱，採用 GPLv3 完全開源。

為什麼選擇 KeeForge
• 使用 Swift 為 Mac 原生打造，不是網頁套殼
• 密碼庫始終在您的 Mac 上保持加密；我們無法查看其中內容
• 無帳號、無遙測、無廣告
• 相容 KeePassXC、KeePass 2.x、KeePassium 和 Strongbox

密碼庫管理
• 支援 Finder 中任意位置的本機檔案，以及 WebDAV 伺服器
• 可在單一視窗中管理多個資料庫，並使用快速啟動
• 可在本機或 WebDAV 中建立 KDBX 4.x 資料庫
• 支援即時搜尋、標籤瀏覽及依資料夾整理

編輯與儲存
• 建立、編輯和刪除項目，並使用內建密碼產生器
• 自動儲存、時間戳記備份和儲存衝突偵測
• 保留項目歷程、未知欄位和第三方擴充，確保與其他 KeePass 用戶端往返編輯時不遺失資料
• 支援共享資料庫的唯讀模式

AutoFill
• 在 Safari 和其他 App 中填入密碼、passkey 與 TOTP 驗證碼
• 在「系統設定」→「一般」→「自動填寫與密碼」中啟用 KeeForge
• 可直接從 AutoFill 建立憑證

安全
• Touch ID 解鎖及閒置自動鎖定
• 支援所有 KeePass 金鑰檔案格式（.key、.keyx、二進位和十六進位）
• 螢幕擷取阻擋功能讓密碼庫不會出現在截圖和螢幕錄影中
• 多次解鎖失敗後採用指數退避鎖定
• 使用 Argon2 KDF，並以 AES-GCM 在記憶體中加密敏感資訊
• 剪貼簿會自動清除，且絕不離開這台 Mac

開源
• 採用 GPLv3 完全開源
• 原始碼：github.com/KeeForge/KeeForge
• 除您自己的 WebDAV 伺服器、可選的網站圖示查詢和 App 內可選的回饋表單外，沒有任何網路請求

首個 Mac 版本支援本機檔案和 WebDAV。Mac 上暫不支援 Dropbox 和 OneDrive，請將同步資料夾中的檔案作為本機檔案開啟。

無帳號、無訂閱、無推銷。若您願意支持開發，可使用小費功能。
```

**Keywords:** `密碼,密碼庫,密碼管理器,自動填入,驗證碼,雙重驗證,加密,離線,金鑰檔案,通行密鑰,WebDAV,kdbx`

## Field limits, unknowns, and do-not-invent rules

ASC counts **characters**, not UTF-8 bytes, for Keywords — CJK keyword sets are
comfortably inside 100 characters even though their byte length exceeds it.
Verify against the live counter anyway; its UI wins.

- **Export compliance:** `ITSAppUsesNonExemptEncryption = false` is declared in
  the Mac plist, but that is a build declaration. It resolves when the build is
  attached (package 10), so it is **not yet observed on this record**. If ASC
  asks a legal questionnaire or requests a document, read the exact current
  question text and the accepted iOS Build Metadata, and obtain action-time owner
  confirmation before saving. Never infer an answer from the plist, from store
  availability, or from the historical France-related "No" — the live record is
  publicly available in France and that record is context only.
- **Age rating:** choose **Keep Existing Rating**. It is app-level and shared.
- **Availability:** 175 countries including France; leave it alone.
- **Release control:** `MANUAL` is saved. Phased release for macOS is optional
  and still not chosen; do not select it without an explicit owner decision.
- **Screenshots:** none uploaded. iOS assets cannot satisfy the Mac listing;
  package 11 produces the seven 2880×1800 captures.
- **Build:** none attached. Package 10 hands over the exact soaked build.

## Final RC release-notes rule (bounded template only)

`What's New in This Version` is deliberately empty on all seven locales. At
submission time use only the matching version heading in `CHANGELOG.md` (for
example `## v1.16.0`), select concise user-facing changes, and translate the
same meaning into every locale ASC lists. Exclude `## Unreleased`, the macOS
package checklist, implementation/audit details, issue numbers unless
user-facing, and any feature not present in the exact soaked RC. Keep each
locale within ASC's current limit (normally 4,000 characters).

## Pre-submission checklist

- [x] Mac version page exists for 1.16.0; no duplicate version was created.
- [ ] Exact soaked Mac build is processed and attached; final RC screenshots are
  the Mac captures for that build.
- [x] English listing copy is saved, and translated faithfully into every locale
  shown on the Mac version page.
- [x] Support URL is verified (not the stale `crazytan` one the iOS fr/de/ru/es
  locales still carry).
- [ ] Privacy URL is verified in ASC — it lives on the App Privacy page, not the
  version page, and was not touched by package 9.
- [x] Contact information is populated; reviewer note identifies the attached
  `test.kdbx.zip` and password `testpassword123`.
- [x] Attachment visibly shows `test.kdbx.zip`.
- [x] Reviewer note says local files and optional WebDAV work, Dropbox and
  OneDrive are unavailable on native Mac, no sign-in is required, and AutoFill
  is enabled at System Settings → General → AutoFill & Passwords.
- [ ] Export compliance resolves as `ITSAppUsesNonExemptEncryption = false` once
  the build is attached; any separate legal/documentation request is handled only
  after reading the exact current question and accepted iOS Build Metadata, with
  action-time owner confirmation before saving; public France availability is
  preserved unless an explicitly confirmed legal/product decision says otherwise.
- [x] **Manually release this version** is saved. **Keep Existing Rating** is
  chosen in the submission flow, not here.
- [ ] Final RC release notes are derived from the matching versioned changelog
  section only, and saved for every locale ASC lists.
- [ ] Add for Review is staged and reaches Ready for Review. Do not click
  Submit for Review without explicit action-time confirmation.
