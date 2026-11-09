# Translation Glossary

The canonical translation of KeeForge's recurring terms in every shipped locale. It was extracted from the String Catalogs, using the majority form where translations disagreed, aligned with Apple's own platform wording.

- Use these forms in new and edited strings, in the app and the AutoFill extensions alike, so the same concept reads the same everywhere.
- For a term not listed, search the catalogs for the English word and follow the majority form. If it will recur, add it here in the same change.
- The catalogs win over this file only for a deliberate, reviewed change. Then update this file in the same change.
- The Known Drift section lists existing strings that disagree with this file. Fix them when you touch them, and do not copy them.

## Locale Conventions

| Locale | Address | Quotes | Ellipsis | Other |
|---|---|---|---|---|
| `de` | `Sie` (majority). What's New, feature highlights, and some newer strings use `du` (see Known Drift) | `„…“` | Space before: `Exportieren …` | Buttons and commands use *Sichern* for Save; prose may say *speichern*. `Symbol` for icon, never `Icon` |
| `fr` | `vous` | `« … »` with spaces inside | `…` attached | Space before `:` `?` `!` `;` (no-break U+00A0 preferred). Apostrophe: straight `'` is the majority |
| `es` | `usted` (majority: `Introduzca`, `su`). What's New, feature highlights, and some newer strings use `tú` | `«…»` | `…` attached | `Ajustes` (Apple wording), not `Configuración`, for Settings |
| `it` | `tu` (`Scegli`, `tuo`) | `“…”` | `…` attached | Straight `'` apostrophe |
| `ru` | `вы` (lowercase), imperative plural | `«…»` | `…` attached | Always write `ё`. Counts with a colon where declension is awkward: `Символов: %lld` |
| `ja` | Polite `です/ます` in sentences; plain noun or verb-stem for buttons | `「…」` | `…` attached | Full-width `：` and `（）`. Counters as `エントリ %lld 件`. `App` in Apple app names (`「ファイル」App`); `アプリ` only in prose. No long-vowel mark: `ユーザ`, `サーバ`, `フォルダ`, `プロバイダ` |
| `zh-Hans` | `你` (Apple style) | `“…”` | `…` | `App`, not `应用`. Full-width `：` `（）`. Space between CJK and Latin/numbers: `%lld 个条目` |
| `zh-Hant` | `你` (Apple style) | `「…」` | `…` | `App`. Full-width punctuation. Space between CJK and Latin/numbers |

All locales use the typographic `…`, never `...`.

## Never Translate

KeeForge, KeePass, KeePassXC, KDBX, YubiKey, YubiKit, Face ID, WebDAV, FTP, HTTP, SSH, Dropbox, OneDrive, iCloud, Mac App Store, AES-256, ChaCha20, Twofish, Argon2, AES-KDF, TOTP, CSV, URL, QR (as in `QR-Code`), Public Suffix List, EFF's Long Wordlist, library names.

Apple renames some of these, and KeeForge follows Apple:

| en | Exception |
|---|---|
| Touch ID | zh-Hans `触控 ID`, zh-Hant `觸控 ID` |
| AirDrop | zh-Hans `隔空投送` |
| Apple's apps | Use the localized app name in the locale's quotes: Files → de `Dateien-App`, fr `l'app Fichiers`, es `la app Archivos`, it `l'app File`, ru `приложение «Файлы»`, ja `「ファイル」App`, zh-Hans `“文件”App`, zh-Hant `「檔案」App`. Passwords → `Passwörter`, `Mots de passe`, `Contraseñas`, `Password`, `«Пароли»`, `「パスワード」`, `“密码”`, `「密碼」` |
| Keychain | de `Schlüsselbund`, fr `trousseau`, es `llavero`, it `portachiavi`, ru `связка ключей`, ja `キーチェーン`, zh-Hans `钥匙串`, zh-Hant `鑰匙圈` |

## Database Structure

