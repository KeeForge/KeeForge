# KeeForge Security Audit (Codex)

Date: 2026-03-03
Scope: Reviewed all Swift files under `KeeForge/`, `AutoFillExtension/`, `KeeForgeTests/`, and `KeeForgeUITests/`.

## Executive Summary

- Critical: 0
- High: 2
- Medium: 3
- Low: 0

Main risk themes were untrusted KDBX parsing hardening and AutoFill domain-matching correctness.

## Findings

### 1) [HIGH] Malformed KDBX can crash parser before authentication checks

**Evidence**
- `KeeForge/Models/KDBXParser.swift:254-255` calls `parseVariantMap` on untrusted header bytes.
- `KeeForge/Models/KDBXParser.swift:311`, `:313`, `:317`, `:319` call `loadUnaligned(...)` without validating `valData.count`.
- `KeeForge/Models/KDBXParser.swift:315` reads `valData[0]` without emptiness checks.
- `KeeForge/Models/KDBXParser.swift:473-477` (`DataReader.readBytes`) truncates silently instead of throwing on short reads.

**Impact**
A crafted/truncated `.kdbx` file can trigger out-of-bounds preconditions and crash the app/extension (denial of service) during unlock.

**Recommendation**
- Make `DataReader` throw on short reads for fixed-width fields.
- Validate exact lengths for each variant-map value type before decoding.
- Treat malformed KDF variant-map fields as parse errors, not best-effort decoding.

---

### 2) [HIGH] Argon2 parameters are unbounded and can force resource exhaustion/crash

**Evidence**
- `KeeForge/Models/KDBXParser.swift:352-354` reads `I`, `M`, `P` directly from file-controlled KDF params.
- `KeeForge/Models/KDBXParser.swift:359-361` converts to `UInt32` with no bounds checks.
- `KeeForge/Models/KDBXParser.swift:133` derives key before header HMAC verification (`:149-153`).

**Impact**
An attacker can supply extreme KDF parameters in a malicious file to cause very high CPU/memory usage or conversion traps, resulting in DoS during unlock attempts.

**Recommendation**
- Enforce strict upper/lower bounds on Argon2 `iterations`, `memory`, and `parallelism`.
- Reject KDF params outside an allowlisted security/performance envelope.
- Guard integer conversions explicitly and fail closed on overflow.

---

### 3) [MEDIUM] Over-broad AutoFill matching can return credentials for the wrong site

**Evidence**
- `KeeForge/Services/CredentialMatcher.swift:18-23` matches by URL substring and title substring, not only canonical host/domain rules.
- `AutoFillExtension/CredentialProviderViewController.swift:59-64` and `:227-229` can auto-select first/single match.

**Impact**
Credentials can be considered matches when domain relation is weak (substring/title-only), increasing risk of wrong-account autofill and unintended credential disclosure in AutoFill flows.

**Recommendation**
- Remove substring/title matching from security decisions.
- Match only normalized host/domain rules (exact host or carefully bounded parent-domain logic).
- Require explicit user selection when multiple trust-equivalent matches exist.

---

### 4) [MEDIUM] Keychain key namespace collides across databases with same filename

**Evidence**
- `KeeForge/Services/KeychainService.swift:10-13` derives keychain account from `lastPathComponent` only.
- Storage/retrieval operations (`:15-23`, `:51-58`) depend on this derived account key.

**Impact**
Two different vault files with the same filename share one keychain slot, causing overwrite/confusion and potentially biometric unlock failures or unintended key reuse behavior.

**Recommendation**
- Use a stable collision-resistant identifier (e.g., bookmark-derived file ID hash, security-scoped bookmark hash, or full canonicalized URL hash) instead of filename-only keying.

---

### 5) [MEDIUM] Registered-domain extraction relies on incomplete static suffix list

**Evidence**
- `KeeForge/Services/CredentialIdentityStoreManager.swift:105-159` uses a hand-maintained `knownMultiPartTLDs` set.
- `:78-83` writes this derived domain into `ASPasswordCredentialIdentity`.

**Impact**
Domains on unlisted public suffix patterns can be collapsed incorrectly (cross-tenant association risk), which may surface credentials in unrelated contexts.

**Recommendation**
- Prefer host-level matching for identity storage, or integrate a full Public Suffix List based parser.
- Add regression tests for multi-tenant suffixes (for example `*.github.io`, `*.appspot.com`, etc.).

## Positive Security Controls Observed

- Per-session secret wrapping via `EncryptedValue` (`AES.GCM`) and session-key invalidation on lock.
- Keychain storage uses `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` with biometric access control.
- Clipboard copy is `localOnly` with expiry.
- KDBX HMAC checks use constant-time equality.

