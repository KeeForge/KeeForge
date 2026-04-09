# KeeForge Security Audit

**Date:** 2026-02-26
**Auditor:** Automated Security Review (Claude)
**Scope:** All Swift source files in KeeForge iOS app + AutoFill extension
**Commit:** `968d142` (main branch)

---

## Executive Summary

KeeForge is an iOS KeePass (.kdbx 4.x) client with AutoFill extension support. The app handles master passwords, KDBX decryption, keychain storage, clipboard operations, and biometric authentication.

**Overall assessment: Moderate risk.** The app gets the fundamentals right — Keychain access control uses `.biometryCurrentSet` with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, Argon2 key derivation is correctly implemented, clipboard has expiration timeouts, and screen protection activates on background. However, there are significant gaps in memory hygiene for cryptographic secrets (the single most important issue for a password manager), clipboard data can leak via Universal Clipboard, and HMAC comparisons are not constant-time.

No hardcoded secrets or API keys were found. No SQL injection, XSS, or command injection vectors exist (this is a native iOS app with no web views or databases). The cryptographic implementations (ChaCha20, AES-CBC, HMAC-SHA256) are correct.

### Finding Summary

| Severity | Count | Key Concerns |
|----------|-------|--------------|
| Critical | 0 | — |
| High     | 4 | Memory hygiene, clipboard leakage, HMAC timing |
| Medium   | 5 | Favicon privacy, decompression bombs, file protection, parser robustness |
| Low      | 4 | Logging, brute-force, screen capture, AutoFill memory |
| Info     | 4 | Positive findings and minor notes |

---

## Findings

### HIGH-1: Cryptographic keys and passwords never zeroed from memory

**Severity:** HIGH
**Files:** `KDBXCrypto.swift:99-103`, `KDBXParser.swift:84-212`, `DatabaseViewModel.swift:46,163-170`

**Description:**
Decrypted secrets — the composite key, transformed key, master key, HMAC base key, and all intermediate derivation products — are stored in Swift `Data` values that are never explicitly zeroed when they go out of scope. Swift's ARC deallocates memory when reference counts drop to zero, but the underlying memory pages are NOT wiped. The freed memory remains readable until the OS reassigns and overwrites those pages.

Specific instances:

- `KDBXCrypto.compositeKey(password:)` (line 99): Creates `pwdData = Data(password.utf8)` and `hash` — neither is zeroed.
- `KDBXParser.parse()` (lines 121-134): `transformedKey`, `preKey`, `masterKey`, `hmacPreKey`, `hmacBaseKey` are all local `Data` variables that fall out of scope without zeroing.
- `DatabaseViewModel.compositeKey` (line 46): The composite key is retained as a `Data?` property for the entire unlocked session. Even when `lock()` sets it to `nil` (line 218), the memory is not overwritten.
- The `password: String` parameter threaded through `unlock()` → `KDBXParser.parse()` → `KDBXCrypto.compositeKey()` is a Swift `String` — immutable, potentially copied by the runtime, and impossible to zero.

**Impact:**
A memory dump of the app process (via jailbreak, exploit, or forensic tool) could recover the master password hash, composite key, or encryption keys even after the vault has been locked.

**Recommendation:**
- Use `UnsafeMutableRawBufferPointer` / `UnsafeMutablePointer<UInt8>` for all key material. Wrap it in a `SecureBytes` type that zeroes memory in `deinit`.
- Alternatively, use `Data` but explicitly zero it with `data.resetBytes(in: 0..<data.count)` before releasing (note: compiler may optimize this away — use `memset_s` or `SecureEnclave` for guarantees).
- For the password string, convert to `[UInt8]` immediately on entry, zero the array after deriving the composite key, and never store the original `String`.
- Remove `DatabaseViewModel.compositeKey` — it serves no purpose after the Keychain store on line 176.

---

### HIGH-2: Passwords and TOTP secrets stored as Swift Strings in memory

**Severity:** HIGH
**Files:** `Entry.swift:8-9`, `Entry.swift:69-70` (TOTPConfig.secret)

**Description:**
`KPEntry.password` and `TOTPConfig.secret` are `let` properties of type `String`. Once the KDBX is parsed, every password and TOTP secret in the database lives in memory as an immutable Swift String for the entire duration of the unlocked session (potentially minutes with auto-lock set to "5 Minutes" or indefinitely with "Never").

Swift Strings are:
- **Immutable:** Cannot be overwritten in place.
- **Copy-on-write with shared storage:** Multiple references may point to the same buffer.
- **Not zeroable:** No API exists to securely erase a String's backing storage.