| en | de | fr | es | it | ru | ja | zh-Hans | zh-Hant |
|---|---|---|---|---|---|---|---|---|
| database | Datenbank | base de données | base de datos | database (m.) | база данных | データベース | 数据库 | 資料庫 |
| database file | Datenbankdatei | fichier de base de données | archivo de la base de datos | file del database | файл базы данных | データベースファイル | 数据库文件 | 資料庫檔案 |
| entry | Eintrag | entrée | entrada | voce | запись | エントリ | 条目 | 項目 |
| group | Gruppe | groupe | grupo | gruppo | группа | グループ | 群组 | 群組 |
| subgroup | Untergruppe | sous-groupe | subgrupo | sottogruppo | подгруппа | サブグループ | 子群组 | 子群組 |
| nested group | verschachtelte Gruppe | groupe imbriqué | grupo anidado | gruppo annidato | вложенная группа | サブグループ | 嵌套群组 | 巢狀群組 |
| Recycle Bin | Papierkorb | Corbeille | Papelera | Cestino | Корзина | ごみ箱 | 回收站 | 資源回收筒 |
| field | Feld | champ | campo | campo | поле | フィールド | 字段 | 欄位 |
| custom field | benutzerdefiniertes Feld | champ personnalisé | campo personalizado | campo personalizzato | пользовательское поле | カスタムフィールド | 自定义字段 | 自訂欄位 |
| protected field | geschütztes Feld | champ protégé | campo protegido | campo protetto | защищённое поле | 保護されたフィールド | 受保护字段 | 受保護欄位 |
| title | Titel | titre | título | titolo | название | タイトル | 标题 | 標題 |
| username | Benutzername | nom d'utilisateur | nombre de usuario | nome utente | имя пользователя | ユーザ名 | 用户名 | 使用者名稱 |
| password | Passwort | mot de passe | contraseña | password (f.) | пароль | パスワード | 密码 | 密碼 |
| website | Website | site web | sitio web | sito web | сайт | Web サイト | 网站 | 網站 |
| notes | Notizen | notes | notas | note | заметки | メモ | 备注 | 備註 |
| tag | Tag | tag | etiqueta | tag | тег | タグ | 标签 | 標籤 |
| attachment | Anhang | pièce jointe | archivo adjunto | allegato | вложение | 添付ファイル | 附件 | 附件 |
| icon | Symbol | icône | icono | icona | значок | アイコン | 图标 | 圖示 |
| custom icon | eigenes Symbol | icône personnalisée | icono personalizado | icona personalizzata | пользовательский значок | カスタムアイコン | 自定义图标 | 自訂圖示 |
| favicon / website icon | Favicon / Website-Symbol | favicon / icône du site | favicon / icono del sitio web | favicon (f.) / icona del sito web | значок сайта | ファビコン / Web サイトのアイコン | 网站图标 | 網站圖示 |
| expiration / expires | Ablauf / läuft ab | expiration / expire | caducidad / caduca | scadenza | срок действия / истекает | 有効期限 | 过期 | 過期 |
| history / earlier versions | Verlauf / frühere Versionen | historique / versions précédentes | historial / versiones anteriores | cronologia / versioni precedenti | история / предыдущие версии | 履歴 / 以前のバージョン | 历史记录 / 较早的版本 | 歷史記錄 / 較早的版本 |
| credential (login item) | Zugangsdaten (pl.) | identifiant | credencial | credenziali (pl.) | учётные данные | 認証情報 | 凭据 | 憑證 |
| metadata | Metadaten | métadonnées | metadatos | metadati | метаданные | メタデータ | 元数据 | 元資料 |

## Keys, Unlocking, and Security

