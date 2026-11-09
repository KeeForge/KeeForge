import CryptoKit
import Foundation
import KDBXKit

/// Saves KeeForge's model as a KDBX 4 file: prepares the header with
/// `KDBXContainerWriter`, serializes the XML against its inner stream key,
/// and seals the result.
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
        var serializer = KDBXXMLSerializer(
            rootGroup: rootGroup,
            meta: meta,
            innerStreamKey: header.innerStreamKey,
            sessionKey: sessionKey
        )
        let xml = try serializer.serialize()
        return try KDBXContainerWriter.seal(xml: xml, header: header, transformedKey: provideTransformedKey)
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
