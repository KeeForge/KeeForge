# Competitive Gap Analysis

Research snapshot dated 2026-04-18 comparing KeeForge with two established Apple-platform KeePass apps: Strongbox and KeePassium.

This is a product-planning aid, not a canonical spec. Competitor feature sets change over time, and some listed features may be premium-only in those apps.

## Summary

KeeForge is already competitive on core iPhone fundamentals: multi-database support, AutoFill, TOTP, passkey sign-in, key files, local editing, local-save safety, and a privacy-first design. The largest visible gaps versus Strongbox and KeePassium are:

1. Broader sync provider support
2. Native iPad and macOS experiences
3. Attachments and richer KeePass data-model support
4. Passkey creation
5. Localization and power-user/security extras

## Feature Matrix

| Area | KeeForge | KeePassium | Strongbox | Gap Read |
| --- | --- | --- | --- | --- |
| iPhone app | Strong | Strong | Strong | Rough parity |
| iPad experience | Roadmap item | Mature iPad app | Mature iPad app | Meaningful gap |
| macOS app | Roadmap item | Official Mac app | Universal Mac app | Major gap |
| Multi-database support | Shipped | Shipped | Shipped | Rough parity |
| Local editing and save safety | Shipped | Shipped | Shipped | Competitive |
| Sync providers | Dropbox support today; more providers on roadmap | Broad Files-based sync: iCloud Drive, Dropbox, OneDrive, Google Drive, Box, Nextcloud, SFTP, WebDAV, more | Native sync for major cloud providers plus SFTP/WebDAV/SharePoint | Major gap |
| AutoFill | Shipped | Shipped | Shipped | Rough parity |
| TOTP | Shipped | Shipped, including Steam TOTP | Shipped | Small gap |
| Passkey sign-in | Shipped | Shipped | Shipped | Rough parity |
| Passkey creation | Roadmap item | Shipped | Public feature list shows passkeys, but creation flow is less explicit in the sources reviewed | Clear gap vs KeePassium |
| Attachments | Roadmap item | Shipped | Shipped | Major gap |
| Entry history UI | History preserved, viewer/restore still on roadmap | Supported | Supported | Clear UX gap |
| Custom fields / richer KeePass metadata | Limited today | Supported | Supported | Meaningful gap |
| Custom icons / icon tooling | Limited today | Supported | Supported | Moderate gap |
| Field references / placeholders | Not surfaced in current product docs | Supported | Supported | Moderate gap |
| Database creation | Roadmap item | Not a prominent differentiator in reviewed sources | Supported in practice-oriented docs and product positioning | Moderate gap |
| Import / export tooling | Limited in current product docs | Not a major differentiator in reviewed sources | Explicitly listed for CSV / 1Password | Moderate gap |
| Localization | Roadmap item | Translation/community support | Broad localization support | Clear gap |
| YubiKey / hardware key support | Not present in current product docs | Supported | Supported | Major security/power-user gap |
| Security / power-user extras | Strong local security posture | App lock layers, audits, YubiKey, field references | Duress PIN, audits, HIBP audit, YubiKey, advanced merge, Apple Watch features | Gap in advanced tier |

## Largest Gaps To Close

### 1. Sync Breadth

This is the most obvious day-to-day feature gap. Both competitors support substantially more storage providers and position sync as a headline capability. For KeeForge, closing this gap likely means:

- Add Google Drive, OneDrive, and WebDAV/SFTP-class support
- Make provider behavior feel consistent in browse, open, save, conflict, and offline flows
- Keep AutoFill/shared-cache behavior solid for cloud-backed databases

### 2. iPad and macOS

Strongbox and KeePassium both market themselves as Apple ecosystem apps, not just iPhone apps. KeeForge still reads as iPhone-first. The biggest product perception jump would come from:

- A proper iPad-native layout
- Native macOS support
- Platform-aware AutoFill and keyboard/navigation polish over time

### 3. Attachments and Richer KeePass Compatibility

Both competitors expose more of the KeePass model. KeeForge has strong edit/save groundwork, but a user comparing apps will notice missing higher-level data features:

- Attachment viewing and management
- Entry history browsing and restore
- Custom fields
- Custom icons
- Field references / placeholders

### 4. Passkey Creation

KeeForge already has passkey sign-in support, which is a strong base. The most visible remaining passkey gap is creating and saving new passkeys directly from the Apple credential flow.

### 5. Power-User and Trust Features

After core sync/platform/data-model gaps, the next differentiators are the features that make advanced users feel fully at home:

- YubiKey support
- Import/export and migration tooling
- Password/security audits
- Localization

## Suggested Priority Order

If the goal is to close the most competitive gaps with the least roadmap sprawl, the likely order is:

1. Sync provider expansion
2. iPad support
3. Attachments and entry-history UI
4. macOS support
5. Passkey creation
6. Localization
7. YubiKey and advanced security/power-user tooling

## Sources

- KeeForge local docs: `README.md`, `CHANGELOG.md`, `ROADMAP.md`
- KeePassium GitHub README: <https://github.com/keepassium/KeePassium>
- KeePassium site: <https://keepassium.com/>
- KeePassium 2.0 release post (2024-12-17): <https://keepassium.com/blog/2024/12/keepassium-2.0/>
- Strongbox feature comparison: <https://strongboxsafe.com/comparison/>
- Strongbox Universal post: <https://strongboxsafe.com/strongbox-universal/>
