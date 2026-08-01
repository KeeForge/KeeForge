<p align="center">
  <img src=".github/assets/KeeForge-iOS-Default-1024x1024@1x.png" alt="Icône de l’application KeeForge" width="128" />
</p>

<h1 align="center">KeeForge</h1>

<p align="center">
  <a href="README.md">English</a> | <a href="README.de.md">Deutsch</a> | Français
</p>

<p align="center">
  Un gestionnaire KeePass gratuit et open source pour iPhone et iPad.
  <br />
  SwiftUI natif, stockage local, remplissage automatique, clés d’accès, TOTP, synchronisation cloud, édition KDBX et visualisation des pièces jointes.
</p>

<p align="center">
  <a href="https://apps.apple.com/us/app/keeforge/id6759309295">
    <img alt="Télécharger sur l’App Store" src="https://img.shields.io/badge/App%20Store-Download-0D96F6?style=for-the-badge&logo=appstore&logoColor=white" />
  </a>
  <img alt="Swift LoC" src="https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Ftokei.kojix2.net%2Fapi%2Fgithub%2FKeeForge%2FKeeForge%2Flanguages&query=%24.data.languages.Swift.code&label=swift%20loc&color=orange&style=for-the-badge" />
  <a href="LICENSE">
    <img alt="Licence : GPLv3" src="https://img.shields.io/badge/license-GPLv3-blue?style=for-the-badge" />
  </a>
</p>

## Pourquoi KeeForge ?

KeeForge est un client KeePass natif pour iOS, destiné à celles et ceux qui veulent garder le contrôle de leur coffre-fort. Ouvrez des bases de données `.kdbx` depuis Fichiers, iCloud Drive, des dossiers locaux, Dropbox, OneDrive ou des serveurs WebDAV comme Nextcloud et Synology ; déverrouillez avec un mot de passe principal, un fichier de clé ou la biométrie ; puis parcourez, recherchez, modifiez, enregistrez et utilisez le remplissage automatique sans confier votre coffre-fort à un service de mots de passe hébergé.

## Bêta publique

De nouvelles versions sont diffusées sur TestFlight avant d’arriver sur l’App Store.

