# KeeForge Mac App Store listing and reviewer metadata

## Current saved record — 1.17.0

This copy was read back through the App Store Connect API on 2026-10-01 after the owner approved the listing corrections. Update this record whenever the saved Mac listing changes. Read live submission status before taking an action; this file is not production-approval evidence.

- App: `6759309295`; Mac version: `72e7493a-3676-490c-be09-a5de4b13c3a1`.
- Exact Mac build: `60` (`ef25ef72-7df6-42d2-970d-631b7483d85b`), from `rc/1.17.0-b60` / `350e20545a5b8343b541cebb58df7281d3b2209a`.
- Review draft: `fa9d93fd-a55e-4777-a9ba-e1107d65fa87`, observed `READY_FOR_REVIEW`; final submission has not occurred at this snapshot.
- Release control: `MANUAL`; no phased release was selected.
- Copyright: `© 2026 Jia Tan`. All seven locales use support URL `https://github.com/KeeForge/KeeForge?tab=readme-ov-file#support` and marketing URL `https://keeforge.com/`.
- Seven inherited Mac screenshots (01–07) report `COMPLETE` in the English gallery; other locales inherit that gallery.
- Reviewer contact is populated, sign-in is not required, and `test.kdbx.zip` reports `COMPLETE`.
- Existing availability remains 175 countries including France. No availability, age-rating, privacy, pricing, or legal declaration was changed.
- Both exact b60 builds report `usesNonExemptEncryption: false`. A new legal questionnaire still requires exact-question review and action-time owner confirmation.

## Platform scope and field limits

Native Mac b60 supports local files, WebDAV, and plain FTP. Dropbox and OneDrive remain unavailable on Mac; a synced folder can be opened as local files. FTP requires explicit unencrypted opt-in, does not support FTPS/SFTP, and cannot prevent every simultaneous-write conflict. YubiKey support is iOS-only in this candidate.

Descriptions remain below 4,000 characters, promotional text below 170, and keywords below 100. Preserve existing ratings. Names, subtitles, categories, age ratings, and App Privacy are shared app-level fields; this listing edit did not change them.

## Reviewer notes — saved

```text
Reviewing KeeForge for Mac does not require an account or sign-in. The attached test.kdbx.zip is a compressed test database. Unzip it, then in KeeForge choose File > Open Database... and select test.kdbx; unlock it with the password testpassword123.

To test AutoFill, open System Settings > General > AutoFill & Passwords and enable KeeForge, then use Safari or another app. The Mac version supports local files and optional WebDAV connections; Dropbox and OneDrive are not available in the Mac version. WebDAV testing is optional and needs a server you provide — no server or account is required to test local files.
```

## en-US — saved

**Promotional text** (157 characters):

```text
A native Mac password manager for KeePass databases. Open local .kdbx files or connect WebDAV, AutoFill with Touch ID, and keep every secret on your own Mac.
```

**Description** (2359 characters):

```text
KeeForge is a native macOS password manager for KeePass (.kdbx) databases. Open vaults from local files or a WebDAV or FTP server you choose. AutoFill passwords, passkeys, and TOTP codes with Touch ID. No accounts, no tracking, no subscription — fully open source under GPLv3.

Why KeeForge:
- Native Mac app built in Swift — not a web wrapper
- Your vault stays encrypted on your Mac; we never see it
- Zero accounts, zero telemetry, zero ads
- Compatible with KeePassXC, KeePass 2.x, KeePassium, and Strongbox

Vault Management
- Open .kdbx databases from anywhere in Finder, or from a WebDAV or FTP server
- Manage multiple databases from one window with Quick Launch
- Create new KDBX 4.x databases locally or on WebDAV or FTP
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
- Screen capture blocking is best-effort and may not stop every screenshot or recording
- Exponential lockout after failed unlock attempts
- Argon2 KDF, AES-GCM in-memory encryption of secrets
- Clipboard clears automatically and is hidden from clipboard managers

Open Source
- Fully open source under GPLv3
- Source on GitHub: github.com/KeeForge/KeeForge
- No network calls except your own WebDAV or FTP server, optional website icon lookup, and the optional in-app feedback form

KeeForge for Mac opens local files and connects to WebDAV or FTP. Dropbox and OneDrive are not available on Mac yet — open your synced folder as a local file instead.

Tip jar available if you'd like to support development. No subscription, no accounts, no upsell.

FTP connections are unencrypted. Use FTP only on networks you trust, and avoid editing the same FTP database from multiple apps or devices at once. FTPS and SFTP are not supported.
```