The entire parsed `KPGroup` tree (`rootGroup`) with all entries is held by `DatabaseViewModel.rootGroup` until `lock()` is called.

**Impact:**
All passwords from the entire database are simultaneously resident in memory. A single memory read primitive gives an attacker every credential.

**Recommendation:**
- Store sensitive fields (`password`, TOTP `secret`) as `Data` or a custom `SecureString` wrapper backed by `UnsafeMutableBufferPointer<UInt8>` that zeroes on deallocation.
- Consider lazy decryption: keep protected values encrypted in memory using the inner stream cipher, and only decrypt on-demand when displayed or copied. This significantly reduces the attack window.

---

### HIGH-3: Clipboard passwords may sync via Universal Clipboard

**Severity:** HIGH
**File:** `ClipboardService.swift:5-8`

**Description:**
```swift
UIPasteboard.general.setItems(
    [[UIPasteboard.typeAutomatic: string]],
    options: [.expirationDate: Date().addingTimeInterval(SettingsService.clipboardTimeout.seconds)]
)
```

The clipboard options include `.expirationDate` (good), but do NOT include `.localOnly: true`. On devices with Handoff enabled, `UIPasteboard.general` contents sync via iCloud Universal Clipboard to nearby Macs, iPads, and other iPhones signed into the same Apple ID.

This means a copied password could:
1. Appear on a nearby Mac's clipboard without user awareness.
2. Be logged by clipboard monitoring tools on macOS (which has no clipboard access restrictions).
3. Persist on another device even after the iOS expiration timer fires.

**Impact:**
Passwords copied to the clipboard can escape the device entirely via Universal Clipboard, appearing on other devices where they may be logged or intercepted.

**Recommendation:**
Add `.localOnly: true` to the pasteboard options:
```swift
options: [
    .expirationDate: Date().addingTimeInterval(SettingsService.clipboardTimeout.seconds),
    .localOnly: true
]
```

---

### HIGH-4: HMAC and hash comparisons are not constant-time

**Severity:** HIGH (defense-in-depth)
**File:** `KDBXParser.swift:116,139,371,383`

**Description:**
All integrity checks use Swift's `==` operator on `Data`:
```swift
guard storedHeaderSHA == computedHeaderSHA else { ... }   // line 116
guard storedHeaderHMAC == computedHeaderHMAC else { ... }  // line 139
guard storedHMAC == computed else { ... }                  // lines 371, 383
```

Swift's `Data.==` performs byte-by-byte comparison and short-circuits on the first mismatch. This is a textbook timing side-channel. While the practical exploitability is limited in a local file-parsing context (the attacker cannot observe timing remotely), this violates cryptographic best practices and could become exploitable if the parsing logic is ever exposed over a network or IPC interface.

**Impact:**
Theoretical timing side-channel. An attacker who can observe parse timing with high precision while also manipulating file contents could potentially determine valid HMAC values byte-by-byte.

**Recommendation:**
Use constant-time comparison. CryptoKit doesn't expose one directly, but you can implement it:
```swift
static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
    guard a.count == b.count else { return false }
    var result: UInt8 = 0
    for i in 0..<a.count {
        result |= a[i] ^ b[i]
    }
    return result == 0
}
```

---

### MEDIUM-1: Favicon fetching leaks vault domains to Google

**Severity:** MEDIUM
**File:** `FaviconService.swift:7,96-99`

**Description:**
When "Download Website Favicons" is enabled, the app fetches icons from:
```
https://www.google.com/s2/favicons?domain=<domain>&sz=64
```

Every domain stored in the user's password database is sent to Google's servers as a query parameter. This includes potentially sensitive domains (banking, healthcare, internal corporate, adult content, etc.).

**Mitigating factors:**
- The setting defaults to OFF (`showWebsiteIcons` returns `false` when unset) — line `SettingsService.swift:88-93`.
- The settings UI includes a disclosure: "Fetches icons from Google. Only the website domain is sent."
- The requests go to Google, NOT directly to the domains (no direct SSRF).

**Impact:**
When enabled, Google receives a complete list of domains the user has credentials for. This is a significant privacy concern for a password manager.

**Recommendation:**
- Consider using a privacy-preserving favicon service or self-hosted proxy.
- Alternatively, use DuckDuckGo's favicon service (`https://icons.duckduckgo.com/ip3/<domain>.ico`) which has a stronger privacy stance.
- Add a more prominent privacy warning when enabling the setting.
- Consider fetching favicons over a Tor circuit or VPN.

