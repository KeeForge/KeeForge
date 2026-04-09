# Cloud File AutoFill Research

Research findings for the cloud-hosted .kdbx AutoFill bug described in [CLOUD_FILE_AUTOFILL_BUG.md](CLOUD_FILE_AUTOFILL_BUG.md).

Date: 2026-03-08

---

## 1. Can an AutoFill Extension Resolve Security-Scoped Bookmarks for Cloud Files?

**No — security-scoped bookmarks cannot be resolved cross-process.**

Apple's sandbox model enforces that only the process that created a security-scoped bookmark can resolve it. An app extension (like an AutoFill Credential Provider) runs in a separate process with its own sandbox. Key findings:

- Per [Apple Developer Forums](https://developer.apple.com/forums/thread/66259): security-scoped bookmarks are bound to the creating process. No other sandboxed process can resolve them.
- A non-security-scoped ("implicit") bookmark *can* be resolved cross-process, but for cloud file provider URLs, the security scope is what grants access to the file — without it, the URL is useless.
- [iOS 17.3 broke even local file references](https://github.com/keepassium/KeePassium/issues/338) for KeePassium's AutoFill extension, where sandbox references resolved to the extension's own documents folder instead of the main app's. Apple fixed this in iOS 17.4, but it illustrates how fragile cross-process file access is.

**Conclusion:** The bookmark-based approach is fundamentally broken for cloud files in extensions. The extension cannot resolve the main app's security-scoped bookmark for a Google Drive / OneDrive / Dropbox URL.

## 2. What Do Other KeePass iOS Apps Do?

### KeePassium (open source, [GitHub](https://github.com/keepassium/KeePassium))

KeePassium uses a **local cache + remote fetch** architecture:

- **FileKeeper** maintains backup copies of every database loaded. When a cloud database is opened, a local backup is saved.
- **AutoFill Quick Mode** prefers the local cached copy of the database for speed. The cached copy lives in the App Group shared container, accessible to both the main app and the AutoFill extension.
- For full AutoFill (non-Quick mode), KeePassium attempts to fetch the remote database file directly. This requires the extension to have its own file access — KeePassium re-adds database references to the extension via shared URLReference objects in the App Group.
- Staleness is handled by configuration: users can set timeout behavior ("Consider File Unreachable → Immediately" falls back to cache; "If File is Unreachable → Use Local Copy").
- KeePassium stores the cached/backup database for up to 2 months by default.

**Key takeaway:** KeePassium copies the .kdbx file to the App Group container as a cache. The extension reads from the cache when it can't access the remote file.

### Strongbox ([GitHub](https://github.com/strongbox-password-safe/Strongbox))

Strongbox uses a similar approach:

- Maintains local copies of databases in a shared container accessible to the AutoFill extension.
- Explicitly documents that "Apple does not allow App Extensions to access the parent App's documents directory directly" — key files must be re-added for the extension to use them.
- For iCloud, uses a dedicated Strongbox folder that the system syncs automatically.

### Bitwarden ([architecture docs](https://deepwiki.com/bitwarden/mobile/4.2-autofill-extension))

Bitwarden takes a different approach since it's not file-based:

- Uses a **shared encrypted database** (LiteDB) in the App Group container (`group.com.8bit.bitwarden`).
- The main app syncs credentials from the server into this shared database.
- The AutoFill extension reads encrypted credentials from the shared database and decrypts on-demand using keys from the shared Keychain Access Group.
- Never reads raw vault files — all data is pre-processed and stored in the shared container.

**Key takeaway:** Bitwarden avoids the file access problem entirely by pre-caching all credentials in a shared database + keychain.

## 3. Does Apple Provide APIs for Extensions to Access File Provider URLs?

**No dedicated API exists for this use case.**

- The **File Provider** framework (`NSFileProviderExtension`) is for *providing* files to the system, not for *consuming* cloud files from another provider within an extension.
- Extensions can use `UIDocumentPickerViewController` to request file access, but this requires user interaction — not suitable for AutoFill which must work non-interactively.
- There is no API that lets an extension silently access a file from a third-party file provider (Google Drive, etc.).

## 4. Would NSFileCoordinator Work in the Extension for Cloud Files?

**No, not for the initial access problem.**

- `NSFileCoordinator` coordinates reads/writes between processes for files *both processes already have access to*. It does not grant access — it coordinates access.
- The extension's problem is not coordination; it's that the extension lacks permission to access the cloud file URL at all.
- Apple's [TN2408](https://developer.apple.com/library/archive/technotes/tn2408/_index.html) warns about file coordination deadlocks in extensions (fixed in iOS 8.2+, but the caution about extension lifecycle remains valid).

**NSFileCoordinator is irrelevant here.** The extension needs the file to be in a location it can already access (like the App Group container).

## 5. Copying the File to App Group Container — Is This the Right Approach?

**Yes. This is the industry-standard approach.** Both KeePassium and Strongbox do this.

### Implementation Strategy

1. When the main app opens a .kdbx from a cloud provider, **copy the file data to the App Group container** (e.g., `group.com.keevault.shared/databases/`).
2. Store metadata (original URL bookmark, last-copied timestamp, file hash) alongside the copy.
3. The AutoFill extension reads from the App Group copy — always accessible, no sandbox issues.

### Staleness / Sync Gotchas

| Concern | Mitigation |
|---------|------------|
| User edits .kdbx on desktop, syncs via cloud | Re-copy on main app launch / foreground. Compare file hash to detect changes. |
| User edits in KeeForge, needs to sync back | Write to App Group copy AND save back to the original bookmarked URL (if the main app has access). |
| Extension reads stale data | Acceptable tradeoff — cached credentials are better than no credentials. Surface "last synced" info to user. |
| File size | .kdbx files are typically <10 MB. Not a concern for App Group storage. |
| Multiple databases | Store each with a unique identifier (UUID or hash of the original URL). |

### When to Refresh the Cache

- **Main app foreground:** Always attempt to re-read the cloud file and update the cache.
- **Main app unlock:** After decrypting, update `ASCredentialIdentityStore` AND refresh the cached file.
- **Background refresh:** Consider `BGAppRefreshTask` to periodically update the cache (limited by iOS, but useful).
- **Manual refresh:** Provide a "Sync Now" option in the main app.

## 6. Alternative: Cache Decrypted Credentials Instead of the File?

**This is the Bitwarden approach and could be simpler for KeeForge.**

### How It Would Work

1. When the user unlocks the database in the main app, extract all credential entries.
2. Store them encrypted in the **App Group keychain** or as an encrypted blob in the **App Group container**.
3. The AutoFill extension decrypts the cached credentials using a key from the shared keychain — never needs the .kdbx file.

### Pros

- Extension never needs file access at all — simplest sandbox story.
- Faster AutoFill — no .kdbx parsing/decryption in the extension.
- No staleness concern for the *file* — credentials are refreshed every time the user unlocks in the main app.
- Works identically for local and cloud files.

### Cons

- **Two sources of truth:** The .kdbx file is the canonical source, but the cache is a derivative. Changes made outside KeeForge (e.g., on desktop) won't appear until the user opens the main app and unlocks.
- **Data duplication:** Credentials exist in both the .kdbx and the cache. Must be careful about cache invalidation.
- **Partial data:** AutoFill only needs username/password/URL/passkey. Attachments, notes, custom fields don't need caching. But the cached format must be maintained separately.
- **Security surface:** Decrypted (or re-encrypted) credentials in the keychain/container are a separate attack surface from the .kdbx master-key encryption.

### Recommendation

This approach is **viable and arguably better** for a v1 implementation, since KeeForge already populates `ASCredentialIdentityStore` with credential metadata on unlock. The gap is that `ASCredentialIdentityStore` only stores *identities* (username + service), not the actual passwords/passkeys. Extending this to also cache the secrets would close the gap.

---

## Recommended Approach for KeeForge

### Short-term (v1): Hybrid — Cache credentials + copy file

1. **Cache decrypted credentials in App Group keychain** on every unlock in the main app:
   - Store: `{ serviceIdentifier, username, password, passkey }` per entry
   - Encrypt with a key derived from the user's master password or biometric-protected keychain item
   - The AutoFill extension reads from this cache — no file access needed

2. **Also copy the .kdbx to the App Group container** as a fallback:
   - If the credential cache is missing or invalidated, the extension can fall back to decrypting the .kdbx copy
   - This handles edge cases (cache corruption, first-time extension launch before main app unlock)

3. **Refresh strategy:**
   - On main app unlock: update credential cache + re-copy .kdbx from cloud
   - On main app foreground: check if cloud file is newer (compare bookmark → read → hash)
   - Show "last synced" timestamp in the UI

### Long-term (v2): Consider removing file dependency entirely

- Move toward the Bitwarden model where the extension is fully independent of the .kdbx file
- All credential data lives in a shared encrypted store
- The .kdbx is treated as an import/export format, not the live data source

---

## Summary Table

| Question | Answer |
|----------|--------|
| Can extension resolve cloud bookmarks? | **No** — sandbox prevents cross-process bookmark resolution |
| What do KeePassium/Strongbox do? | Copy .kdbx to App Group container as cache |
| What does Bitwarden do? | Cache encrypted credentials in App Group shared DB + keychain |
| Apple APIs for extension cloud file access? | **None** — no silent file provider access for extensions |
| NSFileCoordinator in extension? | **Irrelevant** — doesn't grant access, only coordinates |
| Copy to App Group? | **Yes** — industry standard, proven approach |
| Cache credentials instead? | **Yes** — simpler, faster, avoids file access entirely |

## Sources

- [Apple: Security-Scoped Bookmarks](https://developer.apple.com/documentation/professional-video-applications/enabling-security-scoped-bookmark-and-url-access)
- [Apple Forums: Share security scoped bookmark](https://developer.apple.com/forums/thread/66259)
- [Apple: TN2408 - Sharing data between app and extension](https://developer.apple.com/library/archive/technotes/tn2408/_index.html)
- [Apple: Credential Provider Extensions](https://support.apple.com/en-gb/guide/security/sec6319ac7b9/web)
- [KeePassium GitHub](https://github.com/keepassium/KeePassium)
- [KeePassium iOS 17.3 AutoFill issue](https://github.com/keepassium/KeePassium/issues/338)
- [KeePassium local cache discussion](https://github.com/keepassium/KeePassium/issues/391)
- [Strongbox GitHub](https://github.com/strongbox-password-safe/Strongbox)
- [Bitwarden AutoFill Extension Architecture](https://deepwiki.com/bitwarden/mobile/4.2-autofill-extension)
- [iOS Extension Data Sharing](https://dmtopolog.com/ios-app-extensions-data-sharing/)
