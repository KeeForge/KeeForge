import Foundation
import KDBXKit

/// The 8-byte HID feature reports of a YubiKey's OTP (keyboard) interface.
/// Calls block; implementations throw `HardwareKeyError`.
protocol YubiKeyOTPReportDevice {
    func readFeatureReport() throws -> [UInt8]
    func writeFeatureReport(_ report: [UInt8]) throws
}

/// HMAC-SHA1 challenge-response over the YubiKey OTP HID frame protocol, as
/// Yubico's `ykcore` (`yk_challenge_response`) speaks it.
enum YubiKeyOTPHID {
    static let reportSize = 8
    static let challengeLength = 64
    static let responseLength = 20

    /// The 70-byte frame: 64 payload bytes, the slot command, the payload's
    /// CRC (little-endian), and 3 filler bytes.
    private static let frameLength = 70
    private static let dataBytesPerReport = 7
    /// Reports carrying the frame set it with their sequence number; the key
    /// clears it once it has taken the report.
    private static let slotWriteFlag: UInt8 = 0x80
    private static let responsePendingFlag: UInt8 = 0x40
    /// The key is waiting for a touch; the low bits count down its seconds.
    private static let touchWaitFlag: UInt8 = 0x20
    private static let sequenceMask: UInt8 = 0x1F
    /// Written to end a read or to abandon a command waiting for a touch.
    private static let resetReport: UInt8 = 0x8F
    /// What `crc16` of a response and its own (complemented) CRC comes to.
    private static let crcResidual: UInt16 = 0xF0B8

    enum SlotCommand: UInt8 {
        case challengeHMAC1 = 0x30
        case challengeHMAC2 = 0x38

        init(_ slot: HardwareKeyConfiguration.Slot) {
            self = slot == .one ? .challengeHMAC1 : .challengeHMAC2
        }
    }

    struct Timing: Sendable {
        /// How long the key may take to take one report.
        var writeTimeout: Duration = .milliseconds(1150)
        /// How long the key may take to answer when no touch is needed.
        var responseTimeout: Duration = .seconds(2)
        /// A touch wait lasts as long as the key keeps reporting one, up to this.
        var touchTimeout: Duration = .seconds(30)
        var pollInterval: Duration = .milliseconds(20)
        var touchPollInterval: Duration = .milliseconds(100)
        var sleep: @Sendable (Duration) -> Void = { duration in
            let components = duration.components
            Thread.sleep(forTimeInterval: Double(components.seconds) + Double(components.attoseconds) / 1e18)
        }
    }

