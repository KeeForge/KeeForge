# Contributing to KeeForge

English | <a href="CONTRIBUTING.de.md">Deutsch</a> | <a href="CONTRIBUTING.fr.md">Français</a>

Thanks for helping improve KeeForge.

## Before You Start

- For a substantial change, open an issue first so the scope and approach can be discussed.
- Read [`AGENTS.md`](AGENTS.md), then the folder-local `README.md` nearest to the code you plan to change.
- Keep changes focused. Security-sensitive parser, writer, crypto, secret-handling, and save-path changes require focused tests.

## Requirements

- iOS 18+
- Xcode 26+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- Swift 6 with strict concurrency
- Swift Package dependencies: [Argon2Swift](https://github.com/tmthecoder/Argon2Swift), [SwiftyDropbox](https://github.com/dropbox/SwiftyDropbox), [Microsoft Authentication Library](https://github.com/AzureAD/microsoft-authentication-library-for-objc), and the vendored [KeeForgeTwofish](Vendor/KeeForgeTwofish) package

## Build From Source

```bash
cp BuildConfig.local.example.xcconfig BuildConfig.local.xcconfig
# Fill in DROPBOX_APP_KEY and ONEDRIVE_CLIENT_ID for provider-enabled builds.
xcodegen generate
open KeeForge.xcodeproj
```

Select an iOS 18+ simulator or device, then build and run the `KeeForge` scheme.

For command-line verification, prefer the smallest relevant test slice:

```bash
xcodebuild test -project KeeForge.xcodeproj -scheme KeeForge \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:KeeForgeTests/DatabaseViewModelTests -quiet
```

## Development Workflow

1. Fork the repository and create a topic branch from `main`.
2. Make the smallest coherent change that addresses the issue.
3. Add or update tests, using the smallest relevant test target and `-only-testing:`.
4. Add feature and bug-fix notes under `## Unreleased` in [`CHANGELOG.md`](CHANGELOG.md).
5. Open a pull request describing the behavior change and how it was verified.

Pull requests require at least one approving review before merge. KeeForge uses squash merges, so please keep the pull request focused and give it a clear title.

### Which branch to target

Target `main` for everything by default.

When a release is being prepared there is also a live `release/{major}.{minor}` branch soaking on
TestFlight. Only target that branch if a maintainer asks you to — it is reserved for fixes to bugs
found in the release candidate, and every commit landing there forces a new build and restarts the
testing window. Maintainers port those fixes to `main` separately; do not open the same change
against both branches.

Two status checks must pass before a pull request can merge:

- **unit-tests** — runs the `KeeForgeTests` unit suite on an iOS simulator via GitHub Actions.
- **DCO** — verifies every commit is signed off (see below).

## Developer Certificate of Origin

KeeForge uses the [Developer Certificate of Origin 1.1](https://developercertificate.org/) (DCO). By signing off a commit, you certify that you have the right to submit the contribution under the repository's open-source license.

Sign off each commit with Git's `-s` option:

```bash
git commit -s -m "fix: describe the change"
```

This appends a trailer like this to the commit message:

```text
Signed-off-by: Your Name <your.email@example.com>
```

The sign-off is a certification, not a cryptographic signature; `git commit -s` is different from `git commit -S`.

If commits already exist without sign-offs, add them while rebasing onto the current `main` branch:

```bash
git fetch origin
git rebase --signoff origin/main
```

Because rebasing rewrites commit history, update the contributor branch afterward with `git push --force-with-lease` when necessary.

## Licensing

By submitting a contribution, you agree that it is licensed under the same GNU GPL terms that cover this repository. You also represent that you created the contribution or otherwise have the right to submit it under those terms.

Do not submit code copied from an incompatible source. Call out third-party code, generated assets, or other material with separate license or attribution requirements in the pull request.
