import Foundation

enum CloudWriteGuarantee: Sendable, Equatable {
    /// The server validates the supplied revision at content replacement.
    case serverConditional
    case preflightOnly
    case disabled
}