**Keywords** (90 characters):

```text
kdbx,totp,2fa,passkey,fido2,touchid,otp,offline,encrypted,sync,webdav,strongbox,keepassium
```

**What’s New in This Version** (372 characters):

```text
Customize KeeForge with colorful KeePass icons and your choice of accent color. Edit custom fields, change database encryption settings, and choose where AutoFill saves new entries. Connect to FTP servers, and use KeeForge in Japanese. This update also improves search-result deletion, cloud warnings, and localization.

Group sidebar keyboard navigation is more reliable.
```

## de-DE — saved

**Promotional text** (162 characters):

```text
Ein nativer KeePass-Manager für den Mac: lokale .kdbx-Dateien öffnen, optional WebDAV verbinden, mit Touch ID ausfüllen - alle Geheimnisse bleiben auf deinem Mac.
```

**Description** (2831 characters):

```text
KeeForge ist ein nativer macOS-Passwortmanager für KeePass-Datenbanken (.kdbx). Öffne Tresore aus lokalen Dateien oder von einem WebDAV- oder FTP-Server deiner Wahl. Fülle Passwörter, Passkeys und TOTP-Codes per Touch ID automatisch aus. Keine Konten, kein Tracking, kein Abo - vollständig Open Source unter GPLv3.

Warum KeeForge:
- Native Mac-App, in Swift entwickelt - kein Web-Wrapper
- Dein Tresor bleibt verschlüsselt auf deinem Mac; wir sehen ihn nie
- Keine Konten, keine Telemetrie, keine Werbung
- Kompatibel mit KeePassXC, KeePass 2.x, KeePassium und Strongbox

Tresorverwaltung
- Öffne .kdbx-Datenbanken von überall im Finder oder von einem WebDAV- oder FTP-Server
- Verwalte mehrere Datenbanken in einem Fenster mit Schnellstart
- Erstelle neue KDBX-4.x-Datenbanken lokal oder auf WebDAV oder FTP
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
- Der Schutz vor Bildschirmaufnahmen ist ein Best-Effort-Schutz und verhindert möglicherweise nicht alle Screenshots und Aufzeichnungen
- Exponentielle Sperre nach fehlgeschlagenen Entsperrversuchen
- Argon2-KDF, AES-GCM-Verschlüsselung von Geheimnissen im Arbeitsspeicher
- Die Zwischenablage wird automatisch geleert und vor Zwischenablage-Managern verborgen

Open Source
- Vollständig Open Source unter GPLv3
- Quellcode auf GitHub: github.com/KeeForge/KeeForge
- Keine Netzwerkaufrufe außer zu deinem eigenen WebDAV- oder FTP-Server, der optionalen Website-Icon-Suche und dem optionalen Feedbackformular in der App

KeeForge für Mac öffnet lokale Dateien und verbindet sich mit WebDAV oder FTP. Dropbox und OneDrive sind auf dem Mac noch nicht verfügbar - öffne stattdessen deinen synchronisierten Ordner als lokale Datei.

Eine Trinkgeld-Option ist verfügbar, wenn du die Entwicklung unterstützen möchtest. Kein Abo, keine Konten, kein Upselling.

FTP-Verbindungen sind unverschlüsselt. Verwende FTP nur in vertrauenswürdigen Netzwerken und bearbeite dieselbe FTP-Datenbank nicht gleichzeitig mit mehreren Apps oder Geräten. FTPS und SFTP werden nicht unterstützt.
```

**Keywords** (90 characters):

```text
kdbx,keepass,passwort,totp,2fa,passkey,fido2,touchid,otp,offline,verschlüsselt,sync,webdav
```

**What’s New in This Version** (475 characters):

```text
Gestalte KeeForge mit farbigen KeePass-Symbolen und einer Akzentfarbe deiner Wahl. Bearbeite benutzerdefinierte Felder, ändere die Verschlüsselungseinstellungen deiner Datenbank und lege fest, wo AutoFill neue Einträge speichert. Verbinde dich mit FTP-Servern und nutze KeeForge auf Japanisch. Dieses Update verbessert außerdem das Löschen aus Suchergebnissen, Cloud-Warnungen und Übersetzungen.

Die Tastaturnavigation in der Gruppen-Seitenleiste funktioniert zuverlässiger.
```

