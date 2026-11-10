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

Typed: `Meta` settings (recycle bin, history limits), groups (UUID, name, notes, icon, times, expansion, `EnableSearching`, tags), entries (UUID, icon, tags, times, `<String>` fields in order, `<Binary>` references, history), and tombstones. Everything else is in each element's `unknownXML`, and children of `<KeePassFile>` other than `<Meta>` and `<Root>` are in the document's. Custom icons, entry expiry, and custom icon references are read-only views of those fragments.

Optional elements are three-state: `notes == nil` means the source had no `<Notes>`, `""` an empty one. `meta.recycleBin` is `nil` without a `<RecycleBinUUID>`, `.unset` for the all-zero UUID KeePass writes when there is no recycle bin, and `.group(uuid)` otherwise; each writes back as it was read.

## Writing

```swift
let header = try KDBXContainerWriter.prepareHeader(.reuse(payload.header), requiredMinorVersion: 0)
let xml = try document.serialized(innerStream: .chaCha20, innerStreamKey: header.innerStreamKey)
let file = try KDBXContainerWriter.seal(xml: xml, header: header) { parameters in
    try KDBXKeyDerivation.deriveKey(compositeKey: compositeKey, parameters: parameters, policy: policy)
}
```

Typed children are written in KeePass's order. A typed property replaces a preserved element of the same name, so setting `enableSearching` on a group whose source value was unreadable writes one element, not two. `KDBXDocument.validate(text:)` checks text against XML 1.0 before you accept it from a user; `serialized` checks the whole document before it writes anything and reports where the first bad character is.

## Splicing preserved elements

To add or change an element the document keeps opaque, splice it through its owner rather than computing a position. A new element goes where KeePass writes it; a replacement keeps the existing one's place; an empty list removes it.

```swift
entry.replaceOpaqueChildren(named: "CustomIconUUID", with: ["<CustomIconUUID>\(icon.kdbxBase64String)</CustomIconUUID>"])
entry.replaceOpaqueTimesChildren(named: "Expires", with: ["<Expires>True</Expires>"])
meta.replaceOpaqueChildren(named: "CustomIcons", with: ["<CustomIcons></CustomIcons>"])
let slot = entry.binaryInsertionIndex(afterStrings: 5) // a new attachment after the fifth <String>
```

Fragments must be canonical (see `OpaqueXMLNodes`).

## Errors

Plain enums with no user-facing text: `KDBXDocument.ReadError` (`malformedXML(line:column:)`, `unexpectedRootElement`, `invalidProtectedValue`) `KDBXDocument.TextError` (`invalidXMLCharacter`, from `validate(text:)`), and `KDBXDocument.WriteError` (`invalidXMLCharacter(_:at:)`, whose `Location` names the owner (`document` for top-level fragments, `meta`, `root`, a group, an entry, or a history version, by UUID) and the part (an element name, a field key, or an attachment key)).

## Tests and coverage

```bash
swift test
scripts/coverage.sh
```

`scripts/coverage.sh` reports line, region, and function coverage for `Sources/KDBXXML` and fails below its thresholds (`KDBXXML_MIN_LINES`, `KDBXXML_MIN_REGIONS`, `KDBXXML_MIN_FUNCTIONS`). LLVM records no branch coverage for Swift; region coverage stands in for it.
