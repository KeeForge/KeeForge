import CryptoKit
import Foundation
import KDBXKit
import KDBXXML

/// Saves KeeForge's model as a KDBX 4 file: prepares the header with
/// `KDBXContainerWriter`, maps the model to a `KDBXDocument` serialized
/// against the header's inner stream key, and seals the result.
enum KDBXWriter {
    static func write(
        rootGroup: KPGroup,
        meta: KPMeta,
        compositeKey: SymmetricKey,
        header: KDBXContainer.Header,
        sessionKey: SymmetricKey,
        kdfPolicy: KDFExecutionPolicy
    ) throws -> Data {
        try write(rootGroup: rootGroup, meta: meta, header: header, sessionKey: sessionKey) { kdfParameters in
            try KDBXKeyDerivation.deriveKey(compositeKey: compositeKey, parameters: kdfParameters, policy: kdfPolicy)
        }
    }

    /// Writes over `header` with the KDF output supplied by `transformedKey`,
    /// which receives the KDF parameters the file is written with (the
    /// rotated salt included).
    static func write(
        rootGroup: KPGroup,
        meta: KPMeta,
        header: KDBXContainer.Header,
        sessionKey: SymmetricKey,
        transformedKey provideTransformedKey: (_ kdfParameters: KDBXVariantMap) throws -> Data
    ) throws -> Data {
        try write(
            rootGroup: rootGroup,
            meta: meta,
            sessionKey: sessionKey,
            headerSource: .reuse(header),
            provideTransformedKey: provideTransformedKey
        )
    }

    static func write(
        rootGroup: KPGroup,
        meta: KPMeta,
        compositeKey: SymmetricKey,
        freshHeader: KDBXContainerWriter.FreshHeaderConfiguration,
        sessionKey: SymmetricKey,
        kdfPolicy: KDFExecutionPolicy
    ) throws -> Data {
        try write(
            rootGroup: rootGroup,
            meta: meta,
            sessionKey: sessionKey,
            headerSource: .fresh(freshHeader)
        ) { kdfParameters in
            try KDBXKeyDerivation.deriveKey(compositeKey: compositeKey, parameters: kdfParameters, policy: kdfPolicy)
        }
    }

    private static func write(
        rootGroup: KPGroup,
        meta: KPMeta,
        sessionKey: SymmetricKey,
        headerSource: KDBXContainerWriter.HeaderSource,
        provideTransformedKey: (_ kdfParameters: KDBXVariantMap) throws -> Data
    ) throws -> Data {
        let header = try KDBXContainerWriter.prepareHeader(
            headerSource,
            requiredMinorVersion: requiredMinorVersion(for: rootGroup, meta: meta)
        )
        let document = try document(rootGroup: rootGroup, meta: meta, sessionKey: sessionKey)
        let xml: Data
        do {
            xml = try document.serialized(innerStream: .chaCha20, innerStreamKey: header.innerStreamKey)
        } catch let error as KDBXDocument.WriteError {
            throw DocumentWriteFailure(error, in: document)
        }
        return try KDBXContainerWriter.seal(xml: xml, header: header, transformedKey: provideTransformedKey)
    }

    /// The document for a model, with sealed secrets decrypted for writing.
    /// Throws when a secret no longer opens under `sessionKey`.
    static func document(rootGroup: KPGroup, meta: KPMeta, sessionKey: SymmetricKey) throws -> KDBXDocument {
        KDBXDocument(
            meta: KDBXDocument.Meta(
                recycleBinUUID: meta.hasRecycleBinUUIDElement || meta.recycleBinUUID != nil
                    ? meta.recycleBinUUID ?? KDBXParser.nullUUID
                    : nil,
                maintenanceHistoryDays: meta.maintenanceHistoryDays,
                historyMaxItems: meta.historyMaxItems,
                historyMaxSize: meta.historyMaxSize,
                unknownXML: meta.unknownXML
            ),
            root: KDBXDocument.Root(
                entries: try rootGroup.entries.map { try entry($0, sessionKey: sessionKey) },
                groups: try rootGroup.groups.map { try group($0, sessionKey: sessionKey) },
                deletedObjects: meta.deletedObjects.map { .init(uuid: $0.uuid, deletionTime: $0.deletionTime) },
                unknownXML: rootGroup.unknownXML
            )
        )
    }

    private static func group(_ group: KPGroup, sessionKey: SymmetricKey) throws -> KDBXDocument.Group {
        KDBXDocument.Group(
            uuid: group.id,
            name: group.name,
            notes: group.hasNotesElement || !group.notes.isEmpty ? group.notes : nil,
            iconID: group.iconID,
            isExpanded: group.isExpanded,
            times: .init(
                creationTime: group.creationTime,
                lastModificationTime: group.lastModificationTime,
                locationChanged: group.locationChanged
            ),
            enableSearching: group.searchingEnabled?.documentValue,
            tags: group.hasTagsElement || !group.tags.isEmpty ? group.tags : nil,
            entries: try group.entries.map { try entry($0, sessionKey: sessionKey) },
            groups: try group.groups.map { try self.group($0, sessionKey: sessionKey) },
            unknownXML: group.unknownXML
        )
    }

