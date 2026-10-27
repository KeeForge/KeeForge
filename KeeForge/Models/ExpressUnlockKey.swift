import CryptoKit
import Foundation

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

    /// nil when the KDF parameters hold a value type the binding cannot encode.
    init?(transformedKey: Data, kdfParameters: [String: Any], compositeKey: SymmetricKey) {
        guard transformedKey.count == Self.keyByteCount,
              let binding = Self.binding(kdfParameters: kdfParameters, compositeKey: compositeKey) else {
            return nil
        }
        self.init(binding: binding, transformedKey: SymmetricKey(data: transformedKey))
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

    func matches(kdfParameters: [String: Any], compositeKey: SymmetricKey) -> Bool {
        guard binding.count == Self.bindingByteCount,
              let message = Self.bindingMessage(kdfParameters: kdfParameters) else {
            return false
        }
        return HMAC<SHA256>.isValidAuthenticationCode(binding, authenticating: message, using: compositeKey)
    }

    static func binding(kdfParameters: [String: Any], compositeKey: SymmetricKey) -> Data? {
        guard let message = bindingMessage(kdfParameters: kdfParameters) else { return nil }
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: compositeKey))
    }

    /// A canonical encoding of the parsed KDF parameters. `KDBXParser.deriveKey`
    /// reads only this dictionary, so equal encodings derive equal keys.
    private static func bindingMessage(kdfParameters: [String: Any]) -> Data? {
        var message = bindingDomain
        for key in kdfParameters.keys.sorted(by: { Data($0.utf8).lexicographicallyPrecedes(Data($1.utf8)) }) {
            guard let value = kdfParameters[key],
                  let (type, bytes) = encodedValue(value) else {
                return nil
            }
            append(Data(key.utf8), to: &message)
            message.append(type)
            append(bytes, to: &message)
        }
        return message
    }

    // Tags match the KDBX variant-map types `KDBXParser.parseVariantMap` decodes.
    private static func encodedValue(_ value: Any) -> (UInt8, Data)? {
        switch value {
        case let value as UInt32: (0x04, withUnsafeBytes(of: value.littleEndian) { Data($0) })
        case let value as UInt64: (0x05, withUnsafeBytes(of: value.littleEndian) { Data($0) })
        case let value as Bool: (0x08, Data([value ? 1 : 0]))
        case let value as Int32: (0x0C, withUnsafeBytes(of: value.littleEndian) { Data($0) })
        case let value as Int64: (0x0D, withUnsafeBytes(of: value.littleEndian) { Data($0) })
        case let value as String: (0x18, Data(value.utf8))
        case let value as Data: (0x42, value)
        default: nil
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
        let header: KDBXParser.Header
        /// The key for the version just opened, to store for the next quick
        /// unlock. nil for KDBX 3.1, which this path does not cover.
        let keyToStore: ExpressUnlockKey?
        let usedCachedKey: Bool
    }

    typealias KeyDerivation = @Sendable (
        _ compositeKey: SymmetricKey,
        _ kdfParameters: [String: Any],
        _ kdfPolicy: KDFExecutionPolicy
    ) throws -> Data

    static func parse(
        data: Data,
        compositeKey: SymmetricKey,
        cachedKey: ExpressUnlockKey?,
        sessionKey: SymmetricKey,
        kdfPolicy: KDFExecutionPolicy,
        deriveKey: KeyDerivation = { try KDBXParser.deriveKey(compositeKey: $0, kdfParams: $1, kdfPolicy: $2) }
    ) throws -> Outcome {
        guard case .kdbx4 = try KDBXParser.parseFileVersion(from: data) else {
            let parsed = try KDBXParser.parseWithMetaAndHeader(
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
                let parsed = try KDBXParser.parseKDBX4WithMetaAndHeader(data: data, sessionKey: sessionKey) { kdfParameters in
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
        let parsed = try KDBXParser.parseKDBX4WithMetaAndHeader(data: data, sessionKey: sessionKey) { kdfParameters in
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
        /// The key for the version just written. nil when its KDF parameters
        /// hold a value the binding cannot encode.
        let expressKey: ExpressUnlockKey?
    }

    /// Encrypts `draft` over `header` like `DatabaseDraft.write`, keeping the
    /// KDF output of the rotated salt so the saved version needs no KDF on its
    /// next quick unlock.
    static func write(
        draft: DatabaseDraft,
        compositeKey: SymmetricKey,
        header: KDBXParser.Header,
        kdfPolicy: KDFExecutionPolicy,
        deriveKey: KeyDerivation = { try KDBXParser.deriveKey(compositeKey: $0, kdfParams: $1, kdfPolicy: $2) }
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
        _ kdfParameters: [String: Any],
        _ kdfPolicy: KDFExecutionPolicy,
        _ deriveKey: KeyDerivation
    ) throws -> (bytes: Data, key: ExpressUnlockKey?) {
        let bytes = try deriveKey(compositeKey, kdfParameters, kdfPolicy)
        let key = ExpressUnlockKey(transformedKey: bytes, kdfParameters: kdfParameters, compositeKey: compositeKey)
        return (bytes, key)
    }
}
