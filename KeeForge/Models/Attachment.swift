import Foundation

/// A reference to a binary attachment stored in the KDBX4 inner-header binary
/// pool. Only the name and pool index are modeled here; the actual bytes are
/// resolved on demand via `BinaryPool`.
struct KPAttachment: Sendable, Hashable {
    /// Attachment file name as stored in `<Binary><Key>`. Preserved verbatim,
    /// even if empty, for round-trip fidelity.
    var name: String
    /// Index into the inner-header binary pool (`<Binary Value Ref="N"/>`).
    var ref: Int
    /// Number of other structured (known) `<Entry>` children that preceded
    /// this `<Binary>` element in the source document, i.e. the entry's
    /// `knownChildCount` at the moment this element was parsed. The writer
    /// uses this to re-emit `<Binary>` at its original position relative to
    /// sibling known elements and opaque XML, the same mechanism used for
    /// `OpaqueXMLNodes`. Defaults to 0 for attachments created in-app (e.g.
    /// newly attached files), which places them right before `<History>`.
    var insertionIndex: Int = 0
}

/// Lazily decodes the KDBX4 inner-header binary pool.
///
/// Each pool entry is stored by `KDBXParser` as raw `Data` that still includes
/// the leading 1-byte memory-protection flag (`0x01` = protected). Pool bytes
/// are never eagerly copied out of `header.innerHeaderBinaryFields`; decoding
/// happens per item, on subscript access.
struct BinaryPool: Sendable {
    /// A single decoded pool item.
    struct Item: Sendable, Hashable {
        /// Whether the pool entry carries the memory-protection hint
        /// (first byte == 0x01). This is a KDBX4 inner-header convention, not
        /// an indication that `data` is stream-cipher encrypted — pool
        /// content itself is stored in the clear in KDBX4.
        let isProtected: Bool
        /// Raw attachment bytes, excluding the leading flag byte.
        let data: Data
    }

    /// Raw inner-header binary fields, each still including its leading
    /// 1-byte flag. Stored as-is so the writer can re-emit them verbatim.
    private let rawFields: [Data]

    init(rawFields: [Data]) {
        self.rawFields = rawFields
    }

    var count: Int {
        rawFields.count
    }

    var isEmpty: Bool {
        rawFields.isEmpty
    }

    /// Decodes the pool entry at `ref`, or `nil` if the ref is out of range
    /// (a dangling reference, which is tolerated rather than treated as an
    /// error).
    subscript(ref: Int) -> Item? {
        guard rawFields.indices.contains(ref) else { return nil }
        let raw = rawFields[ref]
        guard let flag = raw.first else {
            return Item(isProtected: false, data: Data())
        }
        return Item(isProtected: flag == 0x01, data: raw.dropFirst())
    }
}
