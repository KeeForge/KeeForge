// Tests default to the main-app KDF policy; tests that exercise policy selection pass `kdfPolicy:` explicitly.
import CryptoKit
import Foundation
@testable import KeeForge

extension KDBXParser {
    static func parse(data: Data, password: String, sessionKey: SymmetricKey) throws -> KPGroup {
        try parse(data: data, password: password, sessionKey: sessionKey, kdfPolicy: .mainApp)
    }

    static func parse(data: Data, password: String?, keyFileData: Data?, sessionKey: SymmetricKey) throws -> KPGroup {
        try parse(data: data, password: password, keyFileData: keyFileData, sessionKey: sessionKey, kdfPolicy: .mainApp)
    }

    static func parse(data: Data, compositeKey: SymmetricKey, sessionKey: SymmetricKey) throws -> KPGroup {
        try parse(data: data, compositeKey: compositeKey, sessionKey: sessionKey, kdfPolicy: .mainApp)
    }

    static func parseWithMeta(
        data: Data,
        password: String,
        sessionKey: SymmetricKey
    ) throws -> (rootGroup: KPGroup, meta: KPMeta) {
        try parseWithMeta(data: data, password: password, sessionKey: sessionKey, kdfPolicy: .mainApp)
    }

    static func parseWithMeta(
        data: Data,
        password: String?,
        keyFileData: Data?,
        sessionKey: SymmetricKey
    ) throws -> (rootGroup: KPGroup, meta: KPMeta) {
        try parseWithMeta(data: data, password: password, keyFileData: keyFileData, sessionKey: sessionKey, kdfPolicy: .mainApp)
    }

    static func parseWithMeta(
        data: Data,
        compositeKey: SymmetricKey,
        sessionKey: SymmetricKey
    ) throws -> (rootGroup: KPGroup, meta: KPMeta) {
        try parseWithMeta(data: data, compositeKey: compositeKey, sessionKey: sessionKey, kdfPolicy: .mainApp)
    }

    static func parseWithMetaAndHeader(
        data: Data,
        password: String,
        sessionKey: SymmetricKey
    ) throws -> (rootGroup: KPGroup, meta: KPMeta, header: Header) {
        try parseWithMetaAndHeader(data: data, password: password, sessionKey: sessionKey, kdfPolicy: .mainApp)
    }

    static func parseWithMetaAndHeader(
        data: Data,
        password: String?,
        keyFileData: Data?,
        sessionKey: SymmetricKey
    ) throws -> (rootGroup: KPGroup, meta: KPMeta, header: Header) {
        try parseWithMetaAndHeader(data: data, password: password, keyFileData: keyFileData, sessionKey: sessionKey, kdfPolicy: .mainApp)
    }

    static func parseWithMetaAndHeader(
        data: Data,
        compositeKey: SymmetricKey,
        sessionKey: SymmetricKey
    ) throws -> (rootGroup: KPGroup, meta: KPMeta, header: Header) {
        try parseWithMetaAndHeader(data: data, compositeKey: compositeKey, sessionKey: sessionKey, kdfPolicy: .mainApp)
    }

    static func deriveKey(compositeKey: SymmetricKey, kdfParams: [String: Any]) throws -> Data {
        try deriveKey(compositeKey: compositeKey, kdfParams: kdfParams, kdfPolicy: .mainApp)
    }
}

extension KDBXWriter {
    static func write(
        rootGroup: KPGroup,
        meta: KPMeta,
        compositeKey: SymmetricKey,
        header: KDBXParser.Header,
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
        freshHeader: FreshHeaderConfiguration,
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
