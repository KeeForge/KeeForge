# KDBXXML

The KeePass database XML in Swift: reads the decrypted `<KeePassFile>` payload of a KDBX 3.1 or 4.x file into typed values and writes it back, keeping every element it does not model where it was. Pair it with [KDBXKit](../KDBXKit), which decrypts and encrypts the container around the XML.

Swift 6, iOS 18+ / macOS 15+. Depends on KDBXKit for the protected-value stream.

## Reading

```swift
import KDBXKit
import KDBXXML

let payload = try KDBXContainer.read(data: fileData, compositeKey: compositeKey, kdfPolicy: policy)
let document = try KDBXDocument.read(
    xml: payload.xml,
    innerStreamID: payload.header.innerStreamID,
    innerStreamKey: payload.header.innerStreamKey
)

for group in document.root.groups {
    for entry in group.entries {
        let title = entry.strings.last { $0.key == "Title" }?.value
        let password = entry.strings.last { $0.key == "Password" }?.value // plaintext, unmasked
    }
}
```

Typed: `Meta` settings (recycle bin, history limits), groups (UUID, name, notes, icon, times, expansion, `EnableSearching`, tags), entries (UUID, icon, tags, times, `<String>` fields in order, `<Binary>` references, history), and tombstones. Everything else is in each element's `unknownXML`. Custom icons, entry expiry, and custom icon references are read-only views of those fragments.

Optional elements are three-state: `notes == nil` means the source had no `<Notes>`, `""` an empty one.

## Writing

```swift
let header = try KDBXContainerWriter.prepareHeader(.reuse(payload.header), requiredMinorVersion: 0)
let xml = try document.serialized(innerStream: .chaCha20, innerStreamKey: header.innerStreamKey)
let file = try KDBXContainerWriter.seal(xml: xml, header: header) { parameters in
    try KDBXKeyDerivation.deriveKey(compositeKey: compositeKey, parameters: parameters, policy: policy)
}
```

A typed property replaces a preserved element of the same name, so setting `enableSearching` on a group whose source value was unreadable writes one element, not two. `KDBXDocument.validate(text:)` checks text against XML 1.0 before you accept it from a user; `serialized` checks everything it writes.

## Errors

Plain enums with no user-facing text: `KDBXDocument.ReadError` (`malformedXML(line:column:)`, `unexpectedRootElement`, `invalidProtectedValue`) and `KDBXDocument.WriteError` (`invalidXMLCharacter`).

## Tests and coverage

```bash
swift test
scripts/coverage.sh
```

`scripts/coverage.sh` reports line, region, and function coverage for `Sources/KDBXXML` and fails below its thresholds (`KDBXXML_MIN_LINES`, `KDBXXML_MIN_REGIONS`, `KDBXXML_MIN_FUNCTIONS`). LLVM records no branch coverage for Swift; region coverage stands in for it.
