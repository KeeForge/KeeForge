// Tests default to the main-app KDF policy; tests that exercise policy selection pass `kdfPolicy:` explicitly.
import CryptoKit
import Foundation
import KDBXKit
@testable import KeeForge

// Password and key-file conveniences over `KDBXParser.parse(data:compositeKey:…)`.
extension KDBXParser {
    typealias OpenedTuple = (rootGroup: KPGroup, meta: KPMeta, header: KDBXContainer.Header)

    static func parse(
        data: Data,
        password: String?,
        keyFileData: Data? = nil,
        sessionKey: SymmetricKey,
        kdfPolicy: KDFExecutionPolicy = .mainApp
    ) throws -> KPGroup {
        try parseWithMetaAndHeader(
            data: data, password: password, keyFileData: keyFileData, sessionKey: sessionKey, kdfPolicy: kdfPolicy
        ).rootGroup
    }

    static func parse(data: Data, compositeKey: SymmetricKey, sessionKey: SymmetricKey) throws -> KPGroup {
        try parse(data: data, compositeKey: compositeKey, sessionKey: sessionKey, kdfPolicy: .mainApp).rootGroup
    }

    static func parseWithMeta(
        data: Data,
        password: String?,
        keyFileData: Data? = nil,
        sessionKey: SymmetricKey,
        kdfPolicy: KDFExecutionPolicy = .mainApp
    ) throws -> (rootGroup: KPGroup, meta: KPMeta) {
        let opened = try parseWithMetaAndHeader(
            data: data, password: password, keyFileData: keyFileData, sessionKey: sessionKey, kdfPolicy: kdfPolicy
        )
        return (opened.rootGroup, opened.meta)
    }

    static func parseWithMeta(
        data: Data,
        compositeKey: SymmetricKey,
        sessionKey: SymmetricKey,
        kdfPolicy: KDFExecutionPolicy = .mainApp
    ) throws -> (rootGroup: KPGroup, meta: KPMeta) {
        let opened = try parse(data: data, compositeKey: compositeKey, sessionKey: sessionKey, kdfPolicy: kdfPolicy)
        return (opened.rootGroup, opened.meta)
    }

    static func parseWithMetaAndHeader(
        data: Data,
        password: String?,
        keyFileData: Data? = nil,
        sessionKey: SymmetricKey,
        kdfPolicy: KDFExecutionPolicy = .mainApp
    ) throws -> OpenedTuple {
        let compositeKey = try KDBXCrypto.compositeKey(password: password, keyFileData: keyFileData)
        return try parseWithMetaAndHeader(data: data, compositeKey: compositeKey, sessionKey: sessionKey, kdfPolicy: kdfPolicy)
    }

    static func parseWithMetaAndHeader(
        data: Data,
        compositeKey: SymmetricKey,
        sessionKey: SymmetricKey,
        kdfPolicy: KDFExecutionPolicy = .mainApp
    ) throws -> OpenedTuple {
        let opened = try parse(data: data, compositeKey: compositeKey, sessionKey: sessionKey, kdfPolicy: kdfPolicy)
        return (opened.rootGroup, opened.meta, opened.header)
    }
}

extension KDBXKeyDerivation {
    static func deriveKey(compositeKey: SymmetricKey, parameters: KDBXVariantMap) throws -> Data {
        try deriveKey(compositeKey: compositeKey, parameters: parameters, policy: .mainApp)
    }
}

extension KDBXWriter {
    static func write(
        rootGroup: KPGroup,
        meta: KPMeta,
        compositeKey: SymmetricKey,
        header: KDBXContainer.Header,
        sessionKey: SymmetricKey
    ) throws -> Data {
        try write(
            rootGroup: rootGroup,
            meta: meta,
            compositeKey: compositeKey,
            header: header,
            sessionKey: sessionKey,
            kdfPolicy: .mainApp
        )
    }

    static func write(
        rootGroup: KPGroup,
        meta: KPMeta,
        compositeKey: SymmetricKey,
        freshHeader: KDBXContainerWriter.FreshHeaderConfiguration,
        sessionKey: SymmetricKey
    ) throws -> Data {
        try write(
            rootGroup: rootGroup,
            meta: meta,
            compositeKey: compositeKey,
            freshHeader: freshHeader,
            sessionKey: sessionKey,
            kdfPolicy: .mainApp
        )
    }
}

extension LocalDatabaseSaver {
    static func save(
        draft: DatabaseDraft,
        reference: DatabaseReference,
        compositeKey: SymmetricKey,
        openTimeSHA512: Data
    ) async throws -> SaveResult {
        try await save(
            draft: draft,
            reference: reference,
            compositeKey: compositeKey,
            openTimeSHA512: openTimeSHA512,
            kdfPolicy: .mainApp
        )
    }

    static func save(
        draft: DatabaseDraft,
        reference: DatabaseReference,
        compositeKey: SymmetricKey,
        openTimeSHA512: Data,
        environment: Environment
    ) async throws -> SaveResult {
        try await save(
            draft: draft,
            reference: reference,
            compositeKey: compositeKey,
            openTimeSHA512: openTimeSHA512,
            kdfPolicy: .mainApp,
            environment: environment
        )
    }
}

extension CloudDatabaseSaver {
    static func save(
        draft: DatabaseDraft,
        reference: DatabaseReference,
        compositeKey: SymmetricKey,
        openTimeSHA512: Data,
        expectedRev: String?
    ) async throws -> SaveResult {
        try await save(
            draft: draft,
            reference: reference,
            compositeKey: compositeKey,
            openTimeSHA512: openTimeSHA512,
            expectedRev: expectedRev,
            kdfPolicy: .mainApp
        )
    }

    static func save(
        draft: DatabaseDraft,
        reference: DatabaseReference,
        compositeKey: SymmetricKey,
        openTimeSHA512: Data,
        expectedRev: String?,
        environment: Environment
    ) async throws -> SaveResult {
        try await save(
            draft: draft,
            reference: reference,
            compositeKey: compositeKey,
            openTimeSHA512: openTimeSHA512,
            expectedRev: expectedRev,
            kdfPolicy: .mainApp,
            environment: environment
        )
    }
}