| en | de | fr | es | it | ru | ja | zh-Hans | zh-Hant |
|---|---|---|---|---|---|---|---|---|
| master password | Master-Passwort | mot de passe principal | contraseña maestra | password principale | мастер-пароль | マスターパスワード | 主密码 | 主密碼 |
| master key | Master-Schlüssel | clé principale | clave maestra | chiave principale | мастер-ключ | マスターキー | 主密钥 | 主金鑰 |
| key file | Schlüsseldatei | fichier de clé | archivo de clave | file chiave | файл ключа | キーファイル | 密钥文件 | 金鑰檔案 |
| hardware key | Hardwareschlüssel | clé matérielle | llave de hardware | chiave hardware | аппаратный ключ | ハードウェアキー | 硬件密钥 | 硬體金鑰 |
| challenge-response | Challenge-Response | défi-réponse | desafío-respuesta | challenge-response | «запрос — ответ» | チャレンジレスポンス | 质询-响应 | 挑戰-回應 |
| slot (YubiKey) | Slot | emplacement | ranura | slot | слот | スロット | 插槽 | 插槽 |
| lock / unlock | sperren / entsperren | verrouiller / déverrouiller | bloquear / desbloquear | bloccare / sbloccare | заблокировать / разблокировать | ロック / ロック解除 | 锁定 / 解锁 | 鎖定 / 解鎖 |
| auto-lock | automatische Sperre | verrouillage automatique | bloqueo automático | blocco automatico | автоблокировка | 自動ロック | 自动锁定 | 自動鎖定 |
| biometric unlock | biometrisches Entsperren | déverrouillage biométrique | desbloqueo biométrico | sblocco biometrico | биометрическая разблокировка | 生体認証によるロック解除 | 生物识别解锁 | 生物辨識解鎖 |
| authentication / authenticate | Authentifizierung | authentification | autenticación | autenticazione | аутентификация | 認証 | 身份验证 | 身分驗證 |
| grace period | Karenzzeit | délai de grâce | periodo de gracia | periodo di tolleranza | период без повторной аутентификации | 猶予時間 | 宽限期 | 寬限期 |
| encryption / encrypt / decrypt | Verschlüsselung / verschlüsseln / entschlüsseln | chiffrement / chiffrer / déchiffrer | cifrado / cifrar / descifrar | crittografia / crittografare / decrittografare | шифрование / зашифровать / расшифровать | 暗号化 / 暗号化 / 復号 | 加密 / 加密 / 解密 | 加密 / 加密 / 解密 |
| cipher | Verschlüsselungsverfahren | chiffrement | cifrado | cifrario | шифр | 暗号方式 | 加密算法 | 加密演算法 |
| key derivation | Schlüsselableitung | dérivation de clé | derivación de claves | derivazione della chiave | формирование ключа | 鍵導出 | 密钥派生 | 金鑰衍生 |
| rounds | Runden | tours | rondas | cicli | раунды | ラウンド数 | 轮数 | 回合數 |
| compression | Komprimierung | compression | compresión | compressione | сжатие | 圧縮 | 压缩 | 壓縮 |
| read-only | schreibgeschützt | lecture seule | solo lectura | sola lettura | только чтение | 読み取り専用 | 只读 | 唯讀 |
| clipboard | Zwischenablage | presse-papiers | portapapeles | appunti | буфер обмена | クリップボード | 剪贴板 | 剪貼板 |
| screen capture | Bildschirmaufnahme | capture d'écran | captura de pantalla | acquisizione dello schermo | запись экрана | 画面キャプチャ | 屏幕捕捉 | 螢幕擷取 |
| SSH agent | SSH-Agent | agent SSH | agente SSH | agente SSH | SSH-агент | SSH エージェント | SSH 代理 | SSH 代理程式 |

## AutoFill, Passkeys, and Codes

