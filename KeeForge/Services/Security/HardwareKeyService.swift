import Foundation

/// Answers a YubiKey HMAC-SHA1 challenge over the transport a database is
/// configured for. Backed by YubiKit, which the iOS app target alone links:
/// the Mac app and both AutoFill extensions report no transports and refuse.
@MainActor
enum HardwareKeyService {
    static var availableTransports: [HardwareKeyConfiguration.Transport] {
        #if os(iOS) && canImport(YubiKit)
        YubiKeyConnection.shared.availableTransports
        #else
        []
        #endif
    }

    static func response(
        to challenge: Data,
        using configuration: HardwareKeyConfiguration
    ) async throws -> Data {
        #if os(iOS) && canImport(YubiKit)
        try await YubiKeyConnection.shared.response(to: challenge, using: configuration)
        #else
        throw HardwareKeyError.unavailable
        #endif
    }
}

#if os(iOS) && canImport(YubiKit)
import CoreNFC
@preconcurrency import YubiKit

/// One challenge at a time: YubiKit reports connections through a single
/// shared delegate, so a second request would steal the first one's key.
@MainActor
private final class YubiKeyConnection: NSObject {
    static let shared = YubiKeyConnection()

    private static let responseLength = 20

    private struct Request {
        let id: UUID
        let challenge: Data
        let configuration: HardwareKeyConfiguration
        let continuation: CheckedContinuation<Data, Error>
        var hasSentChallenge = false
    }

    private var request: Request?

    var availableTransports: [HardwareKeyConfiguration.Transport] {
        var transports: [HardwareKeyConfiguration.Transport] = []
        if YubiKitDeviceCapabilities.supportsISO7816NFCTags {
            transports.append(.nfc)
        }
        if YubiKitDeviceCapabilities.supportsMFIAccessoryKey {
            transports.append(.lightning)
        }
        return transports
    }

    func response(to challenge: Data, using configuration: HardwareKeyConfiguration) async throws -> Data {
        guard availableTransports.contains(configuration.transport) else {
            throw HardwareKeyError.unavailable
        }
        guard request == nil else { throw HardwareKeyError.communicationFailed }
        guard Task.isCancelled == false else { throw HardwareKeyError.cancelled }

        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                request = Request(
                    id: id,
                    challenge: challenge,
                    configuration: configuration,
                    continuation: continuation
                )
                YubiKitManager.shared.delegate = self
                switch configuration.transport {
                case .nfc:
                    YubiKitExternalLocalization.nfcScanAlertMessage = String(
                        localized: "Hold your YubiKey near the top of your device."
                    )
                    YubiKitManager.shared.startNFCConnection()
                case .lightning:
                    YubiKitManager.shared.startAccessoryConnection()
                }
            }
        } onCancel: {
            Task { @MainActor in
                self.finish(id, with: .failure(HardwareKeyError.cancelled))
            }
        }
    }

    private func sendChallenge(over connection: YKFConnectionProtocol, transport: HardwareKeyConfiguration.Transport) {
        guard var request, request.configuration.transport == transport, request.hasSentChallenge == false else {
            return
        }
        request.hasSentChallenge = true
        self.request = request

        let id = request.id
        let challenge = request.challenge
        let slot: YKFSlot = request.configuration.slot == .one ? .one : .two
        connection.challengeResponseSession { session, error in
            guard let session else {
                let failure = Self.mapped(error)
                Task { @MainActor in self.finish(id, with: .failure(failure)) }
                return
            }
            session.sendChallenge(challenge, slot: slot) { response, error in
                let result: Result<Data, Error>
                if let response, response.count == Self.responseLength {
                    result = .success(response)
                } else {
                    result = .failure(response == nil ? Self.mapped(error) : HardwareKeyError.communicationFailed)
                }
                Task { @MainActor in self.finish(id, with: result) }
            }
        }
    }

    private func finish(_ id: UUID, with result: Result<Data, Error>) {
        guard let request, request.id == id else { return }
        self.request = nil

        switch request.configuration.transport {
        case .nfc:
            switch result {
            case .success:
                YubiKitManager.shared.stopNFCConnection(withMessage: String(localized: "YubiKey read."))
            case .failure(HardwareKeyError.cancelled):
                YubiKitManager.shared.stopNFCConnection()
            case .failure:
                YubiKitManager.shared.stopNFCConnection(withErrorMessage: String(localized: "The YubiKey couldn't be read."))
            }
        case .lightning:
            YubiKitManager.shared.stopAccessoryConnection()
        }
        request.continuation.resume(with: result)
    }

    private func finishActiveRequest(transport: HardwareKeyConfiguration.Transport, with error: HardwareKeyError) {
        guard let request, request.configuration.transport == transport else { return }
        finish(request.id, with: .failure(error))
    }

    nonisolated private static func mapped(_ error: Error?) -> HardwareKeyError {
        guard let error else { return .communicationFailed }
        let nsError = error as NSError

        if nsError.domain == NFCReaderError.errorDomain {
            switch NFCReaderError.Code(rawValue: nsError.code) {
            case .readerSessionInvalidationErrorUserCanceled:
                return .cancelled
            case .readerSessionInvalidationErrorSessionTimeout:
                return .timedOut
            default:
                return .communicationFailed
            }
        }

        guard nsError.domain == YKFSessionErrorDomain else { return .communicationFailed }
        switch nsError.code {
        case Int(YKFChallengeResponseErrorCode.emptyResponse.rawValue):
            return .slotNotConfigured
        case Int(YKFSessionErrorCode.readTimeoutCode.rawValue),
             Int(YKFSessionErrorCode.touchTimeoutCode.rawValue),
             Int(YKFAPDUErrorCode.conditionNotSatisfied.rawValue):
            return .timedOut
        default:
            return .communicationFailed
        }
    }
}

extension YubiKeyConnection: YKFManagerDelegate {
    nonisolated func didConnectNFC(_ connection: YKFNFCConnection) {
        nonisolated(unsafe) let connection = connection
        Task { @MainActor in self.sendChallenge(over: connection, transport: .nfc) }
    }

    nonisolated func didDisconnectNFC(_ connection: YKFNFCConnection, error: Error?) {
        Task { @MainActor in self.finishActiveRequest(transport: .nfc, with: .disconnected) }
    }

    nonisolated func didFailConnectingNFC(_ error: Error) {
        let failure = Self.mapped(error)
        Task { @MainActor in self.finishActiveRequest(transport: .nfc, with: failure) }
    }

    nonisolated func didConnectAccessory(_ connection: YKFAccessoryConnection) {
        nonisolated(unsafe) let connection = connection
        Task { @MainActor in self.sendChallenge(over: connection, transport: .lightning) }
    }

    nonisolated func didDisconnectAccessory(_ connection: YKFAccessoryConnection, error: Error?) {
        Task { @MainActor in self.finishActiveRequest(transport: .lightning, with: .disconnected) }
    }
}
#endif