## fr-FR — saved

**Promotional text** (159 characters):

```text
Un gestionnaire KeePass natif pour Mac : ouvrez des fichiers .kdbx locaux ou connectez WebDAV, remplissez avec Touch ID, et gardez chaque secret sur votre Mac.
```

**Description** (2934 characters):

```text
KeeForge est un gestionnaire de mots de passe macOS natif pour les bases KeePass (.kdbx). Ouvrez des coffres depuis des fichiers locaux ou un serveur WebDAV ou FTP de votre choix. Remplissez automatiquement les mots de passe, passkeys et codes TOTP avec Touch ID. Aucun compte, aucun suivi, aucun abonnement - entièrement open source sous GPLv3.

Pourquoi KeeForge :
- Application Mac native développée en Swift - pas un habillage web
- Votre coffre reste chiffré sur votre Mac ; nous ne le voyons jamais
- Aucun compte, aucune télémétrie, aucune publicité
- Compatible avec KeePassXC, KeePass 2.x, KeePassium et Strongbox

Gestion des coffres
- Ouvrez des bases .kdbx depuis n'importe quel emplacement du Finder ou depuis un serveur WebDAV ou FTP
- Gérez plusieurs bases dans une seule fenêtre avec le lancement rapide
- Créez de nouvelles bases KDBX 4.x en local ou sur WebDAV ou FTP
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
- Le blocage des captures d'écran est sans garantie et peut ne pas empêcher toutes les captures ou tous les enregistrements
- Verrouillage exponentiel après échecs de déverrouillage
- KDF Argon2 et chiffrement AES-GCM des secrets en mémoire
- Le presse-papiers s'efface automatiquement et est masqué aux gestionnaires de presse-papiers

Open Source
- Entièrement open source sous GPLv3
- Code source sur GitHub : github.com/KeeForge/KeeForge
- Aucun appel réseau sauf vers votre propre serveur WebDAV ou FTP, la recherche facultative d'icônes de sites et le formulaire de commentaires optionnel dans l'app

KeeForge pour Mac ouvre des fichiers locaux et se connecte à WebDAV ou FTP. Dropbox et OneDrive ne sont pas encore disponibles sur Mac - ouvrez plutôt votre dossier synchronisé comme un fichier local.

Un pourboire est disponible si vous souhaitez soutenir le développement. Aucun abonnement, aucun compte, aucune vente forcée.

Les connexions FTP ne sont pas chiffrées. Utilisez FTP uniquement sur des réseaux de confiance et évitez de modifier la même base FTP depuis plusieurs apps ou appareils à la fois. FTPS et SFTP ne sont pas pris en charge.
```

**Keywords** (88 characters):

```text
kdbx,keepass,motdepasse,totp,2fa,passkey,fido2,touchid,otp,horsligne,chiffré,sync,webdav
```

**What’s New in This Version** (521 characters):

```text
Personnalisez KeeForge avec des icônes KeePass colorées et la couleur d’accentuation de votre choix. Modifiez les champs personnalisés et les réglages de chiffrement des bases de données, et choisissez où AutoFill enregistre les nouvelles entrées. Connectez-vous à des serveurs FTP et utilisez KeeForge en japonais. Cette mise à jour améliore aussi la suppression depuis les résultats de recherche, les avertissements cloud et les traductions.

La navigation au clavier dans la barre latérale des groupes est plus fiable.
```

## es-ES — saved

**Promotional text** (141 characters):

```text
Un gestor KeePass nativo para Mac: abre archivos .kdbx locales o conecta WebDAV, rellena con Touch ID y guarda cada secreto en tu propio Mac.
```

**Description** (2678 characters):