| en | de | fr | es | it | ru | ja | zh-Hans | zh-Hant |
|---|---|---|---|---|---|---|---|---|
| AutoFill | AutoFill | remplissage automatique | autorrelleno | inserimento automatico | автозаполнение | 自動入力 | 自动填充 | 自動填寫 |
| Search & AutoFill | Suche & AutoFill | Recherche et remplissage automatique | Búsqueda y autorrelleno | Ricerca e inserimento automatico | Поиск и автозаполнение | 検索と自動入力 | 搜索与自动填充 | 搜尋與自動填寫 |
| passkey | Passkey (m.) | clé d'accès | llave de acceso | passkey (f.) | ключ входа | パスキー | 通行密钥 | 通行金鑰 |
| relying party | Relying Party | Relying Party | Relying Party | relying party | проверяющая сторона | リライングパーティ | 依赖方 | 信賴方 |
| verification code (TOTP) | Bestätigungscode | code de vérification | código de verificación | codice di verifica | код проверки | 確認コード | 验证码 | 驗證碼 |
| one-time password | Einmalpasswort | mot de passe à usage unique | contraseña de un solo uso | password monouso | одноразовый пароль | ワンタイムパスワード | 一次性密码 | 一次性密碼 |
| setup key / setup link | Einrichtungsschlüssel / Einrichtungslink | clé / lien de configuration | clave / enlace de configuración | chiave / link di configurazione | ключ / ссылка настройки | 設定キー / 設定リンク | 设置密钥 / 设置链接 | 設定金鑰 / 設定連結 |
| secret key (TOTP) | geheimer Schlüssel | clé secrète | clave secreta | chiave segreta | секретный ключ | シークレットキー | 密钥 | 金鑰 |
| match / possible match | Treffer / möglicher Treffer | correspondance / correspondance possible | coincidencia / posible coincidencia | corrispondenza / possibile corrispondenza | совпадение / возможное совпадение | 一致する項目 / 一致する可能性のある項目 | 匹配项 / 可能的匹配项 | 符合項目 / 可能相符的項目 |
| login (data) | Anmeldedaten | identifiants | inicios de sesión | credenziali | логины / данные для входа | ログイン情報 | 登录信息 | 登入資訊 |

In French, write `Remplissage automatique` capitalized at the start of a label and lowercase mid-sentence.

## Storage, Sync, and Cloud

| en | de | fr | es | it | ru | ja | zh-Hans | zh-Hant |
|---|---|---|---|---|---|---|---|---|
| save | sichern (commands) / speichern (prose) | enregistrer | guardar | salvare | сохранить | 保存 | 保存 | 儲存 |
| backup | Sicherungskopie | sauvegarde | copia de seguridad | backup (m.) | резервная копия | バックアップ | 备份 | 備份 |
| export / import | exportieren / importieren | exporter / importer | exportar / importar | esportare / importare | экспортировать / импортировать | 書き出す / 読み込む | 导出 / 导入 | 匯出 / 匯入 |
| share | teilen | partager | compartir | condividere | поделиться | 共有 | 共享 | 分享 |
| sync | Synchronisierung / synchronisieren | synchronisation / synchroniser | sincronización / sincronizar | sincronizzazione / sincronizzare | синхронизация | 同期 | 同步 | 同步 |
| cloud | Cloud | cloud | nube (`en la nube`) | cloud | облако / облачный | クラウド | 云 / 云端 | 雲端 |
| cloud account | Cloud-Konto | compte cloud | cuenta en la nube | account cloud | облачная учётная запись | クラウドアカウント | 云账户 | 雲端帳號 |
| provider | Anbieter | fournisseur | proveedor | provider | провайдер | プロバイダ | 提供商 | 提供者 |
| cached copy | Cache-Kopie | copie mise en cache | copia en caché | copia nella cache | кэшированная копия | キャッシュされたコピー | 缓存副本 | 快取副本 |
| upload / download | Upload, hochladen / herunterladen | envoi, envoyer / téléchargement, télécharger | carga, cargar / descarga, descargar | caricamento, caricare / download, scaricare | отправка, отправить / загрузка, загрузить | アップロード / ダウンロード | 上传 / 下载 | 上傳 / 下載 |
| pending upload | ausstehender Upload | envoi en attente | carga pendiente | caricamento in sospeso | ожидающая отправка | 保留中のアップロード | 待处理的上传 | 待處理的上傳 |
| conflict | Konflikt | conflit | conflicto | conflitto | конфликт | 競合 | 冲突 | 衝突 |
| merge | zusammenführen | fusionner | combinar | unire | объединить | マージ | 合并 | 合併 |
| discard | verwerfen | ignorer / abandonner | descartar | scartare | отменить | 破棄 | 放弃 | 捨棄 |
| connect / disconnect | verbinden / Verbindung trennen | connecter / déconnecter | conectar / desconectar | collegare / scollegare | подключить / отключить | 接続 / 接続を解除 | 连接 / 断开连接 | 連接 / 中斷連線 |
| sign in / sign out | anmelden / abmelden | se connecter / se déconnecter | iniciar / cerrar sesión | accedere / esci | войти / выйти | サインイン / サインアウト | 登录 / 退出登录 | 登入 / 登出 |
| local | lokal | local | local | locale | локальный | ローカル | 本地 | 本機 |
| device | Gerät | appareil | dispositivo | dispositivo | устройство | デバイス | 设备 | 裝置 |
| folder | Ordner | dossier | carpeta | cartella | папка | フォルダ | 文件夹 | 資料夾 |
| file | Datei | fichier | archivo | file | файл | ファイル | 文件 | 檔案 |

