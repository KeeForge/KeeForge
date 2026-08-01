# Mitwirken bei KeeForge

<a href="CONTRIBUTING.md">English</a> | Deutsch | <a href="CONTRIBUTING.fr.md">Français</a>

Danke, dass du KeeForge besser machst.

## Bevor du loslegst

- Öffne bei größeren Änderungen zuerst ein Issue, damit Umfang und Vorgehen besprochen werden können.
- Lies [`AGENTS.md`](AGENTS.md) und danach die ordnerlokale `README.md`, die dem Code am nächsten liegt, den du ändern willst.
- Halte Änderungen fokussiert. Sicherheitsrelevante Änderungen an Parser, Writer, Krypto, Geheimnisverwaltung und Speicherpfaden erfordern gezielte Tests.

## Voraussetzungen

- iOS 18+
- Xcode 26+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- Swift 6 mit Strict Concurrency
- Swift-Package-Abhängigkeiten: [Argon2Swift](https://github.com/tmthecoder/Argon2Swift), [SwiftyDropbox](https://github.com/dropbox/SwiftyDropbox), [Microsoft Authentication Library](https://github.com/AzureAD/microsoft-authentication-library-for-objc) und das mitgelieferte [KeeForgeTwofish](Vendor/KeeForgeTwofish)-Paket

## Aus dem Quellcode bauen

```bash
cp BuildConfig.local.example.xcconfig BuildConfig.local.xcconfig
# Für Builds mit Cloud-Anbietern DROPBOX_APP_KEY und ONEDRIVE_CLIENT_ID eintragen.
xcodegen generate
open KeeForge.xcodeproj
```

Wähle einen Simulator oder ein Gerät mit iOS 18+ und baue und starte das Schema `KeeForge`.

Für die Verifikation über die Kommandozeile bevorzuge den kleinsten relevanten Test-Ausschnitt:

```bash
xcodebuild test -project KeeForge.xcodeproj -scheme KeeForge \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:KeeForgeTests/DatabaseViewModelTests -quiet
```

## Entwicklungs-Workflow

1. Forke das Repository und erstelle einen Topic-Branch von `main`.
2. Mache die kleinste zusammenhängende Änderung, die das Problem löst.
3. Ergänze oder aktualisiere Tests und nutze dabei das kleinste relevante Test-Target sowie `-only-testing:`.
4. Trage Notizen zu Features und Bugfixes unter `## Unreleased` in [`CHANGELOG.md`](CHANGELOG.md) ein.
5. Öffne einen Pull Request, der die Verhaltensänderung beschreibt und erklärt, wie sie verifiziert wurde.

Pull Requests brauchen mindestens eine zustimmende Review, bevor sie gemergt werden können. KeeForge nutzt Squash-Merges — halte den Pull Request also fokussiert und gib ihm einen klaren Titel.

### Welchen Branch anvisieren

Ziel ist standardmäßig `main` — für alles.

Während ein Release vorbereitet wird, gibt es zusätzlich einen aktiven `release/{major}.{minor}`-Branch, der
auf TestFlight soakt. Ziele nur dann auf diesen Branch, wenn ein Maintainer dich darum bittet — er ist
Fixes für Bugs vorbehalten, die im Release-Kandidaten gefunden wurden, und jeder Commit dort erzwingt einen
neuen Build und startet das Testfenster neu. Maintainer portieren diese Fixes separat nach `main`; reiche
dieselbe Änderung nicht gegen beide Branches ein.

Zwei Status-Checks müssen bestehen, bevor ein Pull Request gemergt werden kann:

- **unit-tests** — führt die Unit-Suite `KeeForgeTests` über GitHub Actions auf einem iOS-Simulator aus.
- **DCO** — prüft, ob jeder Commit signiert (Sign-off) ist (siehe unten).

## Developer Certificate of Origin

KeeForge nutzt das [Developer Certificate of Origin 1.1](https://developercertificate.org/) (DCO). Mit dem Sign-off eines Commits bestätigst du, dass du das Recht hast, den Beitrag unter der Open-Source-Lizenz dieses Repositorys einzureichen.

Signiere jeden Commit mit Gits Option `-s`:

```bash
git commit -s -m "fix: describe the change"
```

Das hängt einen Trailer wie diesen an die Commit-Nachricht an:

```text
Signed-off-by: Dein Name <deine.email@example.com>
```

Der Sign-off ist eine Bestätigung, keine kryptografische Signatur; `git commit -s` ist etwas anderes als `git commit -S`.

Wenn bereits Commits ohne Sign-off existieren, ergänze ihn beim Rebase auf den aktuellen `main`-Branch:

```bash
git fetch origin
git rebase --signoff origin/main
```

Da ein Rebase die Commit-Historie umschreibt, aktualisiere den Contributor-Branch danach bei Bedarf mit `git push --force-with-lease`.

## Lizenzierung

Mit dem Einreichen eines Beitrags stimmst du zu, dass er unter denselben GNU-GPL-Bedingungen lizenziert wird, die auch dieses Repository abdecken. Außerdem sicherst du zu, dass du den Beitrag selbst erstellt hast oder anderweitig das Recht hast, ihn unter diesen Bedingungen einzureichen.

Reiche keinen Code aus einer inkompatiblen Quelle ein. Weise im Pull Request auf Code Dritter, generierte Assets oder anderes Material mit eigenen Lizenz- oder Attributionsanforderungen hin.

---

Die übrige Entwicklerdokumentation — [`AGENTS.md`](AGENTS.md) und die ordnerlokalen `README.md`-Dateien — wird nur auf Englisch gepflegt. Maßgeblich ist im Zweifel die [englische Fassung dieses Dokuments](CONTRIBUTING.md).