    private static func entry(_ entry: KPEntry, sessionKey: SymmetricKey) throws -> KDBXDocument.Entry {
        KDBXDocument.Entry(
            uuid: entry.id,
            iconID: entry.iconID,
            tags: entry.hasTagsElement || !entry.tags.isEmpty ? entry.tags : nil,
            times: .init(
                creationTime: entry.creationTime,
                lastModificationTime: entry.lastModificationTime,
                locationChanged: entry.locationChanged
            ),
            strings: try strings(of: entry, sessionKey: sessionKey),
            binaries: entry.attachments.map { .init(key: $0.name, ref: $0.ref, insertionIndex: $0.insertionIndex) },
            history: try entry.history.map { try self.entry($0, sessionKey: sessionKey) },
            unknownXML: entry.unknownXML
        )
    }

    /// The entry's `<String>` fields in the order KeeForge writes them, which
    /// is also the position space of its preserved fragments.
    private static func strings(of entry: KPEntry, sessionKey: SymmetricKey) throws -> [KDBXDocument.Field] {
        func field(_ key: String, _ value: String, protected: Bool? = nil) -> KDBXDocument.Field {
            KDBXDocument.Field(key: key, value: value, isProtected: protected ?? entry.protectedStringKeys.contains(key))
        }
        var fields = [
            field("Title", entry.title),
            field("UserName", entry.username),
            field("Password", try entry.password.decrypt(using: sessionKey), protected: true),
            field("URL", entry.url),
            field("Notes", entry.notes),
        ]

        let keeOTPSource = entry.totpConfig?.keeOTPSource
        if let source = keeOTPSource, source.fieldName == "otp" {
            // The KeeOTP spelling and raw query stay unless the editor rewrote them.
            fields.append(field("otp", source.rawQuery))
        } else if let otpURL = entry.otpURL {
            // The original otpauth:// URI keeps issuer, label, and any custom
            // parameters that TimeOtp-* fields cannot hold.
            fields.append(field("otp", otpURL))
        }
        if let source = keeOTPSource, source.fieldName != "otp" {
            // Stripped from customFields at parse time; coexists with an
            // unrelated value in the standard otp slot.
            fields.append(field(source.fieldName, source.rawQuery))
        }
        if keeOTPSource == nil, entry.otpURL == nil, let totpConfig = entry.totpConfig {
            fields += [
                field(totpConfig.keePassSecretField.rawValue, try totpConfig.secret.decrypt(using: sessionKey), protected: true),
                field("TimeOtp-Period", String(totpConfig.period), protected: false),
                field("TimeOtp-Length", String(totpConfig.digits), protected: false),
                field("TimeOtp-Algorithm", totpConfig.algorithm.keePassName, protected: false),
            ]
        }

        // The diverted passkey PEM goes back under its key at its stored
        // custom-field position. An entry still holding the PEM in
        // customFields writes it through the plain path, to the same bytes.
        let passkeyPEMKey = PasskeyCredential.privateKeyPEMKey
        var customFieldKeys = Set(entry.customFields.keys)
        let sealedPEM = entry.customFields[passkeyPEMKey] == nil ? entry.passkeyPrivateKey : nil
        if sealedPEM != nil {
            customFieldKeys.insert(passkeyPEMKey)
        }
        for key in entry.orderedCustomFieldKeys(in: customFieldKeys) {
            if key == passkeyPEMKey, let sealedPEM {
                fields.append(field(key, try sealedPEM.decrypt(using: sessionKey)))
            } else {
                fields.append(field(key, entry.customFields[key] ?? ""))
            }
        }
        return fields
    }

    /// The lowest KDBX 4 minor version that can represent this tree.
    ///
    /// Group tags, Recycle Bin restore references, and custom-icon names
    /// require KDBX 4.1.
    private static func requiredMinorVersion(for rootGroup: KPGroup, meta: KPMeta) -> UInt16 {
        func requiresVersion41(_ group: KPGroup) -> Bool {
            group.hasTagsElement || !group.tags.isEmpty
                || PreviousParentGroupXML.isPresent(in: group.unknownXML)
                || group.entries.contains { PreviousParentGroupXML.isPresent(in: $0.unknownXML) }
                || group.groups.contains(where: requiresVersion41)
        }
        return requiresVersion41(rootGroup) || !meta.customIconNames.isEmpty
            || CustomIconXML.requiresVersion41(meta.unknownXML) ? 1 : 0
    }
}
