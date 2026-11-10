import CryptoKit
import Foundation
import KDBXKit

/// The KDF output for one KDBX 4 file version, kept beside the quick-unlock
/// key so that quick unlock of an unchanged file skips the KDF.
///
/// It opens only the file version it was derived for, because every save
/// rotates the KDF salt. `binding` ties it to that version's KDF parameters
/// and to the composite key it came from, so it is never offered to another
/// version or under another master key.
struct ExpressUnlockKey: Sendable, Equatable {
    static let serializedByteCount = 1 + bindingByteCount + keyByteCount

    private static let formatVersion: UInt8 = 1
    private static let bindingByteCount = 32
    private static let keyByteCount = 32
    private static let bindingDomain = Data("KeeForge.ExpressUnlock.v1".utf8)

    let binding: Data
    let transformedKey: SymmetricKey

    init(binding: Data, transformedKey: SymmetricKey) {
        self.binding = binding
        self.transformedKey = transformedKey
    }

    /// nil when `transformedKey` is not a KDF output.
    init?(transformedKey: Data, kdfParameters: KDBXVariantMap, compositeKey: SymmetricKey) {
        guard transformedKey.count == Self.keyByteCount else { return nil }
        self.init(
            binding: Self.binding(kdfParameters: kdfParameters, compositeKey: compositeKey),
            transformedKey: SymmetricKey(data: transformedKey)
        )
    }

    init?(serialized: some ContiguousBytes) {
        let parts: (binding: Data, key: SymmetricKey)? = serialized.withUnsafeBytes { bytes in
            guard bytes.count == Self.serializedByteCount,
                  bytes.first == Self.formatVersion else {
                return nil
            }
            let keyStart = 1 + Self.bindingByteCount
            return (
                Data(bytes[1..<keyStart]),
                SymmetricKey(data: UnsafeRawBufferPointer(rebasing: bytes[keyStart...]))
            )
        }
        guard let parts else { return nil }
        self.init(binding: parts.binding, transformedKey: parts.key)
    }

    /// Zeroed when its last holder releases it.
    func serialized() -> Data {
        var bytes = Data(capacity: Self.serializedByteCount)
        defer { SecureWipe.wipe(&bytes) }
        bytes.append(Self.formatVersion)
        bytes.append(binding)
        transformedKey.withUnsafeBytes { bytes.append(contentsOf: $0) }
        return SecureWipe.wipingData(copying: bytes)
    }

    func matches(kdfParameters: KDBXVariantMap, compositeKey: SymmetricKey) -> Bool {
        guard binding.count == Self.bindingByteCount else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(
            binding,
            authenticating: Self.bindingMessage(kdfParameters: kdfParameters),
            using: compositeKey
        )
    }

    static func binding(kdfParameters: KDBXVariantMap, compositeKey: SymmetricKey) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: bindingMessage(kdfParameters: kdfParameters), using: compositeKey))
    }

    /// A canonical encoding of every KDF parameter with its type, so equal
    /// encodings derive equal keys under `KDBXKeyDerivation.deriveKey`.
    private static func bindingMessage(kdfParameters: KDBXVariantMap) -> Data {
        var message = bindingDomain
        let entries = kdfParameters.entries
        for key in entries.keys.sorted(by: { Data($0.utf8).lexicographicallyPrecedes(Data($1.utf8)) }) {
            guard let value = entries[key] else { continue }
            let (type, bytes) = encodedValue(value)
            append(Data(key.utf8), to: &message)
            message.append(type)
            append(bytes, to: &message)
        }
        return message
    }

    /// KDBX variant-map type tags.
    private static func encodedValue(_ value: KDBXVariantMap.Value) -> (UInt8, Data) {
        switch value {
        case .uint32(let value): (0x04, withUnsafeBytes(of: value.littleEndian) { Data($0) })
        case .uint64(let value): (0x05, withUnsafeBytes(of: value.littleEndian) { Data($0) })
        case .bool(let value): (0x08, Data([value ? 1 : 0]))
        case .int32(let value): (0x0C, withUnsafeBytes(of: value.littleEndian) { Data($0) })
        case .int64(let value): (0x0D, withUnsafeBytes(of: value.littleEndian) { Data($0) })
        case .string(let value): (0x18, Data(value.utf8))
        case .bytes(let value): (0x42, value)
        case .unknown(let type, let data): (type, data)
        }
    }

    private static func append(_ field: Data, to message: inout Data) {
        withUnsafeBytes(of: UInt32(field.count).littleEndian) { message.append(contentsOf: $0) }
        message.append(field)
    }
}