---

### MEDIUM-2: No decompression bomb mitigation

**Severity:** MEDIUM
**File:** `KDBXCrypto.swift:265-292`

**Description:**
The `inflateStream` method decompresses data without any output size limit:
```swift
var output = Data()
// ...
while true {
    // inflate...
    output.append(contentsOf: outBuffer.prefix(produced))
    // no size check
}
```

A maliciously crafted KDBX file could contain a small compressed payload that expands to gigabytes (a "zip bomb"). Since KDBX decryption happens before decompression, an attacker would need to know the password to trigger this — but a file could be shared with a known password as an attack vector.

**Impact:**
Denial of service — app crash due to memory exhaustion.

**Recommendation:**
Add a maximum decompressed size limit (e.g., 256 MB):
```swift
let maxDecompressedSize = 256 * 1024 * 1024
if output.count > maxDecompressedSize {
    throw CryptoError.decompressionFailed
}
```

---

### MEDIUM-3: Favicon cache written without file protection

**Severity:** MEDIUM
**File:** `FaviconService.swift:116`

**Description:**
```swift
try? data.write(to: path, options: .atomic)
```

Cached favicons are written to the shared app group container with only `.atomic` write option. No `NSFileProtection` attribute is set. The default file protection for app group containers may be `NSFileProtectionCompleteUntilFirstUserAuthentication` rather than the more restrictive `NSFileProtectionComplete`.

The favicon cache reveals which websites are in the user's vault — the filenames are SHA-256 hashes of domains, but the image content itself could identify the website.

**Impact:**
On a device with a passcode that has been unlocked at least once since boot (AFU state), the favicon cache files are readable. A forensic tool could extract them to determine which websites the user has credentials for.

**Recommendation:**
Set `NSFileProtectionComplete` on the cache directory and individual files:
```swift
try data.write(to: path, options: [.atomic, .completeFileProtection])
```

---

### MEDIUM-4: Negative block size can crash the parser

**Severity:** MEDIUM
**File:** `KDBXParser.swift:363-375`

**Description:**
```swift
let blockSizeRaw = reader.readInt32()  // signed Int32
// ...
let blockData = reader.readBytes(Int(blockSizeRaw))
```

`readInt32()` reads a **signed** Int32. If a malformed file contains a negative block size (but non-zero), `Int(blockSizeRaw)` produces a negative value. `DataReader.readBytes()` then computes `min(offset + count, data.count)` where count is negative, resulting in `end < offset`. The subsequent `data.subdata(in: offset..<end)` creates a Range where start > end, which will trap (crash) at runtime.

**Impact:**
Denial of service — a malformed KDBX file crashes the app. This can be triggered without knowing the password since block reading occurs before full decryption verification.

Wait — actually, HMAC block reading occurs AFTER key derivation and header HMAC verification (line 144). An attacker would need to know the password to craft a file that reaches this code. Downgrading risk but still worth fixing.

**Recommendation:**
Validate the block size is non-negative:
```swift
guard blockSizeRaw > 0 else { throw ParseError.truncatedFile }
```

---

### MEDIUM-5: IPv6 addresses bypass FaviconService domain filter

**Severity:** MEDIUM
**File:** `FaviconService.swift:42`

**Description:**
```swift
if host == "localhost" || host.allSatisfy({ $0.isNumber || $0 == "." || $0 == ":" }) {
    return nil
}
```

The IP address check uses character-class filtering. While this catches `127.0.0.1` and `::1`, it does NOT catch:
- IPv6 in brackets: `http://[::1]/path` — `URL.host` returns `::1` without brackets, which IS caught by the colon check. OK, this one works.
- Hostnames like `0x7f000001` (hex IP encoding) — not caught.
- Hostnames resolving to internal IPs: `internal.corp.example.com` — not caught (but since requests go to Google, not directly to these hosts, the direct SSRF risk is low).

The actual risk is information disclosure to Google of internal hostnames, not direct SSRF.

**Impact:**
Internal/private domain names from the vault could be sent to Google's favicon service, revealing internal infrastructure details.

**Recommendation:**
Since requests go through Google's proxy, direct SSRF is not possible. But consider additionally filtering:
- RFC 1918 names (`.local`, `.internal`, `.corp`)
- Known private TLDs
- Or better: only allow domains with well-known public TLDs.

---

### LOW-1: Production logging of keychain status codes

**Severity:** LOW
**File:** `KeychainService.swift:97`

