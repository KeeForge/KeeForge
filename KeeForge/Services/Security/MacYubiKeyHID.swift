#if os(macOS)
import Foundation
import KDBXKit
import IOKit.hid
import Synchronization

/// A plugged-in YubiKey's OTP (keyboard) interface, reached through IOKit's
/// HID feature reports. Needs `com.apple.security.device.usb` in the sandbox.
final class MacYubiKeyHIDDevice: YubiKeyOTPReportDevice {
    private static let yubicoVendorID = 0x1050

    private let device: IOHIDDevice

    private init(device: IOHIDDevice) {
        self.device = device
    }

    deinit {
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    /// Whether a Yubico device with an OTP interface is plugged in. Opens nothing.
    static var isConnected: Bool {
        matchingDevices().isEmpty == false
    }

    /// Opens the first plugged-in YubiKey's OTP interface.
    static func openFirst() throws -> MacYubiKeyHIDDevice {
        guard let device = matchingDevices().first else { throw HardwareKeyError.notConnected }
        let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        switch result {
        case kIOReturnSuccess:
            return MacYubiKeyHIDDevice(device: device)
        case kIOReturnNotPermitted, kIOReturnNotPrivileged:
            // A keyboard interface sits behind Input Monitoring; this asks once
            // and is a no-op after the user has answered.
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            throw HardwareKeyError.permissionDenied
        default:
            throw error(for: result)
        }
    }

    func readFeatureReport() throws -> [UInt8] {
        var report = [UInt8](repeating: 0, count: YubiKeyOTPHID.reportSize)
        var length = CFIndex(report.count)
        let result = report.withUnsafeMutableBufferPointer { buffer -> IOReturn in
            guard let base = buffer.baseAddress else { return kIOReturnNoMemory }
            return IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 0, base, &length)
        }
        guard result == kIOReturnSuccess else { throw Self.error(for: result) }
        guard length == report.count else { throw HardwareKeyError.communicationFailed }
        return report
    }

    func writeFeatureReport(_ report: [UInt8]) throws {
        let result = report.withUnsafeBufferPointer { buffer -> IOReturn in
            guard let base = buffer.baseAddress else { return kIOReturnNoMemory }
            return IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 0, base, buffer.count)
        }
        guard result == kIOReturnSuccess else { throw Self.error(for: result) }
    }

    private static func error(for result: IOReturn) -> HardwareKeyError {
        switch result {
        case kIOReturnNotAttached, kIOReturnNoDevice, kIOReturnOffline, kIOReturnAborted:
            .disconnected
        case kIOReturnNotPermitted, kIOReturnNotPrivileged:
            .permissionDenied
        case kIOReturnTimeout:
            .timedOut
        default:
            .communicationFailed
        }
    }

    /// Yubico devices whose primary usage is a keyboard: the OTP interface.
    /// A FIDO-only Security Key has none.
    private static func matchingDevices() -> [IOHIDDevice] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDVendorIDKey: yubicoVendorID,
            kIOHIDPrimaryUsagePageKey: kHIDPage_GenericDesktop,
            kIOHIDPrimaryUsageKey: kHIDUsage_GD_Keyboard,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return [] }
        return devices.sorted { locationID(of: $0) < locationID(of: $1) }
    }

    private static func locationID(of device: IOHIDDevice) -> Int {
        IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString) as? Int ?? 0
    }
}

/// One challenge at a time on a serial queue: a response can take as long as
/// the key waits for a touch, which must not hold a Swift concurrency thread.
final class MacYubiKeyConnection: Sendable {
    static let shared = MacYubiKeyConnection()

    private let queue = DispatchQueue(label: "com.keevault.yubikey.hid", qos: .userInitiated)
    private let isBusy = Mutex(false)

    func response(to challenge: Data, slot: HardwareKeyConfiguration.Slot) async throws -> Data {
        guard isBusy.withLock({ busy in
            guard busy == false else { return false }
            busy = true
            return true
        }) else { throw HardwareKeyError.communicationFailed }
        defer { isBusy.withLock { $0 = false } }

        let cancellation = CancellationFlag()
        var response = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                queue.async {
                    continuation.resume(with: Result {
                        guard cancellation.isCancelled == false else { throw HardwareKeyError.cancelled }
                        let device = try MacYubiKeyHIDDevice.openFirst()
                        return try YubiKeyOTPHID.challengeResponse(
                            challenge,
                            slot: slot,
                            device: device,
                            isCancelled: { cancellation.isCancelled }
                        )
                    })
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
        // The answer can arrive just as the request is cancelled; cancelling still wins.
        guard Task.isCancelled == false else {
            SecureWipe.wipe(&response)
            throw HardwareKeyError.cancelled
        }
        return response
    }
}

private final class CancellationFlag: Sendable {
    private let state = Mutex(false)

    var isCancelled: Bool { state.withLock { $0 } }

    func cancel() {
        state.withLock { $0 = true }
    }
}
#endif