    /// The CRC-16 (reflected 0x8408, initial 0xFFFF, no final complement) the
    /// OTP application uses.
    static func crc16(_ bytes: some Sequence<UInt8>) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for byte in bytes {
            crc ^= UInt16(byte)
            for _ in 0..<8 {
                let carry = crc & 1
                crc >>= 1
                if carry != 0 { crc ^= 0x8408 }
            }
        }
        return crc
    }

    static func frame(command: SlotCommand, payload: [UInt8]) -> [UInt8] {
        precondition(payload.count == challengeLength)
        let crc = crc16(payload)
        return payload + [command.rawValue, UInt8(crc & 0xFF), UInt8(crc >> 8), 0, 0, 0]
    }

    /// The reports that send `frame`, each 7 data bytes then `seq | 0x80`.
    /// All-zero reports other than the first and last are left out; the key
    /// fills the gap with zeros.
    static func reports(forFrame frame: [UInt8]) -> [[UInt8]] {
        precondition(frame.count == frameLength)
        let count = frameLength / dataBytesPerReport
        var reports: [[UInt8]] = []
        for sequence in 0..<count {
            let data = Array(frame[(sequence * dataBytesPerReport)..<((sequence + 1) * dataBytesPerReport)])
            let isEdge = sequence == 0 || sequence == count - 1
            guard isEdge || data.contains(where: { $0 != 0 }) else { continue }
            reports.append(data + [UInt8(sequence) | slotWriteFlag])
        }
        return reports
    }

    /// Sends `challenge` (padded by the caller to 64 bytes) to `slot` and
    /// returns the 20-byte HMAC-SHA1. `onTouchRequired` runs once if the slot
    /// waits for a touch; `isCancelled` is polled, and a cancelled or timed-out
    /// request is abandoned on the key so it stops waiting for a touch.
    static func challengeResponse(
        _ challenge: Data,
        slot: HardwareKeyConfiguration.Slot,
        device: some YubiKeyOTPReportDevice,
        timing: Timing = Timing(),
        isCancelled: () -> Bool = { false },
        onTouchRequired: () -> Void = {}
    ) throws -> Data {
        guard challenge.count == challengeLength else { throw HardwareKeyError.communicationFailed }
        let clock = ContinuousClock()

        for report in reports(forFrame: frame(command: SlotCommand(slot), payload: Array(challenge))) {
            try waitForWriteFlagToClear(device: device, timing: timing, clock: clock, isCancelled: isCancelled)
            try device.writeFeatureReport(report)
        }

        var response: [UInt8] = []
        defer { SecureWipe.wipe(&response) }
        var sequence: UInt8 = 0
        var needsTouch = false
        var deadline = clock.now.advanced(by: timing.responseTimeout)
        while true {
            if isCancelled() {
                abandon(device)
                throw HardwareKeyError.cancelled
            }
            let report = try readReport(device)
            let status = report[dataBytesPerReport]
            if status & responsePendingFlag != 0 {
                if status & sequenceMask == sequence {
                    response += report[0..<dataBytesPerReport]
                    sequence += 1
                } else if status & sequenceMask == 0 {
                    abandon(device)
                    return try verifiedResponse(response)
                }
                continue
            }
            if status == 0 {
                // An idle status with no data: the slot refused the command,
                // or the touch wait ran out on the key.
                guard response.isEmpty else { throw HardwareKeyError.communicationFailed }
                throw needsTouch ? HardwareKeyError.timedOut : HardwareKeyError.slotNotConfigured
            }
            if status & touchWaitFlag != 0 {
                if needsTouch == false {
                    needsTouch = true
                    deadline = clock.now.advanced(by: timing.touchTimeout)
                    onTouchRequired()
                }
                timing.sleep(timing.touchPollInterval)
            } else {
                timing.sleep(timing.pollInterval)
            }
            if clock.now >= deadline {
                abandon(device)
                throw HardwareKeyError.timedOut
            }
        }
    }

    private static func waitForWriteFlagToClear(
        device: some YubiKeyOTPReportDevice,
        timing: Timing,
        clock: ContinuousClock,
        isCancelled: () -> Bool
    ) throws {
        let deadline = clock.now.advanced(by: timing.writeTimeout)
        while try readReport(device)[dataBytesPerReport] & slotWriteFlag != 0 {
            if isCancelled() { throw HardwareKeyError.cancelled }
            guard clock.now < deadline else { throw HardwareKeyError.timedOut }
            timing.sleep(timing.pollInterval)
        }
    }

    private static func readReport(_ device: some YubiKeyOTPReportDevice) throws -> [UInt8] {
        let report = try device.readFeatureReport()
        guard report.count == reportSize else { throw HardwareKeyError.communicationFailed }
        return report
    }

    private static func abandon(_ device: some YubiKeyOTPReportDevice) {
        var report = [UInt8](repeating: 0, count: reportSize)
        report[dataBytesPerReport] = resetReport
        try? device.writeFeatureReport(report)
    }

    private static func verifiedResponse(_ response: [UInt8]) throws -> Data {
        // 20 HMAC bytes and their CRC; the rest of the last report is padding.
        let checked = responseLength + 2
        guard response.count >= checked, crc16(response[0..<checked]) == crcResidual else {
            throw HardwareKeyError.communicationFailed
        }
        return Data(response[0..<responseLength])
    }
}