**Description:**
```swift
print("[KeychainService] hasStoredKey unexpected status: \(status)")
```

This `print()` statement is NOT gated behind `#if DEBUG`. It outputs keychain operation status codes to the device console in production builds. While `OSStatus` codes are not highly sensitive, they could reveal information about keychain state to anyone with console access.

**Impact:**
Minor information disclosure via device console logs.

**Recommendation:**
Wrap in `#if DEBUG` or use OSLog with `.private` privacy level:
```swift
#if DEBUG
print("[KeychainService] hasStoredKey unexpected status: \(status)")
#endif
```

---

### LOW-2: No brute-force throttling on password entry

**Severity:** LOW
**File:** `UnlockView.swift:114-121`, `CredentialProviderViewController.swift:99-109`

**Description:**
There is no delay or lockout after failed password attempts. An attacker with physical device access could attempt passwords as fast as Argon2 derivation allows.

**Mitigating factors:**
- Argon2 KDF provides implicit brute-force protection through computationally expensive key derivation (the parameters are set by the KDBX file creator).
- iOS device passcode provides a first layer of physical access protection.

**Impact:**
On a jailbroken device or via a security exploit, an attacker could automate password guessing limited only by Argon2 computation speed.

**Recommendation:**
Consider adding an exponential backoff after failed attempts (e.g., 1s, 2s, 4s, 8s...). This adds minimal UX friction for legitimate users while slowing automated attacks.

---

### LOW-3: No active screen recording detection

**Severity:** LOW
**File:** `ScreenProtectionService.swift`

**Description:**
The screen protection service shows a blur overlay when the app enters `.inactive` or `.background` state, which correctly prevents the app switcher thumbnail from showing sensitive data. However:

1. There is no detection of active screen recording (`UIScreen.main.isCaptured`).
2. While the app is in the foreground and unlocked, screen recording captures all visible passwords and TOTP codes.

**Impact:**
Screen recording or AirPlay mirroring while the vault is open captures all visible credentials.

**Recommendation:**
Monitor `UIScreen.capturedDidChangeNotification` and either:
- Show the blur shield while recording is active, or
- Display a warning banner to alert the user.

---

### LOW-4: AutoFill extension retains parsed entries in memory

**Severity:** LOW
**File:** `CredentialProviderViewController.swift:8,156`

**Description:**
```swift
private var parsedEntries: [KPEntry] = []
```

After the AutoFill extension decrypts the database, all entries with non-empty passwords are stored in `parsedEntries`. This array persists until the extension view controller is deallocated by the system, which may be significantly after the user completes the AutoFill interaction.

The extension has no auto-lock timer, unlike the main app.

**Impact:**
Parsed credentials linger in the extension's memory space after use.

**Recommendation:**
Clear `parsedEntries` after completing or canceling the request:
```swift
private func completeRequest(with entry: KPEntry) {
    parsedEntries = []  // clear immediately
    let credential = ASPasswordCredential(...)
    extensionContext.completeRequest(...)
}
```

---

### INFO-1: Keychain configuration is correct (positive finding)

**File:** `KeychainService.swift:28-35`

The Keychain access control is well-configured:
- `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` — item is only accessible when device is unlocked, and is NOT included in backups or device migrations.
- `.biometryCurrentSet` — item is invalidated when biometrics are re-enrolled (new fingerprint/face added), preventing an attacker from adding their own biometric.
- `LAContext` is passed for retrieval, ensuring biometric authentication is performed.

**Assessment:** This is correct and follows Apple's security best practices.

---

### INFO-2: Security-sensitive defaults are conservative (positive finding)

**File:** `SettingsService.swift`

- `autoLockTimeout` defaults to `.immediately` (line 60) — vault locks as soon as the app backgrounds. Most secure default.
- `clipboardTimeout` defaults to `.thirtySeconds` (line 70) — reasonable balance.
- `autoUnlockWithFaceID` defaults to `false` (line 81) — user must opt in.
- `showWebsiteIcons` defaults to `false` (line 90) — no privacy-leaking network requests by default.

**Assessment:** All defaults err on the side of security. Good.

---

### INFO-3: Cryptographic implementations are correct (positive finding)

**Files:** `KDBXCrypto.swift`, `KDBXParser.swift`, `TOTPGenerator.swift`

