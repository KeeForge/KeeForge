# Favicon Feature — Design Spec

## Goal

Display website favicons next to entries in group lists, entry detail, search results, and AutoFill. Makes it much easier to visually identify entries at a glance.

## Opt-in

Favicons require network requests, which breaks KeeForge's current zero-network policy. This must be:
- **Off by default** — new toggle in Settings: "Show Website Icons"
- Stored in `SettingsService` (standard UserDefaults, not shared — AutoFill can have its own toggle or inherit)
- When off, show the existing KeePass icon (key/globe/etc based on `iconID`)

## Favicon Source

Use Google's favicon service (most reliable, no API key needed):

```
https://www.google.com/s2/favicons?domain={domain}&sz=64
```

- Extract domain from entry's primary URL (`entry.url`)
- If entry has no URL, skip (use default icon)
- Request 64×64 size (good for 2x/3x retina, small file size)

### Alternatives considered
- **DuckDuckGo:** `https://icons.duckduckgo.com/ip3/{domain}.ico` — works but lower quality
- **Direct site fetch:** Download `/favicon.ico` from each site — slow, unreliable, potential security concern
- **Self-hosted:** Overkill for v1

## Caching

Use a simple disk cache to avoid re-fetching on every app launch:

```swift
FaviconService {
    // Cache location: App Group container (shared with AutoFill)
    // ~/Library/Group Containers/group.com.keevault.shared/favicons/
    
    func favicon(for domain: String) async -> UIImage?
    func prefetch(domains: [String]) async  // batch on unlock
}
```

- **Cache key:** SHA256 of domain → filename (avoids filesystem issues)
- **TTL:** 7 days — refetch after expiry
- **Max cache size:** ~50MB (with ~1-3KB per icon, supports ~15K-50K entries)
- **Cache miss:** Return nil immediately, show placeholder, fetch in background, update UI when ready

## UI Integration

### GroupListView / EntryListView
- Replace the SF Symbol icon with an `AsyncImage`-style view
- Fallback chain: cached favicon → fetch favicon → KeePass `iconID` → generic key icon
- 24×24 display size, rounded corners (4pt radius)

### EntryDetailView
- Larger favicon (40×40) next to entry title
- Same fallback chain

### SearchView
- Same as list view (24×24)

### AutoFill
- Show favicon in credential list if setting is enabled
- Read from shared cache (App Group container)

## View Component

```swift
struct FaviconView: View {
    let url: String?        // entry URL
    let iconID: Int         // KeePass icon ID fallback
    let size: CGFloat       // display size
    
    // Internally:
    // 1. Extract domain from URL
    // 2. Check FaviconService cache
    // 3. Show cached image or placeholder
    // 4. Fetch in background if cache miss
    // 5. Animate in when loaded
}
```

## Privacy / Security

- Only the **domain** is sent to Google (not full URL, not credentials)
- User must explicitly opt in
- No favicons fetched while locked
- Cache is local only, in App Group container
- Clear cache option in Settings (nice-to-have)

## Implementation Plan

1. `FaviconService` — fetch + disk cache with TTL
2. `FaviconView` — SwiftUI component with fallback chain
3. Settings toggle — "Show Website Icons" in Display section
4. Wire into GroupListView, EntryListView, EntryDetailView, SearchView
5. Wire into AutoFill credential list
6. Tests — unit test for cache logic, URL domain extraction
7. Update AGENTS.md with favicon architecture notes

## Out of Scope (for now)

- Custom icon upload
- Caching inside the .kdbx file
- Passkey/WebAuthn icons
- Per-entry icon override
