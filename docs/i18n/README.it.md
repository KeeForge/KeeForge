<p align="center">
  <img src="../../.github/assets/KeeForge-iOS-Default-1024x1024@1x.png" alt="Icona dell'app KeeForge" width="128" />
</p>

<h1 align="center">KeeForge</h1>

<p align="center">
  <a href="../../README.md">English</a> | <a href="README.de.md">Deutsch</a> | <a href="README.fr.md">Français</a> | <a href="README.es.md">Español</a> | <a href="README.zh-Hans.md">简体中文</a> | <a href="README.zh-Hant.md">繁體中文</a> | <a href="README.ja.md">日本語</a> | Italiano
</p>

<p align="center">
  Un gestore KeePass gratuito e open source per iPhone, iPad e Mac.
  <br />
  SwiftUI nativo, archiviazione locale prima di tutto, inserimento automatico, passkey, TOTP, sincronizzazione cloud, modifica dei file KDBX e visualizzazione degli allegati.
</p>

<p align="center">
  <a href="https://apps.apple.com/us/app/keeforge/id6759309295">
    <img alt="Scarica per iPhone, iPad o Mac dall'App Store" src="https://img.shields.io/badge/App%20Store-iPhone%2C%20iPad%20%26%20Mac-0D96F6?style=for-the-badge&logo=appstore&logoColor=white" />
  </a>
  <a href="https://github.com/KeeForge/KeeForge/releases/latest">
    <img alt="Scarica KeeForge direttamente per Mac" src="https://img.shields.io/badge/Mac-Direct%20Download-24292F?style=for-the-badge&logo=apple&logoColor=white" />
  </a>
  <a href="https://testflight.apple.com/join/mPAT4f1a">
    <img alt="Partecipa alla beta per iPhone e iPad su TestFlight" src="https://img.shields.io/badge/TestFlight-iPhone%20%26%20iPad-1F8AF0?style=for-the-badge&logo=apple&logoColor=white" />
  </a>
  <a href="https://testflight.apple.com/join/ZKQRwPaa">
    <img alt="Partecipa alla beta per Mac su TestFlight" src="https://img.shields.io/badge/TestFlight-Mac-1F8AF0?style=for-the-badge&logo=apple&logoColor=white" />
  </a>
  <img alt="Richiede iOS 18.0 o versioni successive" src="https://img.shields.io/badge/iOS-18.0%2B-000000?style=for-the-badge&logo=apple&logoColor=white" />
  <img alt="Richiede macOS 15.0 o versioni successive" src="https://img.shields.io/badge/macOS-15.0%2B-000000?style=for-the-badge&logo=apple&logoColor=white" />
  <img alt="Righe di codice Swift" src="https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Ftokei.kojix2.net%2Fapi%2Fgithub%2FKeeForge%2FKeeForge%2Flanguages&query=%24.data.languages.Swift.code&label=swift%20loc&color=orange&style=for-the-badge" />
  <a href="../../LICENSE">
    <img alt="Licenza: GPLv3" src="https://img.shields.io/badge/license-GPLv3-blue?style=for-the-badge" />
  </a>
</p>

## Perché KeeForge?

KeeForge è un client KeePass nativo per iPhone, iPad e Mac, pensato per chi vuole che il proprio vault resti suo. Apri i database `.kdbx` da file locali o tramite WebDAV su ogni piattaforma, con iCloud Drive, Dropbox, OneDrive e altri provider di File su iPhone e iPad; sblocca con una password principale, un file chiave o la biometria; poi sfoglia, cerca, modifica, salva e usa l'inserimento automatico senza affidare il tuo vault a un servizio di password ospitato da terzi.

## Beta pubblica

