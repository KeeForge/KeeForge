import Foundation
import KDBXXML

// KDBXXML throws plain errors; KeeForge owns their user-facing text.

extension KDBXDocument.ReadError: @retroactive LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .malformedXML, .unexpectedRootElement:
            String(localized: "Failed to parse database XML")
        case .invalidProtectedValue:
            String(localized: "The database contains a protected value that could not be decoded.")
        }
    }
}

extension KDBXDocument.WriteError: @retroactive LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidXMLCharacter(let scalar):
            String(
                format: String(localized: "The database contains an unsupported character (%@). Remove it from your text before saving."),
                String(format: "U+%04X", scalar.value)
            )
        }
    }
}
