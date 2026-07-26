<p align="center">
  <img src=".github/assets/KeeForge-iOS-Default-1024x1024@1x.png" alt="KeeForge App-Icon" width="128" />
</p>

<h1 align="center">KeeForge</h1>

<p align="center">
  <a href="README.md">English</a> | Deutsch
</p>

<p align="center">
  Ein kostenloser, quelloffener KeePass-Manager für iPhone und iPad.
  <br />
  Natives SwiftUI, lokale Datenhaltung, AutoFill, Passkeys, TOTP, Cloud-Sync, KDBX-Bearbeitung und Anhang-Anzeige.
</p>

<p align="center">
  <a href="https://apps.apple.com/us/app/keeforge/id6759309295">
    <img alt="Im App Store laden" src="https://img.shields.io/badge/App%20Store-Download-0D96F6?style=for-the-badge&logo=appstore&logoColor=white" />
  </a>
  <img alt="Swift LoC" src="https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Ftokei.kojix2.net%2Fapi%2Fgithub%2FKeeForge%2FKeeForge%2Flanguages&query=%24.data.languages.Swift.code&label=swift%20loc&color=orange&style=for-the-badge" />
  <a href="LICENSE">
    <img alt="Lizenz: GPLv3" src="https://img.shields.io/badge/license-GPLv3-blue?style=for-the-badge" />
  </a>
</p>

## Warum KeeForge?

KeeForge ist ein nativer iOS-KeePass-Client für alle, die die Kontrolle über ihren Tresor behalten wollen. Öffne `.kdbx`-Datenbanken aus der Dateien-App, iCloud Drive, lokalen Ordnern, Dropbox, OneDrive oder von WebDAV-Servern wie Nextcloud und Synology; entsperre mit Master-Passwort, Schlüsseldatei oder Biometrie; und durchsuche, bearbeite, speichere und fülle Zugangsdaten automatisch aus — ohne deinen Tresor einem gehosteten Passwortdienst anzuvertrauen.

## Highlights

| Bereich | Was KeeForge kann |
| --- | --- |
| **KeePass-Kompatibilität** | Liest und schreibt KDBX-4.x-Datenbanken mit AES-256-, ChaCha20- oder Twofish-Verschlüsselung und AES-KDF, Argon2d oder Argon2id. Öffnet außerdem KDBX-3.1-Datenbanken im Nur-Lese-Modus. |
| **Lokale Bearbeitung** | Einträge erstellen, bearbeiten und löschen; Gruppen erstellen und löschen; Speichern mit Konfliktprüfung, zeitgestempelten Backups sowie Erhalt des Eintragsverlaufs und unbekannter XML-Elemente. |
| **Neue Datenbanken** | Neue KDBX-4.x-Datenbanken lokal oder direkt in Dropbox-, OneDrive- und WebDAV-Ordnern anlegen. |
| **Zusammengesetzte Schlüssel** | Entsperren mit Passwort, Schlüsseldatei oder beidem — einschließlich binärer, Hex-, XML-v1/v2- (`.key`/`.keyx`) und beliebiger Schlüsseldateien. |
| **AutoFill** | AutoFill in Safari und Apps, QuickType-Vorschläge, Anlegen von Zugangsdaten direkt aus der Extension und per Face ID geschütztes Entsperren. |
| **Passkeys** | Erkennen und Authentifizieren von FIDO2/WebAuthn-Passkeys, die in KeePassXC-kompatiblen benutzerdefinierten Feldern gespeichert sind. |
| **TOTP** | Live-Anzeige von Einmalpasswörtern, Kopierfunktion, Countdown und Bestätigungscode-AutoFill ab iOS 18. |
| **Cloud-Sync** | Natives Durchsuchen und Lese-/Schreib-Sync für Dropbox, OneDrive und WebDAV, zwischengespeicherte geteilte Kopien für AutoFill, Upload-Warteschlange in der Extension und Konfliktprüfungen. |
| **Anhänge** | KeePass-Eintragsanhänge anzeigen, unterstützte Dateien per QuickLook in der Vorschau öffnen und aus kurzlebigen geschützten temporären Dateien teilen. Das Bearbeiten von Anhängen wird noch nicht unterstützt. |
| **Bereit fürs iPad** | Die adaptive Navigation nutzt auf breiteren Layouts eine Split-View-Tresoransicht und hält den kompakten iPhone-Ablauf fokussiert und nativ. |
| **Sicherheitsbewusst** | AES-GCM-Verschlüsselung von Geheimnissen im Arbeitsspeicher, Backoff nach fehlgeschlagenen Entsperrversuchen, ausschließlich lokale Zwischenablage, Limits gegen Dekompressionsbomben und HMAC-Vergleich in konstanter Zeit. Der Bildschirmschutz unterscheidet sich je Plattform: iOS blendet die App aus, während der Bildschirm aufgenommen wird (`UIScreen.isCaptured`); macOS blurrt seine Fenster, sobald sie den Fokus verlieren, und blockiert standardmäßig nach bestem Bemühen Screenshots/Aufnahmen (`NSWindow.sharingType`, das ScreenCaptureKit-basierte Aufnahmen ab macOS 15 umgehen können). Das macOS-Verhalten bezieht sich auf die experimentelle native macOS-App (das Target `KeeForgeMac`) in diesem Repository, derzeit pausiert und unveröffentlicht. Siehe [`docs/macos-security-notes.md`](docs/macos-security-notes.md). |