**[Rejoignez la bêta KeeForge sur TestFlight](https://testflight.apple.com/join/mPAT4f1a)**

> [!WARNING]
> **Testez avec une copie de votre base de données, pas avec votre coffre-fort principal.** Les versions bêta ne sont pas revues et partagent l’identifiant de bundle et le conteneur de l’application de l’App Store — elles ouvrent donc vos vrais fichiers `.kdbx`.

Le nombre de places est limité à 300 testeurs, et les inscriptions sont fermées tant qu’une nouvelle version est en cours de revue bêta chez Apple : le lien n’est donc pas toujours ouvert.

## Points forts

| Domaine | Ce que fait KeeForge |
| --- | --- |
| **Compatibilité KeePass** | Lit et écrit des bases de données KDBX 4.x avec chiffrement AES-256, ChaCha20 ou Twofish, et AES-KDF, Argon2d ou Argon2id. Ouvre aussi les bases de données KDBX 3.1 en lecture seule. |
| **Édition locale** | Créez, modifiez et supprimez des entrées ; créez et supprimez des groupes ; enregistrez avec vérification des conflits, sauvegardes horodatées, et conservation de l’historique des entrées et du XML inconnu. |
| **Nouvelles bases de données** | Créez de nouvelles bases de données KDBX 4.x en local ou directement dans des dossiers Dropbox, OneDrive et WebDAV. |
| **Clés composites** | Déverrouillez avec un mot de passe, un fichier de clé, ou les deux — y compris des fichiers de clé binaires, hexadécimaux, XML v1/v2 (`.key`/`.keyx`) et arbitraires. |
| **Remplissage automatique** | Remplissage automatique dans Safari et dans les applications, suggestions QuickType, création d’identifiants depuis l’extension, et déverrouillage protégé par Face ID. |
| **Clés d’accès** | Détecte et authentifie les clés d’accès FIDO2/WebAuthn stockées dans des champs personnalisés compatibles KeePassXC. |
| **TOTP** | Affichage en direct des mots de passe à usage unique, copie, comptes à rebours, et remplissage automatique des codes de vérification à partir d’iOS 18. |
| **Synchronisation cloud** | Navigation native et synchronisation en lecture/écriture pour Dropbox, OneDrive et WebDAV, copies partagées mises en cache pour le remplissage automatique, envois différés depuis l’extension, et vérification des conflits. |
| **Pièces jointes** | Affichez les pièces jointes des entrées KeePass, prévisualisez les fichiers pris en charge avec QuickLook, et partagez-les depuis des fichiers temporaires protégés et de courte durée. La modification des pièces jointes n’est pas encore prise en charge. |
| **Compatible iPad** | La navigation adaptative utilise un espace de travail en vue scindée sur les écrans larges, tout en gardant le parcours iPhone compact, ciblé et natif. |
| **Sécurité** | Chiffrement AES-GCM des secrets en mémoire, ralentissement après échec de déverrouillage, limites contre les bombes de décompression, et comparaison HMAC à temps constant. |

## Confidentialité

KeeForge n’intègre aucun outil d’analyse, aucune télémétrie en arrière-plan et aucun SDK de rapport de plantage. Les données du coffre-fort restent sur l’appareil et aux emplacements de stockage que vous choisissez. L’accès réseau se limite aux fournisseurs cloud connectés, à la récupération optionnelle des favicônes via DuckDuckGo, aux achats optionnels sur l’App Store pour le pourboire, et au formulaire de retour intégré à l’application lorsque vous envoyez explicitement un message.

Tout ce que vous copiez reste sur l’appareil où vous l’avez copié, ne se synchronise jamais avec vos autres appareils, et s’efface de lui-même après un court instant ou lors du verrouillage de la base de données. KeeForge masque également le contenu de l’écran pendant qu’il est enregistré ou dupliqué (mirroring).

Lisez la [politique de confidentialité](https://keeforge.com/fr/privacy) ([version originale en anglais](https://keeforge.com/privacy)).

## Sécurité des données

KeeForge prend la sécurité des données très au sérieux : un gestionnaire de mots de passe ne doit jamais corrompre votre coffre-fort ni en perdre silencieusement une partie. Avant la publication de tout changement, des tests automatisés vérifient que :

- **Rien n’est perdu à l’enregistrement.** Chaque type de modification est enregistré puis relu élément par élément — mots de passe, notes, pièces jointes, historique des entrées, et même les données d’autres applications KeePass que KeeForge ne reconnaît pas doivent toutes revenir exactement telles qu’elles ont été saisies.
- **Votre fichier est protégé avant d’être touché.** KeeForge refuse d’écraser des modifications faites ailleurs pendant que le fichier était ouvert chez vous, écrit une sauvegarde horodatée avant chaque enregistrement, et rejette purement et simplement les bases de données endommagées plutôt que de charger des données partielles.
- **Un programme indépendant confirme.** Chaque version doit franchir une étape de vérification où KeePassXC — une application KeePass largement utilisée qui ne partage aucun code avec KeeForge — ouvre les bases de données écrites par KeeForge, déchiffre les mots de passe et confirme que les pièces jointes correspondent bit à bit. Les bases de données créées par d’autres logiciels KeePass doivent de même s’ouvrir dans KeeForge et rester lisibles ailleurs après avoir été enregistrées par KeeForge.

Pour les personnes curieuses sur le plan technique : la suite de tests est décrite dans [`KeeForgeTests/README.md`](KeeForgeTests/README.md), et l’étape de vérification avant chaque publication dans [`ci_scripts/README.md`](ci_scripts/README.md) (les deux en anglais).

## Plan du projet

```text
KeeForge/
├── App/              # Point d’entrée de l’application, coquille racine adaptative, cycle de vie des scènes
├── Extensions/       # Aides de compatibilité inter-plateformes partagées
├── Models/           # Parseur/writer KDBX, cryptographie, brouillon d’édition, TOTP, clés d’accès
├── Resources/        # Catalogues de chaînes et catalogues d’assets
├── Services/         # Persistance, synchronisation cloud, Trousseau, bookmarks, pièces jointes, aides au remplissage automatique
├── ViewModels/       # Liste des bases de données, déverrouillage, enregistrement, recherche, tri, état TOTP
├── Views/            # Écrans SwiftUI, éditeur, réglages, pourboire, contrôles réutilisables
AutoFillExtension/    # Fournisseur d’identifiants du remplissage automatique, authentification par clé d’accès, création d’identifiants
KeeForgeMac/          # Application macOS native expérimentale (non publiée, en pause)
KeeForgeMacUITests/   # Couverture XCUITest pour l’application macOS
KeeForgeTests/        # Tests unitaires
KeeForgeUITests/      # Couverture XCUITest
TestFixtures/         # Exemples de bases de données .kdbx et fichiers de clé
Vendor/               # Package Swift KeeForgeTwofish fourni en interne
ci_scripts/           # Scripts d’amorçage Xcode Cloud et de vérification de publication
scripts/              # Outils de développement locaux
```

## Documentation

- [`CHANGELOG.md`](CHANGELOG.md) – historique des versions
- [`ROADMAP.md`](ROADMAP.md) – travaux produit prévus et priorités ouvertes
- [`AGENTS.md`](AGENTS.md) – contexte pour les agents de codage
- [`KeeForge/README.md`](KeeForge/README.md) – plan de l’architecture des cibles de l’application
- [`AutoFillExtension/README.md`](AutoFillExtension/README.md) – contraintes de l’extension et notes sur le code partagé
- [`SECURITY.md`](SECURITY.md) – politique de signalement des vulnérabilités
- [`docs/`](docs/) – spécifications d’implémentation, audits et documents de conception plus détaillés

Hormis ce README et [`CONTRIBUTING.fr.md`](CONTRIBUTING.fr.md), la documentation pour développeurs est maintenue uniquement en anglais.

## Support

- App Store : [KeeForge sur l’App Store](https://apps.apple.com/us/app/keeforge/id6759309295)
- E-mail : [support@keeforge.com](mailto:support@keeforge.com)
- Issues : [GitHub Issues](https://github.com/KeeForge/KeeForge/issues)

## Contribuer

Consultez [`CONTRIBUTING.fr.md`](CONTRIBUTING.fr.md) pour les prérequis de compilation, la compilation depuis les sources, le workflow des pull requests, l’exigence de signature Developer Certificate of Origin, et les conditions de licence. Commencez par [`AGENTS.md`](AGENTS.md), puis ouvrez la `README.md` locale du dossier le plus proche du code que vous modifiez.

## Licence

KeeForge est distribué sous licence GPLv3. Voir [`LICENSE`](LICENSE) pour plus de détails.
