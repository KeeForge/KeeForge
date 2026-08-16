# Contribuer à KeeForge

<a href="../../CONTRIBUTING.md">English</a> | <a href="CONTRIBUTING.de.md">Deutsch</a> | Français | <a href="CONTRIBUTING.es.md">Español</a> | <a href="CONTRIBUTING.zh-Hans.md">简体中文</a> | <a href="CONTRIBUTING.zh-Hant.md">繁體中文</a>

Merci de contribuer à l’amélioration de KeeForge.

## Avant de commencer

- Pour un changement important, ouvrez d’abord une issue afin que la portée et l’approche puissent être discutées.
- Lisez [`AGENTS.md`](../../AGENTS.md), puis la `README.md` locale du dossier le plus proche du code que vous prévoyez de modifier.
- Restez concis. Les changements sensibles touchant au parseur, au writer, à la cryptographie, à la gestion des secrets et aux chemins d’enregistrement nécessitent des tests ciblés.

## Prérequis

- iOS 18+
- Xcode 26+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- Swift 6 avec la concurrence stricte
- Dépendances Swift Package : [Argon2Swift](https://github.com/tmthecoder/Argon2Swift), [SwiftyDropbox](https://github.com/dropbox/SwiftyDropbox), [Microsoft Authentication Library](https://github.com/AzureAD/microsoft-authentication-library-for-objc), [swift-psl](https://github.com/ameshkov/swift-psl), et le package [KeeForgeTwofish](../../Vendor/KeeForgeTwofish) fourni en interne

## Compiler depuis les sources

```bash
cp BuildConfig.local.example.xcconfig BuildConfig.local.xcconfig
# Renseignez DROPBOX_APP_KEY et ONEDRIVE_CLIENT_ID pour les builds avec fournisseurs cloud activés.
xcodegen generate
open KeeForge.xcodeproj
```

Sélectionnez un simulateur ou un appareil iOS 18+, puis compilez et lancez le schéma `KeeForge`.

Pour une vérification en ligne de commande, privilégiez le plus petit sous-ensemble de tests pertinent :

```bash
xcodebuild test -project KeeForge.xcodeproj -scheme KeeForge \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:KeeForgeTests/DatabaseViewModelTests -quiet
```

## Workflow de développement

1. Forkez le dépôt et créez une branche thématique à partir de `main`.
2. Faites le plus petit changement cohérent qui résout le problème.
3. Ajoutez ou mettez à jour des tests, en utilisant la cible de test la plus petite pertinente et `-only-testing:`.
4. Ajoutez des notes de fonctionnalités et de correctifs sous `## Unreleased` dans [`CHANGELOG.md`](../../CHANGELOG.md).
5. Ouvrez une pull request décrivant le changement de comportement et la façon dont il a été vérifié.

Un mainteneur relit chaque pull request avant sa fusion. KeeForge utilise les squash merges : veillez donc à garder la pull request ciblée et à lui donner un titre clair.

### Quelle branche cibler

Par défaut, ciblez `main` pour tout.

Lorsqu’une publication est en préparation, il existe aussi une branche `release/{major}.{minor}` active,
en cours de test sur TestFlight. Ne ciblez cette branche que si un mainteneur vous le demande : elle est
réservée aux correctifs des bugs trouvés dans le candidat de version, et chaque commit qui y arrive force
un nouveau build et redémarre la fenêtre de test. Les mainteneurs portent ces correctifs séparément vers
`main` ; ne soumettez pas le même changement sur les deux branches.

Deux vérifications de statut doivent réussir avant qu’une pull request puisse être fusionnée :

- **unit-tests** — exécute la suite unitaire `KeeForgeTests` sur un simulateur iOS via GitHub Actions.
- **DCO** — vérifie que chaque commit est signé (voir ci-dessous).

## Developer Certificate of Origin

KeeForge utilise le [Developer Certificate of Origin 1.1](https://developercertificate.org/) (DCO). En signant un commit, vous certifiez que vous avez le droit de soumettre la contribution sous la licence open source de ce dépôt.

Signez chaque commit avec l’option `-s` de Git :

```bash
git commit -s -m "fix: describe the change"
```

Cela ajoute un trailer de ce type au message de commit :

```text
Signed-off-by: Votre nom <votre.email@example.com>
```

Le sign-off est une certification, pas une signature cryptographique ; `git commit -s` est différent de `git commit -S`.

Si des commits existent déjà sans sign-off, ajoutez-le en rebasant sur la branche `main` actuelle :

```bash
git fetch origin
git rebase --signoff origin/main
```

Comme le rebase réécrit l’historique des commits, mettez à jour la branche du contributeur ensuite avec `git push --force-with-lease` si nécessaire.

## Licence

En soumettant une contribution, vous acceptez qu’elle soit distribuée sous les mêmes conditions GNU GPL qui couvrent ce dépôt. Vous garantissez également que vous êtes l’auteur de la contribution ou que vous disposez sinon du droit de la soumettre sous ces conditions.

Ne soumettez pas de code copié depuis une source incompatible. Signalez dans la pull request tout code tiers, tout contenu généré, ou tout autre matériel soumis à des exigences de licence ou d’attribution distinctes.

---

Le reste de la documentation pour développeurs — [`AGENTS.md`](../../AGENTS.md) et les `README.md` locales des dossiers — est maintenu uniquement en anglais. En cas de doute, la [version anglaise de ce document](../../CONTRIBUTING.md) fait foi.
