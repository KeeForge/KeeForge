import CryptoKit
import Foundation
import KDBXKit

/// Answers a YubiKey HMAC-SHA1 challenge over the transport a database is
/// configured for: NFC through YubiKit, which the iOS app target alone links,
/// and USB through IOKit HID in the Mac app and Mac AutoFill. The iOS AutoFill
/// extension does not compile this file.
@MainActor
enum HardwareKeyService {
    static var availableTransports: [HardwareKeyConfiguration.Transport] {
        #if DEBUG
        if UITestYubiKey.secret != nil { return UITestYubiKey.transports }
        #endif
        #if os(iOS) && canImport(YubiKit)
        return YubiKeyConnection.shared.availableTransports
        #elseif os(macOS)
        return [.usb]
        #else
        return []
        #endif
    }

    /// What to tell the user while the key is asked.
    static func prompt(for transport: HardwareKeyConfiguration.Transport) -> String {
        switch transport {
        case .nfc: String(localized: "Hold your YubiKey near the top of your device.")
        case .usb: String(localized: "Touch your YubiKey if it flashes.")
        }
    }

    static func response(
        to challenge: Data,
        using configuration: HardwareKeyConfiguration
    ) async throws -> Data {
        guard availableTransports.contains(configuration.transport) else {
            throw HardwareKeyError.unavailable
        }
        #if DEBUG
        if let secret = UITestYubiKey.secret { return UITestYubiKey.response(to: challenge, secret: secret) }
        #endif
        #if os(iOS) && canImport(YubiKit)
        return try await YubiKeyConnection.shared.response(to: challenge, using: configuration)
        #elseif os(macOS)
        return try await MacYubiKeyConnection.shared.response(to: challenge, slot: configuration.slot)
        #else
        throw HardwareKeyError.unavailable
        #endif
    }
}

#if DEBUG
/// UI tests drive the YubiKey flows with an emulated key: with `-ui-testing`
/// and `UI_TEST_YUBIKEY_SECRET` (a test HMAC secret, never a real one), every
/// transport answers at once as a variable-length HMAC-SHA1 slot does.
private enum UITestYubiKey {
    static var secret: Data? {
        guard ProcessInfo.processInfo.arguments.contains("-ui-testing"),
              let secret = ProcessInfo.processInfo.environment["UI_TEST_YUBIKEY_SECRET"] else { return nil }
        return Data(secret.utf8)
    }

    static var transports: [HardwareKeyConfiguration.Transport] {
        #if os(macOS)
        [.usb]
        #else
        [.nfc]
        #endif
    }

    /// A variable-length slot drops trailing bytes equal to the last one.
    static func response(to challenge: Data, secret: Data) -> Data {
        var message = challenge
        if let last = message.last {
            while message.last == last { message.removeLast() }
        }
        return Data(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: SymmetricKey(data: secret)))
    }
}
#endif

#if os(iOS) && canImport(YubiKit)
import CoreNFC
@preconcurrency import YubiKit

enum HardwareKeyErrorMapper {
    nonisolated static func disconnectError(_ error: Error?) -> HardwareKeyError {
        guard let error else { return .disconnected }
        return Self.error(from: error)
    }

    nonisolated static func error(from error: Error?) -> HardwareKeyError {
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

/// One challenge at a time: YubiKit reports connections through a single
/// shared delegate, so a second request would steal the first one's key.
@MainActor
private final class YubiKeyConnection: NSObject {
    static let shared = YubiKeyConnection()

    private nonisolated static let responseLength = 20

    private struct Request {
        let id: UUID
        let challenge: Data
        let configuration: HardwareKeyConfiguration
        let continuation: CheckedContinuation<Data, Error>
        var hasSentChallenge = false
    }

    private var request: Request?

    var availableTransports: [HardwareKeyConfiguration.Transport] {
        YubiKitDeviceCapabilities.supportsISO7816NFCTags ? [.nfc] : []
    }

    func response(to challenge: Data, using configuration: HardwareKeyConfiguration) async throws -> Data {
        guard availableTransports.contains(configuration.transport) else {
            throw HardwareKeyError.unavailable
        }
        guard request == nil else { throw HardwareKeyError.communicationFailed }
        guard Task.isCancelled == false else { throw HardwareKeyError.cancelled }

        let id = UUID()
        var response = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                request = Request(
                    id: id,
                    challenge: challenge,
                    configuration: configuration,
                    continuation: continuation
                )
                YubiKitManager.shared.delegate = self
                YubiKitExternalLocalization.nfcScanAlertMessage = HardwareKeyService.prompt(for: .nfc)
                YubiKitManager.shared.startNFCConnection()
            }
        } onCancel: {
            Task { @MainActor in
                self.finish(id, with: .failure(HardwareKeyError.cancelled))
            }
        }
        // The key's answer and the cancellation reach `finish` as separate
        // main-actor tasks, so the answer can win the race; cancelling still
        // has to.
        guard Task.isCancelled == false else {
            SecureWipe.wipe(&response)
            throw HardwareKeyError.cancelled
        }
        return response
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
                let failure = HardwareKeyErrorMapper.error(from: error)
                Task { @MainActor in self.finish(id, with: .failure(failure)) }
                return
            }
            session.sendChallenge(challenge, slot: slot) { response, error in
                let result: Result<Data, Error>
                if let response, response.count == Self.responseLength {
                    result = .success(response)
                } else {
                    result = .failure(
                        response == nil
                            ? HardwareKeyErrorMapper.error(from: error)
                            : HardwareKeyError.communicationFailed
                    )
                }
                Task { @MainActor in self.finish(id, with: result) }
            }
        }
    }

    private func finish(_ id: UUID, with result: Result<Data, Error>) {
        guard let request, request.id == id else { return }
        self.request = nil

        switch result {
        case .success:
            YubiKitManager.shared.stopNFCConnection(withMessage: String(localized: "YubiKey read."))
        case .failure(HardwareKeyError.cancelled):
            YubiKitManager.shared.stopNFCConnection()
        case .failure:
            YubiKitManager.shared.stopNFCConnection(withErrorMessage: String(localized: "The YubiKey couldn't be read."))
        }
        request.continuation.resume(with: result)
    }

    private func finishActiveRequest(transport: HardwareKeyConfiguration.Transport, with error: HardwareKeyError) {
        guard let request, request.configuration.transport == transport else { return }
        finish(request.id, with: .failure(error))
    }

}

extension YubiKeyConnection: YKFManagerDelegate {
    nonisolated func didConnectNFC(_ connection: YKFNFCConnection) {
        nonisolated(unsafe) let connection = connection
        Task { @MainActor in self.sendChallenge(over: connection, transport: .nfc) }
    }

    nonisolated func didDisconnectNFC(_ connection: YKFNFCConnection, error: Error?) {
        let failure = HardwareKeyErrorMapper.disconnectError(error)
        Task { @MainActor in self.finishActiveRequest(transport: .nfc, with: failure) }
    }

    nonisolated func didFailConnectingNFC(_ error: Error) {
        let failure = HardwareKeyErrorMapper.error(from: error)
        Task { @MainActor in self.finishActiveRequest(transport: .nfc, with: failure) }
    }

    // YubiKit requires these callbacks even when only NFC is started.
    nonisolated func didConnectAccessory(_ connection: YKFAccessoryConnection) {}

    nonisolated func didDisconnectAccessory(_ connection: YKFAccessoryConnection, error: Error?) {}
}
#endif