## Password Generator

| en | de | fr | es | it | ru | ja | zh-Hans | zh-Hant |
|---|---|---|---|---|---|---|---|---|
| password generator | Passwortgenerator | générateur de mots de passe | generador de contraseñas | generatore di password | генератор паролей | パスワード生成 | 密码生成器 | 密碼產生器 |
| generate / regenerate | generieren / neu generieren | générer / régénérer | generar / regenerar | generare / rigenerare | создать / создать заново | 生成 / 再生成 | 生成 / 重新生成 | 產生 / 重新產生 |
| passphrase | Passphrase | phrase secrète | frase de contraseña | passphrase (f.) | парольная фраза | パスフレーズ | 密码短语 | 密碼片語 |
| character sets | Zeichensätze | jeux de caractères | conjuntos de caracteres | set di caratteri | наборы символов | 文字の種類 | 字符集 | 字元集 |
| uppercase / lowercase | Großbuchstaben / Kleinbuchstaben | majuscules / minuscules | mayúsculas / minúsculas | maiuscole / minuscole | прописные / строчные буквы | 大文字 / 小文字 | 大写字母 / 小写字母 | 大寫字母 / 小寫字母 |
| digits / symbols | Ziffern / Symbole | chiffres / symboles | dígitos / símbolos | cifre / simboli | цифры / символы | 数字 / 記号 | 数字 / 符号 | 數字 / 符號 |
| separator | Trennzeichen | séparateur | separador | separatore | разделитель | 区切り文字 | 分隔符 | 分隔符號 |
| strength | Stärke | robustesse | seguridad | robustezza | надёжность | 強度 | 强度 | 強度 |

## Common Actions

These follow Apple's platform wording. The delete/remove/clear split matters: *delete* destroys data, *remove* takes something off a list or entry without destroying it, and *clear* empties a value or cache.