- iPhone e iPad: [Partecipa alla beta di KeeForge su TestFlight](https://testflight.apple.com/join/mPAT4f1a)
- Mac: [Partecipa alla beta di KeeForge su TestFlight](https://testflight.apple.com/join/ZKQRwPaa)

La disponibilità della beta può differire tra iPhone, iPad e Mac mentre Apple
esamina la build di ciascuna piattaforma.

## Punti di forza

| Area | Cosa fa KeeForge |
| --- | --- |
| **Compatibilità con KeePass** | Legge e scrive database KDBX 4.x con crittografia AES-256, ChaCha20 o Twofish e con AES-KDF, Argon2d o Argon2id. Apre anche i database KDBX 3.1 in sola lettura. |
| **Modifica in locale prima di tutto** | Crea, modifica, sposta ed elimina voci e gruppi; salva con controlli dei conflitti, backup con data e ora e conservazione della cronologia delle voci e dell'XML sconosciuto. |
| **Nuovi database** | Crea nuovi database KDBX 4.x in locale o tramite WebDAV su ogni piattaforma, e direttamente in Dropbox o OneDrive su iPhone e iPad. |
| **Chiavi composite** | Sblocca con password, file chiave o entrambi, inclusi file chiave binari, esadecimali, XML v1/v2 (`.key`/`.keyx`) e di qualsiasi altro tipo. |
| **Inserimento automatico** | Inserimento automatico nativo delle password nelle app e nei browser, con sblocco biometrico, più la registrazione delle passkey su ogni piattaforma; su iPhone e iPad l'estensione offre anche i suggerimenti QuickType e la creazione di voci con password. |
| **Passkey** | Rileva le passkey FIDO2/WebAuthn archiviate in campi personalizzati compatibili con KeePassXC e le usa per l'autenticazione. |
| **TOTP** | Visualizzazione in tempo reale delle password monouso, copia e conto alla rovescia su ogni piattaforma, più l'inserimento automatico dei codici di verifica su iOS 18+ e Mac. |
| **Sincronizzazione cloud** | Navigazione WebDAV e sincronizzazione in lettura e scrittura su ogni piattaforma. L'integrazione con Dropbox e OneDrive è attualmente disponibile su iPhone e iPad; su Mac puoi aprire le cartelle sincronizzate come file locali. |
| **Allegati** | Visualizza gli allegati delle voci KeePass, mostra l'anteprima dei file supportati con QuickLook e condividili tramite file temporanei protetti e di breve durata. La modifica degli allegati non è ancora supportata. |
| **Nativo su ogni schermo** | Navigazione essenziale su iPhone, un'area di lavoro a vista divisa su iPad e un'app Mac nativa ottimizzata per il desktop, con menu, comandi e Touch ID. |
| **Sicurezza** | Crittografia AES-GCM dei segreti in memoria, attesa crescente dopo gli sblocchi non riusciti, limiti contro le bombe di decompressione e confronto HMAC a tempo costante. |

## Privacy

KeeForge non ha analytics, telemetria in background né SDK per la segnalazione dei crash. I dati del vault restano sul dispositivo e nelle posizioni di archiviazione che scegli tu. L'accesso alla rete è limitato ai provider cloud collegati, al recupero facoltativo delle favicon tramite DuckDuckGo, agli acquisti facoltativi sull'App Store per il barattolo delle mance, alla verifica degli aggiornamenti per l'app Mac scaricata direttamente e al modulo di feedback nell'app quando invii esplicitamente un messaggio.

Su iPhone e iPad i segreti copiati vengono contrassegnati come solo locali, così non viaggiano attraverso gli Appunti condivisi. macOS non offre questa esclusione, quindi i segreti copiati possono seguire l'impostazione degli Appunti condivisi del tuo sistema; KeeForge li contrassegna come nascosti e cancella la propria voce degli appunti dopo poco tempo o quando blocchi il database. KeeForge protegge inoltre le anteprime nel selettore delle app su iPhone e iPad. Su Mac il blocco dell'acquisizione dello schermo non è garantito e potrebbe non impedire ogni screenshot o registrazione.

Leggi l'[informativa sulla privacy](https://keeforge.com/privacy) (in inglese).

## Sicurezza dei dati

KeeForge prende molto sul serio la sicurezza dei dati: un gestore di password non deve mai danneggiare il tuo vault né perderne in silenzio una parte. Prima che una modifica venga rilasciata, i test automatici verificano che:

- **Nulla vada perso quando salvi.** Ogni tipo di modifica viene salvato e riletto pezzo per pezzo: password, note, allegati, cronologia delle voci e perfino i dati di altre app KeePass che KeeForge non riconosce devono tornare esattamente come sono entrati.
- **Il tuo file sia protetto prima di essere toccato.** KeeForge controlla le modifiche fatte altrove mentre avevi il file aperto e rifiuta il salvataggio quando rileva un conflitto, scrive un backup con data e ora prima di ogni salvataggio e respinge del tutto i database danneggiati invece di caricare dati parziali.
- **Un programma indipendente sia d'accordo.** Ogni versione deve superare una verifica in cui KeePassXC, un'app KeePass molto diffusa che non condivide codice con KeeForge, apre i database scritti da KeeForge, decrittografa le password e conferma che gli allegati corrispondano bit per bit. Allo stesso modo, i database creati da altri software KeePass devono aprirsi in KeeForge e restare leggibili altrove dopo che KeeForge li ha salvati.

Con FTP, il controllo finale dei conflitti e la sostituzione del file non possono avvenire come un'unica operazione. Un salvataggio simultaneo da un'altra app o da un altro dispositivo può comunque essere sovrascritto, quindi evita di modificare un database FTP in due posti contemporaneamente.

Per chi è curioso degli aspetti tecnici, la suite di test è descritta in [`KeeForgeTests/AGENTS.md`](../../KeeForgeTests/AGENTS.md) e la verifica che precede ogni rilascio in [`ci_scripts/README.md`](../../ci_scripts/README.md).

## Mappa del progetto

```text
KeeForge/
├── App/              # Punto di ingresso dell'app, shell principale adattiva, ciclo di vita delle scene
├── Extensions/       # Helper condivisi per la compatibilità tra piattaforme
├── Models/           # Parser/writer KDBX, crittografia, bozza di modifica, TOTP, passkey
├── Resources/        # Cataloghi di stringhe e cataloghi di risorse
├── Services/         # Persistenza, sincronizzazione cloud, Portachiavi, segnalibri, allegati, helper dell'inserimento automatico
├── ViewModels/       # Elenco dei database, sblocco, salvataggio, ricerca, ordinamento, stato TOTP
├── Views/            # Schermate SwiftUI, editor, impostazioni, barattolo delle mance, controlli riutilizzabili
AutoFillExtension/    # Provider di credenziali per l'inserimento automatico, autenticazione con passkey, creazione di credenziali
KeeForgeMac/          # Configurazione ed entitlement dell'app macOS nativa
KeeForgeMacUITests/   # Copertura XCUITest dell'app macOS
KeeForgeTests/        # Test unitari
KeeForgeUITests/      # Copertura XCUITest
TestFixtures/         # Database .kdbx e file chiave di esempio
Vendor/               # Pacchetto Swift KeeForgeTwofish incluso nel repository
ci_scripts/           # Bootstrap di Xcode Cloud e script delle verifiche di rilascio
scripts/              # Strumenti di sviluppo locali
```

## Documentazione

- [`CHANGELOG.md`](../../CHANGELOG.md) - cronologia delle versioni
- [`ROADMAP.md`](../../ROADMAP.md) - lavoro pianificato sul prodotto e priorità aperte
- [`AGENTS.md`](../../AGENTS.md) - contesto per gli agenti di programmazione
- [`KeeForge/README.md`](../../KeeForge/README.md) - mappa dell'architettura del target dell'app
- [`AutoFillExtension/AGENTS.md`](../../AutoFillExtension/AGENTS.md) - vincoli dell'estensione e note sul codice condiviso
- [`SECURITY.md`](../../SECURITY.md) - politica di segnalazione delle vulnerabilità
- [`docs/`](../../docs/) - specifiche di implementazione, audit e documenti di progettazione più estesi

A parte questo README e [`CONTRIBUTING.it.md`](CONTRIBUTING.it.md), la documentazione per sviluppatori è mantenuta solo in inglese.

## Supporto

- App Store (iPhone, iPad e Mac): [KeeForge sull'App Store](https://apps.apple.com/us/app/keeforge/id6759309295)
- Download diretto per Mac: [ultima release su GitHub](https://github.com/KeeForge/KeeForge/releases/latest)
- Email: [support@keeforge.com](mailto:support@keeforge.com)
- Issue: [GitHub Issues](https://github.com/KeeForge/KeeForge/issues)

## Contribuire

Consulta [`CONTRIBUTING.it.md`](CONTRIBUTING.it.md) per i requisiti di compilazione, la compilazione dai sorgenti, il flusso di lavoro delle pull request, il requisito di sign-off del Developer Certificate of Origin e i termini di licenza. Inizia da [`AGENTS.md`](../../AGENTS.md), poi apri il `README.md` della cartella più vicina al codice che stai modificando.

## Licenza

KeeForge è distribuito con licenza GPLv3. Consulta [`LICENSE`](../../LICENSE) per i dettagli.

## Cronologia delle stelle

[![Grafico della cronologia delle stelle](https://api.star-history.com/svg?repos=KeeForge/KeeForge&type=Date)](https://www.star-history.com/#KeeForge/KeeForge&Date)
