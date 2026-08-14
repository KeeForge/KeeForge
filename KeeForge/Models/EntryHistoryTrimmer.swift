import CryptoKit
import Foundation

/// The database's `HistoryMaxItems` / `HistoryMaxSize` policy, in one place.
///
/// `DatabaseDraft` applies it whenever an edit pushes a version, and the merge
/// engine re-applies it to the union of two sides' histories. Both have to
/// decide *which* versions survive the same way, or a merged file would keep
/// versions a plain edit would have discarded.
///
/// Which versions survive is decided by recency; the survivors keep their
/// storage order. Deciding by position instead would discard the newest
/// versions of a KeePass-authored file, whose `<History>` is oldest-first where
/// this app prepends, and reordering the array would rewrite a foreign file's
/// bytes on every save.
enum EntryHistoryTrimmer {
    /// `snapshot` prepended to `existing`, trimmed. Every stored version is
    /// cloned without its own history first, as KDBX requires.
    static func trimmed(
        appending snapshot: KPEntry,
        existing: [KPEntry],
        meta: KPMeta,
        sessionKey: SymmetricKey
    ) -> [KPEntry] {
        trimmed(([snapshot] + existing).map { $0.cloneForHistory() }, meta: meta, sessionKey: sessionKey)
    }

    /// The versions of `history` that fit the database's limits, in the order
    /// they were given.
    static func trimmed(_ history: [KPEntry], meta: KPMeta, sessionKey: SymmetricKey) -> [KPEntry] {
        let survivors = survivingIndices(of: history, meta: meta, sessionKey: sessionKey)
        return history.indices.filter { survivors.contains($0) }.map { history[$0] }
    }

    static func survivingIndices(
        of history: [KPEntry],
        meta: KPMeta,
        sessionKey: SymmetricKey
    ) -> Set<Int> {
        let byRecency = recencyOrderedIndices(of: history)
        var survivors = Set(history.indices)

        let maxItems = meta.resolvedHistoryMaxItems
        if maxItems >= 0, history.count > maxItems {
            survivors = Set(byRecency.prefix(maxItems))
        }

        let maxSize = meta.resolvedHistoryMaxSize
        if maxSize >= 0 {
            var retained: Set<Int> = []
            var sizeSoFar: Int64 = 0

            for index in byRecency where survivors.contains(index) {
                let entrySize = estimatedSize(of: history[index], sessionKey: sessionKey)
                if sizeSoFar + entrySize > maxSize {
                    break
                }
                retained.insert(index)
                sizeSoFar += entrySize
            }

            survivors = retained
        }

        return survivors
    }

    /// Storage indices newest first, matching `DatabaseViewModel.history(forEntryID:)`:
    /// versions without a timestamp sort last, and ties fall back to storage order so
    /// second-resolution KDBX timestamps still give a total order.
    static func recencyOrderedIndices(of history: [KPEntry]) -> [Int] {
        history.indices.sorted { lhs, rhs in
            switch (history[lhs].lastModificationTime, history[rhs].lastModificationTime) {
            case let (left?, right?): return left == right ? lhs < rhs : left > right
            case (nil, _?): return false
            case (_?, nil): return true
            case (nil, nil): return lhs < rhs
            }
        }
    }

    static func estimatedSize(of entry: KPEntry, sessionKey: SymmetricKey) -> Int64 {
        var size = Int64(256)
        size += Int64(entry.title.utf8.count)
        size += Int64(entry.username.utf8.count)
        size += Int64(entry.url.utf8.count)
        size += Int64(entry.notes.utf8.count)
        size += Int64(entry.tags.joined(separator: ",").utf8.count)
        size += Int64(entry.otpURL?.utf8.count ?? 0)

        if let password = try? entry.password.decrypt(using: sessionKey) {
            size += Int64(password.utf8.count)
        } else {
            size += Int64(entry.password.sealedData.count)
        }

        for (key, value) in entry.customFields {
            size += Int64(key.utf8.count + value.utf8.count)
        }

        if let passkeyPrivateKey = entry.passkeyPrivateKey {
            // Sealed size approximates the PEM length without decrypting.
            size += Int64(passkeyPrivateKey.sealedData.count)
        }

        if let totpConfig = entry.totpConfig {
            if let secret = try? totpConfig.secret.decrypt(using: sessionKey) {
                size += Int64(secret.utf8.count)
            } else {
                size += Int64(totpConfig.secret.sealedData.count)
            }
            size += Int64(String(totpConfig.period).utf8.count)
            size += Int64(String(totpConfig.digits).utf8.count)
            size += Int64(totpConfig.algorithm.rawValue.utf8.count)
        }

        for node in entry.unknownXML.nodes {
            size += Int64(node.xml.utf8.count)
            size += Int64(node.path.joined(separator: "/").utf8.count)
        }

        for key in entry.protectedStringKeys {
            size += Int64(key.utf8.count)
        }

        return size
    }
}