```text
KeeForge es un gestor de contraseñas nativo para macOS para bases de datos KeePass (.kdbx). Abre bóvedas desde archivos locales o desde un servidor WebDAV o FTP que tú elijas. Rellena automáticamente contraseñas, passkeys y códigos TOTP con Touch ID. Sin cuentas, sin seguimiento, sin suscripción - completamente open source bajo GPLv3.

Por qué KeeForge:
- App nativa para Mac, creada en Swift - no es un envoltorio web
- Tu bóveda permanece cifrada en tu Mac; nunca la vemos
- Cero cuentas, cero telemetría, cero anuncios
- Compatible con KeePassXC, KeePass 2.x, KeePassium y Strongbox

Gestión de bóvedas
- Abre bases .kdbx desde cualquier lugar del Finder o desde un servidor WebDAV o FTP
- Gestiona varias bases en una sola ventana con inicio rápido
- Crea nuevas bases KDBX 4.x en local o en WebDAV o FTP
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
- El bloqueo de captura es una protección sin garantía y puede no impedir todas las capturas y grabaciones de pantalla
- Bloqueo exponencial tras intentos fallidos de desbloqueo
- KDF Argon2 y cifrado AES-GCM de secretos en memoria
- El portapapeles se borra automáticamente y se oculta de los gestores del portapapeles

Open Source
- Completamente open source bajo GPLv3
- Código fuente en GitHub: github.com/KeeForge/KeeForge
- Sin llamadas de red salvo a tu propio servidor WebDAV o FTP, la búsqueda opcional de iconos de sitios y el formulario opcional de comentarios en la app

KeeForge para Mac abre archivos locales y se conecta a WebDAV o FTP. Dropbox y OneDrive aún no están disponibles en Mac - abre tu carpeta sincronizada como un archivo local.

Hay una opción de propina si quieres apoyar el desarrollo. Sin suscripción, sin cuentas, sin ventas forzadas.

Las conexiones FTP no están cifradas. Usa FTP solo en redes de confianza y evita editar la misma base de datos FTP desde varias apps o dispositivos a la vez. FTPS y SFTP no son compatibles.
```

**Keywords** (86 characters):

```text
kdbx,keepass,contraseña,totp,2fa,passkey,fido2,touchid,otp,offline,cifrado,sync,webdav
```

**What’s New in This Version** (475 characters):

```text
Personaliza KeeForge con iconos de KeePass de colores y el color de acento que prefieras. Edita campos personalizados, cambia los ajustes de cifrado de las bases de datos y elige dónde guarda AutoFill las nuevas entradas. Conéctate a servidores FTP y usa KeeForge en japonés. Esta actualización también mejora la eliminación desde los resultados de búsqueda, los avisos de la nube y las traducciones.

La navegación con el teclado en la barra lateral de grupos es más fiable.
```

## ru — saved

**Promotional text** (158 characters):

```text
Нативный менеджер паролей KeePass для Mac: открывайте локальные файлы .kdbx или подключайте WebDAV, заполняйте с Touch ID — все секреты остаются на вашем Mac.
```

**Description** (2658 characters):

```text
KeeForge - нативный менеджер паролей для macOS для баз данных KeePass (.kdbx). Открывайте хранилища из локальных файлов или с выбранного вами сервера WebDAV или FTP. Автоматически заполняйте пароли, passkeys и TOTP-коды с Touch ID. Без аккаунтов, без отслеживания, без подписки - полностью open source под GPLv3.

Почему KeeForge:
- Нативное приложение для Mac, написано на Swift - не веб-обертка
- Ваше хранилище остается зашифрованным на вашем Mac; мы его никогда не видим
- Никаких аккаунтов, телеметрии и рекламы
- Совместимо с KeePassXC, KeePass 2.x, KeePassium и Strongbox

Управление хранилищами
- Открывайте базы .kdbx из любого места в Finder или с сервера WebDAV или FTP
- Управляйте несколькими базами в одном окне с быстрым запуском
- Создавайте новые базы KDBX 4.x локально или на WebDAV или FTP
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
- Блокировка снимков экрана работает в меру возможностей и может не предотвратить все скриншоты и записи
- Экспоненциальная блокировка после неудачных попыток разблокировки
- KDF Argon2 и AES-GCM-шифрование секретов в памяти
- Буфер обмена очищается автоматически и скрывается от менеджеров буфера обмена

Open Source
- Полностью open source под GPLv3
- Исходный код на GitHub: github.com/KeeForge/KeeForge
- Сетевых запросов нет, кроме вашего сервера WebDAV или FTP, необязательного поиска значков сайтов и необязательной формы обратной связи в приложении

KeeForge для Mac открывает локальные файлы и подключается к WebDAV или FTP. Dropbox и OneDrive пока недоступны на Mac - откройте синхронизированную папку как обычный локальный файл.

Есть возможность оставить чаевые, если вы хотите поддержать разработку. Без подписки, без аккаунтов, без навязанных покупок.

Соединения FTP не шифруются. Используйте FTP только в доверенных сетях и не редактируйте одну базу FTP одновременно в нескольких приложениях или на разных устройствах. FTPS и SFTP не поддерживаются.
```

