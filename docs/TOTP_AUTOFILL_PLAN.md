# TOTP AutoFill Implementation Plan

## Overview
Add one-time code (TOTP) AutoFill support so iOS suggests verification codes from KeeForge entries in the QuickType bar, just like passwords and passkeys.

## API (iOS 18+)
- `ASOneTimeCodeCredentialIdentity` — register TOTP entries in the credential identity store
- `ASOneTimeCodeCredential(code:)` — return the computed TOTP code
- Uses the same `ASCredentialProviderViewController` extension, same unlock flow

## Changes Required

### 1. CredentialIdentityStoreManager.swift
Add a new method to generate `ASOneTimeCodeCredentialIdentity` for entries with TOTP:

```swift
@available(iOS 18.0, *)
static func oneTimeCodeIdentity(for entry: KPEntry) -> ASOneTimeCodeCredentialIdentity? {
    guard entry.totpConfig != nil else { return nil }
    
    let allURLs = [entry.url] + entry.additionalURLs
    let domain = allURLs.compactMap(domainFromURLString).first
    guard let domain else { return nil }
    
    let label = entry.title.isEmpty ? entry.username : entry.title
    guard !label.isEmpty else { return nil }
    
    let serviceIdentifier = ASCredentialServiceIdentifier(identifier: domain, type: .domain)
    return ASOneTimeCodeCredentialIdentity(
        serviceIdentifier: serviceIdentifier,
        label: label,
        recordIdentifier: entry.id.uuidString
    )
}
```

Update `populate(with:)` to include one-time code identities in the `replaceCredentialIdentities` call (guarded by `#available(iOS 18.0, *)`). They must be included in the same atomic `replaceCredentialIdentities` call alongside password + passkey identities (otherwise it wipes the other types — this was a bug we fixed before).

### 2. CredentialProviderViewController.swift
Handle one-time code requests. The flow goes through the same `prepareInterfaceToProvideCredential(for: ASCredentialRequest)` and `provideCredentialWithoutUserInteraction(for: ASCredentialRequest)` methods that already exist.

Add detection for `ASOneTimeCodeCredentialRequest`:

```swift
// In prepareInterfaceToProvideCredential(for credentialRequest:)
if #available(iOS 18.0, *), let otcRequest = credentialRequest as? ASOneTimeCodeCredentialRequest {
    // Store the request, trigger unlock flow
    pendingOTCRequest = otcRequest
    targetRecordIdentifier = otcRequest.credentialIdentity.recordIdentifier
    pendingUnlock = true
    return
}

// In provideCredentialWithoutUserInteraction(for credentialRequest:)
if #available(iOS 18.0, *), let otcRequest = credentialRequest as? ASOneTimeCodeCredentialRequest {
    provideOTCWithoutUserInteraction(for: otcRequest)
    return
}
```

Add the completion method:

```swift
@available(iOS 18.0, *)
private func completeOTCRequest(with entry: KPEntry) {
    guard let totpConfig = entry.totpConfig,
          let sessionKey = sessionKey else {
        cancelRequest(code: .failed)
        return
    }
    
    let code = TOTPGenerator.generateCode(config: totpConfig, sessionKey: sessionKey)
    guard code != "------" else {
        cancelRequest(code: .failed)
        return
    }
    
    let credential = ASOneTimeCodeCredential(code: code)
    cleanup()
    extensionContext.completeOneTimeCodeRequest(using: credential)
}
```

Update `afterUnlock()` to handle pending OTC requests.

### 3. Entry.swift
Add a computed property for convenience:

```swift
var hasTOTP: Bool { totpConfig != nil }
```

### 4. AutoFillExtension/Info.plist (or entitlements)
Verify that `ASCredentialProviderExtensionCapabilities` includes `ProvidesOneTimeCodes = YES` (or the modern equivalent in the extension's Info.plist). This tells iOS that the extension supports one-time codes.

### 5. loadEntries filter
Currently `loadEntries` filters to `$0.hasPassword || $0.hasPasskey`. Update to also include entries with TOTP:
```swift
parsedEntries = allEntries.filter { $0.hasPassword || $0.hasPasskey || $0.hasTOTP }
```

### 6. Tests
- Test `oneTimeCodeIdentity(for:)` generates correct identities
- Test entries with TOTP but no password are included in parsed entries
- Test TOTP code generation in the extension context (unit test the flow)

## iOS Version Handling
- `ASOneTimeCodeCredentialIdentity` and `ASOneTimeCodeCredential` require iOS 18.0+
- All new code must be guarded with `@available(iOS 18.0, *)` / `if #available(iOS 18.0, *)`
- The app's minimum deployment target stays at iOS 17
- On iOS 17, TOTP entries simply won't appear in the QuickType bar (graceful degradation)

## What NOT to change
- TOTPGenerator.swift — already works perfectly
- In-app TOTP display — unrelated to AutoFill
- Existing password/passkey AutoFill flows — only additive changes
