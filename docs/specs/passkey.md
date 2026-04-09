# Passkey Support — Implementation Plan

## Overview

Passkeys (FIDO2/WebAuthn) allow passwordless authentication using public-key cryptography. Instead of sending a password to a server, the client proves possession of a private key. The server only stores the public key.

**Scope:** KeeForge would act as a **passkey provider** on iOS — storing passkey credentials in the KDBX database and responding to authentication/registration requests from Safari and apps.

## How Passkeys Are Stored in KDBX (KeePassXC Format)

KeePassXC established a de facto standard using custom string fields on entries:

| Custom Field | Description |
|---|---|
| `KPEX_PASSKEY_CREDENTIAL_ID` | Base64URL-encoded credential ID |
| `KPEX_PASSKEY_PRIVATE_KEY_PEM` | ECDSA P-256 private key in PEM format (protected) |
| `KPEX_PASSKEY_RELYING_PARTY` | Relying party ID (e.g. `google.com`) |
| `KPEX_PASSKEY_USERNAME` | Username associated with the passkey |
| `KPEX_PASSKEY_USER_HANDLE` | Base64URL-encoded user handle from the server |

The entry's **URL** field contains the relying party URL, and **Username** matches `KPEX_PASSKEY_USERNAME`.

KeePassDX (Android) follows the same field naming convention for cross-client compatibility.

## iOS Passkey Provider API

Since iOS 17, third-party apps can act as passkey providers via `ASCredentialProviderViewController`:

### Registration (Creating a Passkey)
```swift
// Called when a website requests passkey creation
func prepareInterface(forPasskeyRegistration registrationRequest: ASCredentialRequest)
```
1. Generate EC P-256 key pair
2. Build attestation object (none/self attestation)
3. Store credential in KDBX entry (custom fields above)
4. Return `ASPasskeyRegistrationCredential` to the system

### Authentication (Using a Passkey)
```swift
// Called when a website requests passkey authentication
func prepareInterfaceToProvideCredential(for credentialRequest: ASCredentialRequest)

// Silent auth (no UI) — used for QuickType suggestions
func provideCredentialWithoutUserInteraction(for credentialRequest: ASCredentialRequest)
```
1. Find matching entry by relying party + credential ID
2. Load private key from `KPEX_PASSKEY_PRIVATE_KEY_PEM`
3. Sign the client data hash with the private key
4. Return `ASPasskeyAssertionCredential` to the system

### Required Capabilities
In the AutoFill extension's Info.plist:
```xml
<key>ASCredentialProviderExtensionCapabilities</key>
<dict>
    <key>ProvidesPasskeys</key>
    <true/>
    <key>ProvidesPasswords</key>
    <true/>
</dict>
```

### Credential Identity Store
Register passkey identities for QuickType bar suggestions:
```swift
let passkeyIdentity = ASPasskeyCredentialIdentity(
    relyingPartyIdentifier: "example.com",
    userName: "alex@example.com",
    credentialID: credentialIDData,
    userHandle: userHandleData
)
ASCredentialIdentityStore.shared.saveCredentialIdentities([passkeyIdentity])
```

## Implementation Phases

### Phase 1: Passkey Model & Detection (~2 hours)
**Read-only**: detect and display existing passkeys in KDBX entries

- Create `PasskeyCredential` model struct
- Parse `KPEX_PASSKEY_*` custom fields from entries
- Show passkey info in entry detail view (relying party, username, credential ID)
- Add passkey icon/badge to entry list for passkey entries

### Phase 2: Passkey Authentication (~6 hours)
**Use existing passkeys** to authenticate

- Extend AutoFill extension to handle `ASCredentialRequest` for passkeys
- Register `ASPasskeyCredentialIdentity` in the credential store alongside passwords
- Implement `provideCredentialWithoutUserInteraction(for:)` for silent passkey auth
- Implement `prepareInterfaceToProvideCredential(for:)` for interactive passkey auth
- Load PEM private key → create SecKey → sign assertion
- Build `ASPasskeyAssertionCredential` response
- Add `ProvidesPasskeys` to Info.plist capabilities

**Crypto needed:**
- Parse PEM EC P-256 private key → `SecKey` (via `SecKeyCreateWithData`)
- ECDSA-SHA256 signing of authenticator data + client data hash
- Build authenticator data (RP ID hash, flags, sign counter)

### Phase 3: Passkey Registration (~4 hours)
**Create new passkeys** — requires KDBX write support

- Generate EC P-256 key pair (`SecKeyCreateRandomKey`)
- Export private key as PEM
- Create new KDBX entry with `KPEX_PASSKEY_*` custom fields
- Build attestation object (packed self-attestation or none)
- Return `ASPasskeyRegistrationCredential`
- Save modified KDBX to disk

**⚠️ Blocker:** KeeForge is currently read-only. Passkey registration requires writing to the KDBX file (creating new entries). This is the biggest dependency.

### Phase 4: Entry Detail UI (~2 hours)
- Show passkey details in entry detail view
- "Use Passkey" button (manual trigger)
- Passkey metadata: relying party, username, creation date, last used

## Dependencies & Blockers

| Dependency | Status | Notes |
|---|---|---|
| KDBX write support | ❌ Not implemented | Required for Phase 3 (registration). Phase 1-2 work without it. |
| iOS 17+ | ✅ Already minimum target | Passkey provider API available |
| AutoFill extension | ✅ Exists | Needs extension for passkey capability |
| EC P-256 crypto | ✅ Available | `Security.framework` / `CryptoKit` |

## Estimated Effort

| Phase | Effort | Can Ship Independently? |
|---|---|---|
| Phase 1: Detection & Display | ~2 hours | ✅ Yes — shows passkey entries from KeePassXC |
| Phase 2: Authentication | ~6 hours | ✅ Yes — use passkeys created in KeePassXC |
| Phase 3: Registration | ~4 hours | ❌ Needs KDBX write support |
| Phase 4: UI polish | ~2 hours | ✅ Yes |
| **Total** | **~14 hours** | |

## Recommended Approach

**Ship Phase 1+2 first** (v1.5.0) — users who create passkeys in KeePassXC can use them for authentication on iOS via KeeForge. This is valuable on its own and doesn't require write support.

**Phase 3 deferred** to when KDBX write support is implemented (needed for entry editing too).

## Complexity Assessment

**Medium-Large feature.** The crypto and WebAuthn protocol are well-documented, but the iOS credential provider API has subtle requirements:
- Attestation format must be correct or servers reject
- Authenticator data encoding is fiddly (bit flags, CBOR)
- Need to handle both conditional UI (QuickType) and modal flows
- Testing requires a real WebAuthn-enabled website

Compared to key file support (~7 hours), passkeys are roughly 2x the effort.

## References

- [Apple: ASCredentialProviderViewController](https://developer.apple.com/documentation/authenticationservices/ascredentialproviderviewcontroller)
- [KeePassXC PR #8825 — WebAuthn support](https://github.com/keepassxreboot/keepassxc/pull/8825)
- [KeePassDX Wiki — Passkeys](https://github.com/Kunzisoft/KeePassDX/wiki/Passkeys)
- [KeePassium Issue #297 — Passkey support](https://github.com/keepassium/KeePassium/issues/297)
- [WebAuthn Spec](https://www.w3.org/TR/webauthn-2/)
- [PassKeeZ — FIDO2 authenticator using KDBX](https://codeberg.org/r4gus/PassKeeZ)