| en | de | fr | es | it | ru | ja | zh-Hans | zh-Hant |
|---|---|---|---|---|---|---|---|---|
| delete | löschen | supprimer | eliminar | eliminare | удалить | 削除 | 删除 | 刪除 |
| remove | entfernen | retirer | quitar | rimuovere | удалить | 削除 | 移除 | 移除 |
| clear | löschen / leeren | effacer / vider | borrar | cancellare / svuotare | очистить | 消去 | 清除 | 清除 |
| delete permanently | endgültig löschen | supprimer définitivement | eliminar permanentemente | eliminare definitivamente | удалить навсегда | 完全に削除 | 永久删除 | 永久刪除 |
| restore | wiederherstellen | restaurer | restaurar | ripristinare | восстановить | 復元 | 恢复 | 回復 |
| add | hinzufügen | ajouter | añadir | aggiungere | добавить | 追加 | 添加 | 加入 (to a list) / 新增 (create) |
| new (item) | neu | nouveau | nuevo | nuovo | новый | 新規 | 新建 | 新增 |
| edit | bearbeiten | modifier | editar | modificare | изменить | 編集 | 编辑 | 編輯 |
| open | öffnen | ouvrir | abrir | aprire | открыть | 開く | 打开 | 開啟 |
| turn on / off | aktivieren / deaktivieren (ausschalten) | activer / désactiver | activar / desactivar | attivare / disattivare | включить / выключить | オンにする / オフにする | 开启 / 关闭 | 開啟 / 關閉 |
| copy | kopieren | copier | copiar | copiare | скопировать | コピー | 拷贝 | 拷貝 |
| duplicate | duplizieren | dupliquer | duplicar | duplicare | дублировать | 複製 | 创建副本 | 建立副本 |
| move to group | in Gruppe verschieben | déplacer vers un groupe | mover a grupo | spostare nel gruppo | переместить в группу | グループへ移動 | 移动到群组 | 移動到群組 |
| choose | auswählen | choisir | elegir | scegliere | выбрать | 選択 | 选择 | 選擇 |
| select | auswählen | sélectionner | seleccionar | selezionare | выбрать | 選択 | 选择 | 選取 |
| search | suchen | rechercher | buscar | cercare | поиск / найти | 検索 | 搜索 | 搜尋 |
| show / hide | einblenden / ausblenden | afficher / masquer | mostrar / ocultar | mostrare / nascondere | показать / скрыть | 表示 / 非表示 | 显示 / 隐藏 | 顯示 / 隱藏 |
| retry / try again | erneut versuchen | réessayer | reintentar | riprovare | повторить | 再試行 | 重试 | 重試 |
| cancel / done | Abbrechen / Fertig | Annuler / Terminé | Cancelar / Hecho | Annulla / Fine | Отменить / Готово | キャンセル / 完了 | 取消 / 完成 | 取消 / 完成 |
| settings | Einstellungen | Réglages | Ajustes | Impostazioni | Настройки | 設定 | 设置 | 設定 |
| unavailable | nicht verfügbar | indisponible | no disponible | non disponibile | недоступно | 利用できません | 不可用 | 無法使用 |
| couldn't X (error title) | X konnte nicht … werden | Impossible de X | No se pudo X | Impossibile X | Не удалось X | Xできませんでした | 无法 X | 無法 X |
| X failed | X fehlgeschlagen | Échec de X | Error de X | X non riuscito | Ошибка X / Не удалось X | Xに失敗しました | X失败 | X失敗 |
| feedback | Feedback | commentaires | comentarios | feedback | отзыв | フィードバック | 反馈 | 意見回饋 |
| What's New | Neuigkeiten | Nouveautés | Novedades | Novità | Что нового | 新機能 | 新功能 | 新功能 |

## Known Drift

Existing strings that disagree with this file. Fix them when you touch them; do not copy them.

- **de / es address form.** What's New and feature-highlight copy, plus some newer settings footers and errors (about 50 strings in de, 30 in es), use `du` / `tú`; the other strings use `Sie` / `usted`. Use the formal form for new UI, errors, and settings. Whether to unify on one form is an open product decision.
- **zh-Hans / zh-Hant `您`.** About 30 strings per locale use `您`; the majority and Apple use `你`.
- **de Save.** Some commands and statuses use *speichern* (`Ohne Passwort speichern`, `Wird gespeichert …`, `Speichert in %@`) where commands use *Sichern*.
- **de Download.** Some strings use `laden` for download (`Symbol konnte nicht geladen werden`); use `herunterladen`. Keep `laden` for load.
- **de ellipsis.** About a third of `…` lack the preceding space (`Datenbank öffnen…`).
- **zh-Hant Open.** About a dozen strings use `打開`; use `開啟`.
- **zh-Hant Select.** `Choose Group` uses `選取群組`; `Select Group` uses `選擇群組`. Follow the choose/select rows above.
- **es upload.** `Dropbox upload failed.` uses `subir`; use `carga` / `cargar`.
- **es / fr Remove Verification Code.** These use `Eliminar` / `Supprimer`; the code is removed from the entry, so use `Quitar` / `Retirer`.
- **`...` instead of `…`.** A few strings in ja, zh-Hans, zh-Hant, and it (`Saving changes...`, `Syncing with %@...`).
