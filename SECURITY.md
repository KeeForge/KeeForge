# Security Policy

KeeForge is a password manager, so we take security reports seriously. Thank you for helping keep KeeForge users safe.

## Supported Versions

Only the latest released version of KeeForge is supported with security updates.

| Version | Supported |
| ------- | --------- |
| Latest release (currently 1.10.x) | ✅ |
| Older versions | ❌ |

## Reporting a Vulnerability

**Please do not report security vulnerabilities through public GitHub issues, discussions, or pull requests.**

Instead, report them privately via GitHub's private vulnerability reporting:

1. Go to the [Security Advisories page](https://github.com/KeeForge/KeeForge/security/advisories/new).
2. Click **Report a vulnerability** and fill in the details.

Please include as much of the following as you can:

- A description of the vulnerability and its impact
- Steps to reproduce, or a proof of concept
- Affected version(s) and platform (iOS or macOS version, device or hardware)
- Any suggested fix or mitigation

### What to expect

- We will acknowledge your report within **7 days**.
- We will keep you informed as we investigate and work on a fix.
- Once a fix is released, we will credit you in the advisory (unless you prefer to remain anonymous).

Please give us a reasonable amount of time to address the issue before any public disclosure.

## Scope

In scope:

- The KeeForge iOS app and its AutoFill extension
- The macOS app and its AutoFill extension (unreleased; in scope for source-level reports)
- KDBX parsing, writing, and cryptography
- Keychain, App Group, and local storage handling
- Cloud sync and network features

Out of scope:

- Vulnerabilities in third-party services (e.g., cloud storage providers)
- Issues requiring a jailbroken device or physical access to an unlocked device
- Weaknesses in the KDBX format itself rather than KeeForge's implementation
