# KDBXKit

The KeePass KDBX container in Swift: reads KDBX 4.x and 3.1, writes KDBX 4.x. It handles everything around the database XML — headers, key derivation, encryption, authentication, compression, and the protected-value stream — and leaves the XML's meaning to you.

Swift 6, iOS 18+ / macOS 15+. Depends on [phc-winner-argon2](https://github.com/P-H-C/phc-winner-argon2) and the Twofish package in `../../Vendor/KeeForgeTwofish`.

## Supported

| | |
| --- | --- |
| Formats | KDBX 4.0 and 4.1 (read and write), KDBX 3.1 (read) |
| Outer ciphers | AES-256-CBC, ChaCha20, Twofish-256-CBC (Twofish read and write in KDBX 4; KDBX 3.1 reads AES and Twofish) |
| Key derivation | Argon2d, Argon2id, AES-KDF |
| Protected values | ChaCha20 (written), Salsa20 (read) |
| Key files | Binary 32-byte, 64-char hex, XML v1.0 and v2.0, and any other file (hashed) |

## Reading

```swift
import KDBXKit

let compositeKey = try KDBXCrypto.compositeKey(password: password, keyFileData: keyFile)
let policy = KDFExecutionPolicy(
    maxPeakMemoryBytes: 1 << 30,
    maxTotalWorkBytes: 16 << 30,
    maxParallelism: 16
)
let payload = try KDBXContainer.read(data: fileData, compositeKey: compositeKey, kdfPolicy: policy)

// payload.xml is the database XML. Protected values in it are XORed with the
// inner stream, in document order:
var stream = try KDBXInnerStream(streamID: payload.header.innerStreamID, key: payload.header.innerStreamKey)
let plaintext = stream.apply(base64DecodedProtectedValue)
```

`KDFExecutionPolicy` caps Argon2's memory, total work, and threads before any work runs, because the parameters come from an untrusted file. Choose limits that fit your process.

`KDBXContainer.readHeader(from:)` reads the plaintext header (version, cipher, compression, KDF settings) without credentials.

## Writing

Saving is three steps, because protected values must be encrypted with the inner stream key of the header being written:

```swift
// 1. Fresh seeds, IV, inner stream key, and KDF salt.
let header = try KDBXContainerWriter.prepareHeader(.reuse(payload.header), requiredMinorVersion: 0)

// 2. Serialize your XML, XORing protected values with this stream in document order.
var stream = try KDBXInnerStream(algorithm: .chaCha20, key: header.innerStreamKey)
let xml = serialize(using: &stream)

// 3. Encrypt and frame.
let file = try KDBXContainerWriter.seal(xml: xml, header: header) { kdfParameters in
    try KDBXKeyDerivation.deriveKey(compositeKey: compositeKey, parameters: kdfParameters, policy: policy)
}
```

For a new file, pass `.fresh(FreshHeaderConfiguration(cipher:kdfParameters:))`, with parameters from `KDBXKeyDerivation.argon2(...).parameters` or `.aesKDF(...).parameters`. The minor version never goes below the source's.

## Errors

Errors are plain enums with no user-facing text: `KDBXContainer.ParseError`, `KDBXCrypto.CryptoError`, `KDBXContainerWriter.WriteError`, and `KDBXKeyFile.KeyFileError`. A wrong key surfaces as `CryptoError.hmacMismatch` on KDBX 4 and `ParseError.invalidStreamStartBytes` on KDBX 3.1.

## Tests and coverage

```bash
swift test
scripts/coverage.sh
```

`scripts/coverage.sh` reports line, region, and function coverage for `Sources/KDBXKit` and fails below its thresholds. LLVM records no branch coverage for Swift; region coverage, which counts each side of every condition, stands in for it.