- **ChaCha20** quarter-round, column rounds, and diagonal rounds match RFC 7539.
- **KDBX4 key derivation** follows the specification: compositeKey → Argon2 → SHA256(masterSeed + transformedKey).
- **HMAC block verification** correctly uses per-block keys derived from SHA512(blockIndex + baseKey).
- **ChaCha20-Poly1305** outer decryption correctly uses CryptoKit's `ChaChaPoly`.
- **AES-256-CBC** decryption uses CommonCrypto with PKCS7 padding.
- **TOTP** generation follows RFC 6238 with correct HMAC truncation.

**Assessment:** The cryptographic primitives are correctly implemented. No algorithmic flaws found.

---

### INFO-4: Auto-lock timeout includes "Never" option

**File:** `SettingsService.swift:25`

The `AutoLockTimeout` enum includes a `.never` case. While this is a user choice and defaults to `.immediately`, the "Never" option means the vault stays unlocked indefinitely until the app is backgrounded (which triggers `lock()` in `KeeForgeApp.swift:23`).

Since backgrounding always locks regardless of the timer setting, the "Never" option only applies to idle time while the app is in the foreground. This is acceptable but worth noting.

---

## Files Reviewed

| File | Lines | Status |
|------|-------|--------|
| `KeeForge/Models/KDBXCrypto.swift` | 294 | Reviewed |
| `KeeForge/Models/KDBXParser.swift` | 929 | Reviewed |
| `KeeForge/Models/Entry.swift` | 87 | Reviewed |
| `KeeForge/Models/Group.swift` | 61 | Reviewed |
| `KeeForge/Models/TOTPGenerator.swift` | 83 | Reviewed |
| `KeeForge/Services/KeychainService.swift` | 115 | Reviewed |
| `KeeForge/Services/BiometricService.swift` | 40 | Reviewed |
| `KeeForge/Services/ClipboardService.swift` | 10 | Reviewed |
| `KeeForge/Services/SharedVaultStore.swift` | 41 | Reviewed |
| `KeeForge/Services/ScreenProtectionService.swift` | 76 | Reviewed |
| `KeeForge/Services/FaviconService.swift` | 156 | Reviewed |
| `KeeForge/Services/SettingsService.swift` | 96 | Reviewed |
| `KeeForge/Services/DocumentPickerService.swift` | 15 | Reviewed |
| `KeeForge/Services/CredentialMatcher.swift` | 42 | Reviewed |
| `KeeForge/Services/HapticService.swift` | 12 | Reviewed |
| `KeeForge/ViewModels/DatabaseViewModel.swift` | 329 | Reviewed |
| `KeeForge/ViewModels/TOTPViewModel.swift` | 41 | Reviewed |
| `KeeForge/Views/UnlockView.swift` | 150 | Reviewed |
| `KeeForge/Views/EntryDetailView.swift` | 335 | Reviewed |
| `KeeForge/Views/GroupListView.swift` | 145 | Reviewed |
| `KeeForge/Views/EntryListView.swift` | 18 | Reviewed |
| `KeeForge/Views/SearchView.swift` | 43 | Reviewed |
| `KeeForge/Views/SettingsView.swift` | 89 | Reviewed |
| `KeeForge/Views/FaviconView.swift` | 70 | Reviewed |
| `KeeForge/Extensions/NavigationConformances.swift` | 21 | Reviewed |
| `KeeForge/App/KeeForgeApp.swift` | 70 | Reviewed |
| `AutoFillExtension/CredentialProviderViewController.swift` | 235 | Reviewed |
| `KeeForge/KeeForge.entitlements` | 16 | Reviewed |
| `AutoFillExtension/AutoFillExtension.entitlements` | 16 | Reviewed |
| `KeeForge/Info.plist` | 39 | Reviewed |
| `AutoFillExtension/Info.plist` | 40 | Reviewed |

---

## Priority Remediation Order

1. **HIGH-3** — Clipboard `.localOnly` — One-line fix, immediate security improvement.
2. **HIGH-4** — Constant-time HMAC comparison — Small utility function, defense-in-depth.
3. **HIGH-1** — Memory zeroing for key material — Moderate effort, critical for a password manager.
4. **HIGH-2** — Secure string storage for passwords — Significant refactor, highest long-term impact.
5. **MEDIUM-4** — Negative block size validation — One-line fix.
6. **MEDIUM-2** — Decompression size limit — Small fix.
7. **MEDIUM-3** — File protection on favicon cache — One-line fix.
8. **LOW-4** — Clear AutoFill entries after use — Small fix.
9. **LOW-1** — Gate production logging — Small fix.
10. **MEDIUM-1** — Favicon privacy improvements — Larger effort, product decision.
