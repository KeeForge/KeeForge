# Участие в разработке KeeForge

<a href="../../CONTRIBUTING.md">English</a> | <a href="CONTRIBUTING.de.md">Deutsch</a> | <a href="CONTRIBUTING.fr.md">Français</a> | <a href="CONTRIBUTING.es.md">Español</a> | <a href="CONTRIBUTING.zh-Hans.md">简体中文</a> | <a href="CONTRIBUTING.zh-Hant.md">繁體中文</a> | <a href="CONTRIBUTING.ja.md">日本語</a> | <a href="CONTRIBUTING.it.md">Italiano</a> | Русский

Спасибо, что помогаете улучшать KeeForge.

## Прежде чем начать

- Для существенного изменения сначала откройте issue, чтобы можно было обсудить объём и подход.
- Прочитайте [`AGENTS.md`](../../AGENTS.md), затем `README.md` в папке, ближайшей к коду, который вы собираетесь изменить.
- Держите изменения сфокусированными. Изменения в парсере, записи, криптографии, обработке секретов и путях сохранения, влияющие на безопасность, требуют целевых тестов.

## Требования

- iOS 18+ и macOS 15+
- Xcode 26+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- Swift 6 со строгой проверкой параллелизма
- Зависимости Swift Package: [argon2](https://github.com/P-H-C/phc-winner-argon2), [SwiftyDropbox](https://github.com/dropbox/SwiftyDropbox), [Microsoft Authentication Library](https://github.com/AzureAD/microsoft-authentication-library-for-objc), [swift-psl](https://github.com/ameshkov/swift-psl), [YubiKit](https://github.com/Yubico/yubikit-ios) и встроенный пакет [KeeForgeTwofish](../../Vendor/KeeForgeTwofish)

## Сборка из исходного кода

```bash
cp BuildConfig.local.example.xcconfig BuildConfig.local.xcconfig
# Заполните DROPBOX_APP_KEY и ONEDRIVE_CLIENT_ID для сборок с облачными провайдерами.
xcodegen generate
open KeeForge.xcodeproj
```

Для iPhone и iPad выберите симулятор или устройство с iOS 18+ и запустите
схему `KeeForge`. Для Mac запустите схему `KeeForgeMac` в macOS 15 или новее.

Для проверки из командной строки используйте наименьший подходящий набор тестов:

```bash
xcodebuild test -project KeeForge.xcodeproj -scheme KeeForge \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:KeeForgeTests/DatabaseViewModelTests -quiet

xcodebuild test -project KeeForge.xcodeproj -scheme KeeForgeMac \
  -destination 'platform=macOS' \
  -only-testing:KeeForgeMacTests/DatabaseViewModelTests -quiet
```

## Процесс разработки

1. Сделайте форк репозитория и создайте тематическую ветку от `main`.
2. Внесите наименьшее целостное изменение, которое решает задачу.
3. Добавьте или обновите тесты, используя наименьшую подходящую цель тестов и `-only-testing:`.
4. Добавьте заметки о новых функциях и исправлениях для пользователей каждой платформы в раздел `## Unreleased` файла [`CHANGELOG.md`](../../CHANGELOG.md).
5. Откройте pull request с описанием изменения поведения и того, как оно было проверено.

Сопровождающий проверяет каждый pull request перед слиянием. KeeForge использует слияние со сжатием (squash merge), поэтому держите pull request сфокусированным и давайте ему понятный заголовок.

### В какую ветку направлять изменения

По умолчанию направляйте всё в `main`.

Во время подготовки выпуска также существует активная ветка `release/{major}.{minor}`, которая проходит
проверку в TestFlight. Направляйте изменения в неё, только если об этом попросит сопровождающий: она
предназначена для исправления ошибок, найденных в кандидате на выпуск, и каждый коммит в ней требует новой
сборки и перезапускает период тестирования. Сопровождающие переносят такие исправления в `main` отдельно;
не открывайте одно и то же изменение для обеих веток.

Перед слиянием pull request должны пройти три проверки статуса:

- **unit-tests** — запускает набор модульных тестов `KeeForgeTests` в симуляторе iOS.
- **macos-unit-tests** — компилирует общие исходники модульных тестов с нативным приложением для Mac и запускает `KeeForgeMacTests` в macOS.
- **DCO** — проверяет, что каждый коммит подписан (см. ниже).

## Developer Certificate of Origin

KeeForge использует [Developer Certificate of Origin 1.1](https://developercertificate.org/) (DCO). Подписывая коммит (sign-off), вы подтверждаете, что имеете право передать вклад на условиях лицензии с открытым исходным кодом этого репозитория.

Подписывайте каждый коммит с помощью параметра Git `-s`:

```bash
git commit -s -m "fix: describe the change"
```

Это добавляет строку такого вида:

```text
Signed-off-by: Your Name <your.email@example.com>
```

Подпись (sign-off) — это подтверждение, а не криптографическая подпись; `git commit -s` отличается от `git commit -S`.

Если коммиты уже созданы без подписи, добавьте её при перебазировании на текущую ветку `main`:

```bash
git fetch origin
git rebase --signoff origin/main
```

Поскольку перебазирование переписывает историю коммитов, при необходимости обновите затем ветку с вкладом командой `git push --force-with-lease`.

## Лицензирование

Отправляя вклад, вы соглашаетесь, что он лицензируется на тех же условиях GNU GPL, что и этот репозиторий. Вы также заявляете, что создали этот вклад сами или иным образом имеете право передать его на этих условиях.

Не отправляйте код, скопированный из источника с несовместимой лицензией. Указывайте в pull request сторонний код, сгенерированные ресурсы и другие материалы с отдельными требованиями к лицензированию или указанию авторства.

---

Остальная документация для разработчиков, то есть [`AGENTS.md`](../../AGENTS.md) и `README.md` отдельных папок, ведётся только на английском языке. В случае сомнений ориентируйтесь на [английскую версию этого документа](../../CONTRIBUTING.md).
