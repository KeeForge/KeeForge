# Contribuire a KeeForge

<a href="../../CONTRIBUTING.md">English</a> | <a href="CONTRIBUTING.de.md">Deutsch</a> | <a href="CONTRIBUTING.fr.md">Français</a> | <a href="CONTRIBUTING.es.md">Español</a> | <a href="CONTRIBUTING.zh-Hans.md">简体中文</a> | <a href="CONTRIBUTING.zh-Hant.md">繁體中文</a> | <a href="CONTRIBUTING.ja.md">日本語</a> | Italiano

Grazie per l'aiuto nel migliorare KeeForge.

## Prima di iniziare

- Per una modifica sostanziale, apri prima una issue, così ambito e approccio possono essere discussi.
- Leggi [`AGENTS.md`](../../AGENTS.md), poi il `README.md` della cartella più vicina al codice che intendi modificare.
- Mantieni le modifiche mirate. Le modifiche sensibili per la sicurezza a parser, writer, crittografia, gestione dei segreti e percorso di salvataggio richiedono test mirati.

## Requisiti

- iOS 18+ e macOS 15+
- Xcode 26+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- Swift 6 con concorrenza rigorosa (strict concurrency)
- Dipendenze Swift Package: [argon2](https://github.com/P-H-C/phc-winner-argon2), [SwiftyDropbox](https://github.com/dropbox/SwiftyDropbox), [Microsoft Authentication Library](https://github.com/AzureAD/microsoft-authentication-library-for-objc), [swift-psl](https://github.com/ameshkov/swift-psl), [YubiKit](https://github.com/Yubico/yubikit-ios) e il pacchetto [KeeForgeTwofish](../../Vendor/KeeForgeTwofish) incluso nel repository

## Compilare dai sorgenti

```bash
cp BuildConfig.local.example.xcconfig BuildConfig.local.xcconfig
# Inserisci DROPBOX_APP_KEY e ONEDRIVE_CLIENT_ID per le build con i provider abilitati.
xcodegen generate
open KeeForge.xcodeproj
```

Per iPhone e iPad, seleziona un simulatore o un dispositivo con iOS 18+ ed esegui
lo schema `KeeForge`. Per Mac, esegui lo schema `KeeForgeMac` su macOS 15 o versioni successive.

Per la verifica da riga di comando, preferisci il più piccolo sottoinsieme di test pertinente:

```bash
xcodebuild test -project KeeForge.xcodeproj -scheme KeeForge \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:KeeForgeTests/DatabaseViewModelTests -quiet

xcodebuild test -project KeeForge.xcodeproj -scheme KeeForgeMac \
  -destination 'platform=macOS' \
  -only-testing:KeeForgeMacTests/DatabaseViewModelTests -quiet
```

## Flusso di lavoro di sviluppo

1. Crea un fork del repository e un branch tematico a partire da `main`.
2. Apporta la più piccola modifica coerente che risolva il problema.
3. Aggiungi o aggiorna i test, usando il più piccolo target di test pertinente e `-only-testing:`.
4. Aggiungi sotto `## Unreleased` in [`CHANGELOG.md`](../../CHANGELOG.md) le note sulle funzionalità e sulle correzioni rivolte agli utenti, per ogni piattaforma.
5. Apri una pull request che descriva il cambiamento di comportamento e come è stato verificato.

Un maintainer esamina ogni pull request prima del merge. KeeForge usa gli squash merge, quindi mantieni la pull request mirata e assegnale un titolo chiaro.

### Quale branch scegliere come destinazione

Per impostazione predefinita, usa `main` come destinazione per tutto.

Quando è in preparazione una release esiste anche un branch `release/{major}.{minor}` attivo, in prova su
TestFlight. Usalo come destinazione solo se te lo chiede un maintainer: è riservato alle correzioni dei bug
trovati nella release candidate, e ogni commit che vi arriva impone una nuova build e fa ripartire
il periodo di test. I maintainer riportano quelle correzioni su `main` separatamente; non aprire la stessa modifica
su entrambi i branch.

Prima che una pull request possa essere unita devono risultare superati tre controlli di stato:

- **unit-tests**: esegue la suite di test unitari `KeeForgeTests` su un simulatore iOS.
- **macos-unit-tests**: compila i sorgenti dei test unitari condivisi con l'app Mac nativa ed esegue `KeeForgeMacTests` su macOS.
- **DCO**: verifica che ogni commit sia firmato con sign-off (vedi sotto).

## Developer Certificate of Origin

KeeForge usa il [Developer Certificate of Origin 1.1](https://developercertificate.org/) (DCO). Firmando un commit con il sign-off, certifichi di avere il diritto di inviare il contributo con la licenza open source del repository.

Firma ogni commit con l'opzione `-s` di Git:

```bash
git commit -s -m "fix: describe the change"
```

Questo aggiunge al messaggio di commit un trailer come questo:

```text
Signed-off-by: Your Name <your.email@example.com>
```

Il sign-off è una certificazione, non una firma crittografica; `git commit -s` è diverso da `git commit -S`.

Se esistono già commit senza sign-off, aggiungilo durante il rebase sul branch `main` attuale:

```bash
git fetch origin
git rebase --signoff origin/main
```

Poiché il rebase riscrive la cronologia dei commit, aggiorna poi il branch del contributo con `git push --force-with-lease` quando necessario.

## Licenza

Inviando un contributo, accetti che sia concesso in licenza con gli stessi termini della GNU GPL che coprono questo repository. Dichiari inoltre di aver creato il contributo o di avere comunque il diritto di inviarlo con tali termini.

Non inviare codice copiato da una fonte incompatibile. Nella pull request segnala il codice di terze parti, le risorse generate o altro materiale con requisiti di licenza o di attribuzione separati.

---

Il resto della documentazione per sviluppatori, cioè [`AGENTS.md`](../../AGENTS.md) e i `README.md` delle singole cartelle, è mantenuto solo in inglese. In caso di dubbio fa fede la [versione inglese di questo documento](../../CONTRIBUTING.md).
