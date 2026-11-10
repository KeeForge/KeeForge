import CryptoKit
import Foundation
import KDBXKit
import KDBXXML
@testable import KeeForge

/// The model's payload XML without the container: what a save writes inside
/// the encryption and an open reads back, through the app's mapping.
enum ModelXML {
    struct Serializer {
        let rootGroup: KPGroup
        let meta: KPMeta
        let innerStreamKey: Data
        let sessionKey: SymmetricKey

        func serialize() throws -> Data {
            try KDBXWriter.document(rootGroup: rootGroup, meta: meta, sessionKey: sessionKey)
                .serialized(innerStream: .chaCha20, innerStreamKey: innerStreamKey)
        }
    }

    static func parse(
        _ xml: Data,
        innerStream: KDBXInnerStream.Algorithm,
        key: Data,
        sessionKey: SymmetricKey
    ) throws -> (rootGroup: KPGroup, meta: KPMeta) {
        let document = try KDBXDocument.read(xml: xml, innerStreamID: innerStream.rawValue, innerStreamKey: key)
        return KDBXParser.model(from: document, sessionKey: sessionKey)
    }
}