## Datenschutz

KeeForge enthält keine Analytik, keine Hintergrund-Telemetrie und keine Crash-Reporting-SDKs. Tresordaten bleiben auf dem Gerät und an den von dir gewählten Speicherorten. Netzwerkzugriffe beschränken sich auf verbundene Cloud-Anbieter, das optionale Laden von Favicons über DuckDuckGo, optionale App-Store-Käufe für das Trinkgeld und das In-App-Feedback-Formular, wenn du explizit eine Nachricht absendest.

Lies die [Datenschutzerklärung](https://keeforge.com/de/privacy) ([englisches Original](https://keeforge.com/privacy)).

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

## Projektübersicht

```text
KeeForge/
├── App/              # App-Einstiegspunkt, adaptive Root-Shell, Scene-Lifecycle
├── Extensions/       # Geteilte Plattform-Kompatibilitätshelfer
├── Models/           # KDBX-Parser/-Writer, Krypto, Bearbeitungsentwurf, TOTP, Passkeys
├── Resources/        # String-Kataloge und Asset-Kataloge
├── Services/         # Persistenz, Cloud-Sync, Keychain, Bookmarks, Anhänge, AutoFill-Helfer
├── ViewModels/       # Datenbankliste, Entsperren, Speichern, Suche, Sortierung, TOTP-State
├── Views/            # SwiftUI-Screens, Editor, Einstellungen, Trinkgeld, wiederverwendbare Controls
AutoFillExtension/    # AutoFill-Credential-Provider, Passkey-Auth, Anlegen von Zugangsdaten
KeeForgeMac/          # Experimentelle native macOS-App (unveröffentlicht, pausiert)
KeeForgeMacUITests/   # XCUITest-Abdeckung für die macOS-App
KeeForgeTests/        # Unit-Tests
KeeForgeUITests/      # XCUITest-Abdeckung
TestFixtures/         # Beispiel-.kdbx-Datenbanken und Schlüsseldateien
Vendor/               # Lokal mitgeliefertes Swift-Package KeeForgeTwofish
ci_scripts/           # Xcode-Cloud-Bootstrap- und Release-Gate-Skripte
scripts/              # Lokale Entwickler-Tools
```

## Dokumentation

- [`CHANGELOG.md`](CHANGELOG.md) – Versionshistorie
- [`ROADMAP.md`](ROADMAP.md) – geplante Produktarbeit und offene Prioritäten
- [`AGENTS.md`](AGENTS.md) – Kontext für Coding-Agents
- [`KeeForge/README.md`](KeeForge/README.md) – Architekturübersicht des App-Targets
- [`AutoFillExtension/README.md`](AutoFillExtension/README.md) – Extension-Einschränkungen und Hinweise zu geteiltem Code
- [`SECURITY.md`](SECURITY.md) – Richtlinie zur Meldung von Sicherheitslücken
- [`docs/`](docs/) – Implementierungs-Specs, Audits und längere Design-Dokumente

Die Entwicklerdokumentation wird nur auf Englisch gepflegt.

## Support

- App Store: [KeeForge im App Store](https://apps.apple.com/us/app/keeforge/id6759309295)
- E-Mail: [support@keeforge.com](mailto:support@keeforge.com)
- Issues: [GitHub Issues](https://github.com/KeeForge/KeeForge/issues)

## Mitwirken

Siehe [`CONTRIBUTING.md`](CONTRIBUTING.md) für den Pull-Request-Workflow, die Sign-off-Pflicht nach dem Developer Certificate of Origin und die Lizenzbedingungen. Beginne mit [`AGENTS.md`](AGENTS.md) und öffne dann die ordnerlokale `README.md`, die dem Code am nächsten liegt, den du änderst.

## Lizenz

KeeForge ist unter der GPLv3 lizenziert. Details in [`LICENSE`](LICENSE).