/// Opens a database with an optional `ExpressUnlockKey`, falling back to the
/// KDF whenever the cached key does not belong to the file, and keeps the key
/// of each version it opens or writes.
enum ExpressUnlock {
    struct Outcome {
        let rootGroup: KPGroup
        let meta: KPMeta
        let header: KDBXContainer.Header
        /// The key for the version just opened, to store for the next quick
        /// unlock. nil for KDBX 3.1, which this path does not cover.
        let keyToStore: ExpressUnlockKey?
        let usedCachedKey: Bool
    }

    typealias KeyDerivation = @Sendable (
        _ compositeKey: SymmetricKey,
        _ kdfParameters: KDBXVariantMap,
        _ kdfPolicy: KDFExecutionPolicy
    ) throws -> Data

    static func parse(
        data: Data,
        compositeKey: SymmetricKey,
        cachedKey: ExpressUnlockKey?,
        sessionKey: SymmetricKey,
        kdfPolicy: KDFExecutionPolicy,
        deriveKey: KeyDerivation = { try KDBXKeyDerivation.deriveKey(compositeKey: $0, parameters: $1, policy: $2) }
    ) throws -> Outcome {
        guard case .kdbx4 = try KDBXContainer.parseFileVersion(from: data) else {
            let parsed = try KDBXParser.parse(
                data: data,
                compositeKey: compositeKey,
                sessionKey: sessionKey,
                kdfPolicy: kdfPolicy
            )
            return Outcome(
                rootGroup: parsed.rootGroup,
                meta: parsed.meta,
                header: parsed.header,
                keyToStore: nil,
                usedCachedKey: false
            )
        }

        if let cachedKey {
            var offeredCachedKey = false
            var derivedKey: ExpressUnlockKey?
            do {
                let parsed = try KDBXParser.parse(data: data, sessionKey: sessionKey) { kdfParameters in
                    if cachedKey.matches(kdfParameters: kdfParameters, compositeKey: compositeKey) {
                        offeredCachedKey = true
                        return cachedKey.transformedKey.withUnsafeBytes { Data($0) }
                    }
                    let derived = try derive(compositeKey, kdfParameters, kdfPolicy, deriveKey)
                    derivedKey = derived.key
                    return derived.bytes
                }
                return Outcome(
                    rootGroup: parsed.rootGroup,
                    meta: parsed.meta,
                    header: parsed.header,
                    keyToStore: derivedKey ?? cachedKey,
                    usedCachedKey: offeredCachedKey
                )
            } catch KDBXCrypto.CryptoError.hmacMismatch where offeredCachedKey {
                // The binding matched but the bytes did not open the file
                // (a damaged item); the KDF decides.
            }
        }

        var derivedKey: ExpressUnlockKey?
        let parsed = try KDBXParser.parse(data: data, sessionKey: sessionKey) { kdfParameters in
            let derived = try derive(compositeKey, kdfParameters, kdfPolicy, deriveKey)
            derivedKey = derived.key
            return derived.bytes
        }
        return Outcome(
            rootGroup: parsed.rootGroup,
            meta: parsed.meta,
            header: parsed.header,
            keyToStore: derivedKey,
            usedCachedKey: false
        )
    }

    struct Written: Sendable {
        let data: Data
        /// The key for the version just written. nil when the KDF output is
        /// not a 32-byte key.
        let expressKey: ExpressUnlockKey?
    }

    /// Encrypts `draft` over `header` like `DatabaseDraft.write`, keeping the
    /// KDF output of the rotated salt so the saved version needs no KDF on its
    /// next quick unlock.
    static func write(
        draft: DatabaseDraft,
        compositeKey: SymmetricKey,
        header: KDBXContainer.Header,
        kdfPolicy: KDFExecutionPolicy,
        deriveKey: KeyDerivation = { try KDBXKeyDerivation.deriveKey(compositeKey: $0, parameters: $1, policy: $2) }
    ) throws -> Written {
        var expressKey: ExpressUnlockKey?
        let data = try draft.write(header: header) { kdfParameters in
            let derived = try derive(compositeKey, kdfParameters, kdfPolicy, deriveKey)
            expressKey = derived.key
            return derived.bytes
        }
        return Written(data: data, expressKey: expressKey)
    }

    private static func derive(
        _ compositeKey: SymmetricKey,
        _ kdfParameters: KDBXVariantMap,
        _ kdfPolicy: KDFExecutionPolicy,
        _ deriveKey: KeyDerivation
    ) throws -> (bytes: Data, key: ExpressUnlockKey?) {
        let bytes = try deriveKey(compositeKey, kdfParameters, kdfPolicy)
        let key = ExpressUnlockKey(transformedKey: bytes, kdfParameters: kdfParameters, compositeKey: compositeKey)
        return (bytes, key)
    }
}