**Keywords** (83 characters):

```text
kdbx,keepass,пароли,totp,2fa,passkey,fido2,touchid,otp,офлайн,sync,webdav,strongbox
```

**What’s New in This Version** (441 characters):

```text
Настройте KeeForge с помощью цветных значков KeePass и выбранного вами акцентного цвета. Редактируйте пользовательские поля, меняйте параметры шифрования баз данных и выбирайте, куда AutoFill сохраняет новые записи. Подключайтесь к FTP-серверам и пользуйтесь KeeForge на японском языке. Также улучшены удаление записей из результатов поиска, облачные предупреждения и переводы.

Навигация с клавиатуры по боковой панели групп стала надёжнее.
```

## zh-Hans — saved

**Promotional text** (83 characters):

```text
适用于 Mac 的原生 KeePass 管理器：打开本地 .kdbx 文件或连接 WebDAV，使用 Touch ID 自动填充，所有密码都留在您自己的 Mac 上。
```

**Description** (1143 characters):

```text
KeeForge 是一款原生 macOS KeePass（.kdbx）密码管理器。可从本地文件或您选择的 WebDAV 或 FTP 服务器打开密码库，并通过 Touch ID 在 Safari 和各类 App 中自动填充密码、passkey 和 TOTP 验证码。无需账户、没有跟踪、没有订阅，采用 GPLv3 完全开源。

为什么选择 KeeForge
• 使用 Swift 为 Mac 原生打造，不是网页套壳
• 密码库始终在您的 Mac 上保持加密；我们无法查看其中内容
• 无账户、无遥测、无广告
• 兼容 KeePassXC、KeePass 2.x、KeePassium 和 Strongbox

密码库管理
• 支持访达中任意位置的本地文件，以及 WebDAV 或 FTP 服务器
• 可在单一窗口中管理多个数据库，并使用快速启动
• 可在本地或 WebDAV 或 FTP 中创建 KDBX 4.x 数据库
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
• 屏幕捕捉阻止功能尽力保护密码库，但可能无法阻止所有截屏和录屏
• 多次解锁失败后采用指数退避锁定
• 使用 Argon2 KDF，并以 AES-GCM 在内存中加密敏感信息
• 剪贴板会自动清除，并对剪贴板管理器隐藏

开源
• 采用 GPLv3 完全开源
• 源代码：github.com/KeeForge/KeeForge
• 除您自己的 WebDAV 或 FTP 服务器、可选的网站图标查询和 App 内可选的反馈表单外，没有任何网络请求

Mac 版 KeeForge支持本地文件和 WebDAV 或 FTP。Mac 上暂不支持 Dropbox 和 OneDrive，请将同步文件夹中的文件作为本地文件打开。

无账户、无订阅、无推销。若您愿意支持开发，可使用小费功能。

FTP 连接不加密。请仅在信任的网络中使用 FTP，并避免同时通过多个 App 或设备编辑同一个 FTP 数据库。目前不支持 FTPS 和 SFTP。
```

**Keywords** (54 characters):

```text
密码,密码库,密码管理器,自动填充,验证码,双重验证,加密,离线,密钥文件,通行密钥,WebDAV,kdbx
```

**What’s New in This Version** (151 characters):

```text
使用彩色 KeePass 图标和自选强调色，让 KeeForge 更合心意。编辑自定义字段、更改数据库加密设置，并选择 AutoFill 保存新条目的位置。连接 FTP 服务器，也可使用日语版 KeeForge。本次更新还改进了搜索结果中的删除操作、云端警告和本地化。

群组侧边栏的键盘导航更加可靠。
```

## zh-Hant — saved

**Promotional text** (83 characters):

```text
適用於 Mac 的原生 KeePass 管理器：開啟本機 .kdbx 檔案或連接 WebDAV，使用 Touch ID 自動填入，所有密碼都留在您自己的 Mac 上。
```

**Description** (1155 characters):

```text
KeeForge 是一款原生 macOS KeePass（.kdbx）密碼管理器。可從本機檔案或您選擇的 WebDAV 或 FTP 伺服器開啟密碼庫，並透過 Touch ID 在 Safari 和各類 App 中自動填入密碼、passkey 和 TOTP 驗證碼。無需帳號、沒有追蹤、沒有訂閱，採用 GPLv3 完全開源。

為什麼選擇 KeeForge
• 使用 Swift 為 Mac 原生打造，不是網頁套殼
• 密碼庫始終在您的 Mac 上保持加密；我們無法查看其中內容
• 無帳號、無遙測、無廣告
• 相容 KeePassXC、KeePass 2.x、KeePassium 和 Strongbox

密碼庫管理
• 支援 Finder 中任意位置的本機檔案，以及 WebDAV 或 FTP 伺服器
• 可在單一視窗中管理多個資料庫，並使用快速啟動
• 可在本機或 WebDAV 或 FTP 中建立 KDBX 4.x 資料庫
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
• 螢幕擷取阻擋功能會盡力保護密碼庫，但可能無法阻止所有截圖和螢幕錄影
• 多次解鎖失敗後採用指數退避鎖定
• 使用 Argon2 KDF，並以 AES-GCM 在記憶體中加密敏感資訊
• 剪貼簿會自動清除，並對剪貼簿管理工具隱藏

開源
• 採用 GPLv3 完全開源
• 原始碼：github.com/KeeForge/KeeForge
• 除您自己的 WebDAV 或 FTP 伺服器、可選的網站圖示查詢和 App 內可選的回饋表單外，沒有任何網路請求

Mac 版 KeeForge支援本機檔案和 WebDAV 或 FTP。Mac 上暫不支援 Dropbox 和 OneDrive，請將同步資料夾中的檔案作為本機檔案開啟。

無帳號、無訂閱、無推銷。若您願意支持開發，可使用小費功能。

FTP 連線未加密。請僅在信任的網路中使用 FTP，並避免同時透過多個 App 或裝置編輯同一個 FTP 資料庫。目前不支援 FTPS 和 SFTP。
```

**Keywords** (54 characters):

```text
密碼,密碼庫,密碼管理器,自動填入,驗證碼,雙重驗證,加密,離線,金鑰檔案,通行密鑰,WebDAV,kdbx
```

**What’s New in This Version** (151 characters):

```text
使用彩色 KeePass 圖示和自選強調色，讓 KeeForge 更合心意。編輯自訂欄位、更改資料庫加密設定，並選擇 AutoFill 儲存新項目的位置。連線至 FTP 伺服器，也可使用日文版 KeeForge。本次更新還改善了搜尋結果中的刪除操作、雲端警告和本地化。

群組側邊欄的鍵盤導覽更加可靠。
```

## Release-notes rule

Use only the matching version heading in CHANGELOG.md and features present in the exact soaked RC. Translate the same meaning into every live App Store locale. Do not include Unreleased work. The seven current listing locales differ from the in-app language list; Japanese app support does not by itself add a Japanese store localization.

## v1.16.0 submission record

- [x] Mac version page exists for 1.16.0; no duplicate version was created.
- [x] Exact Mac App Store build `57` is accepted and attached.
- [x] Seven final Mac screenshots are uploaded in English in listing order
  01–07; Simplified Chinese inherits the English Mac gallery.
- [x] English listing copy is saved, and translated faithfully into every locale
  shown on the Mac version page.
- [x] Support URL is verified (not the stale `crazytan` one the iOS fr/de/ru/es
  locales still carry).
- [x] The App Privacy record was observed read-only on 2026-09-14: policy URL
  `https://keeforge.com/privacy/`, Product Preview **Data Not Collected**, and
  Data Types **“Data is not collected from this app.”** No edit or new
  declaration was made.
- [x] Contact information is populated; reviewer note identifies the attached
  `test.kdbx.zip` and password `testpassword123`.
- [x] Attachment visibly shows `test.kdbx.zip`.
- [x] Reviewer note says local files and optional WebDAV work, Dropbox and
  OneDrive are unavailable on native Mac, no sign-in is required, and AutoFill
  is enabled at System Settings → General → AutoFill & Passwords.
- [x] Export compliance resolved **No** for the attached build; public France
  availability was preserved.
- [x] **Manually release this version** is saved. **Keep Existing Rating** is
  chosen in the submission flow, not here.
- [x] Final RC release notes are derived from the matching versioned changelog
  section only, and saved for every locale ASC lists.
- [x] Review was staged, submitted with explicit action-time confirmation,
  approved, manually released, and owner-confirmed **Ready for Distribution**.
