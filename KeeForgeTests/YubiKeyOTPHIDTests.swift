import XCTest
@testable import KeeForge

/// The OTP HID frame protocol against an emulated key that checks every
/// report the way the firmware does.
final class YubiKeyOTPHIDTests: XCTestCase {
    private let timing = YubiKeyOTPHID.Timing(
        writeTimeout: .milliseconds(200),
        responseTimeout: .milliseconds(200),
        touchTimeout: .milliseconds(400),
        pollInterval: .zero,
        touchPollInterval: .zero,
        sleep: { _ in }
    )

    /// A 32-byte KDF salt PKCS#7-padded to 64 bytes, as `ChallengeResponseKey` builds it.
    private let challenge = Data((0..<32).map { UInt8($0 * 7 & 0xFF) } + [UInt8](repeating: 32, count: 32))

    func testCRCMatchesTheOTPApplicationsAndItsResponseResidual() {
        XCTAssertEqual(YubiKeyOTPHID.crc16([UInt8]("123456789".utf8)), 0x6F91)
        let response = [UInt8](repeating: 0xA5, count: 20)
        let crc = ~YubiKeyOTPHID.crc16(response)
        XCTAssertEqual(YubiKeyOTPHID.crc16(response + [UInt8(crc & 0xFF), UInt8(crc >> 8)]), 0xF0B8)
    }

    func testFrameSkipsEmptyMiddleReportsButKeepsTheFirstAndLast() {
        let frame = YubiKeyOTPHID.frame(command: .challengeHMAC2, payload: [UInt8](repeating: 0, count: 64))
        let reports = YubiKeyOTPHID.reports(forFrame: frame)

        // The slot byte and CRC sit in report 9 (bytes 63–69); reports 1–8 carry only zeros.
        XCTAssertEqual(reports.map { $0[7] }, [0x80, 0x89])
        XCTAssertTrue(reports.allSatisfy { $0.count == 8 })
        XCTAssertEqual(reports[1][1], 0x38)
    }

    func testChallengeResponseReturnsTheSlotsHMAC() throws {
        let key = EmulatedOTPKey(slots: [.two: YubiKeyEmulator.fixtureSecret])

        let response = try YubiKeyOTPHID.challengeResponse(challenge, slot: .two, device: key, timing: timing)

        XCTAssertEqual(response, YubiKeyEmulator.response(to: challenge))
        XCTAssertEqual(key.receivedCommand, 0x38)
        XCTAssertTrue(key.wasReset, "A finished read resets the key's read state")
    }

    func testSlotOneUsesItsOwnCommand() throws {
        let key = EmulatedOTPKey(slots: [.one: Data("other".utf8)])

        let response = try YubiKeyOTPHID.challengeResponse(challenge, slot: .one, device: key, timing: timing)

        XCTAssertEqual(key.receivedCommand, 0x30)
        XCTAssertEqual(response, YubiKeyEmulator.response(to: challenge, secret: Data("other".utf8)))
    }

    func testUnconfiguredSlotIsReportedAsSuch() {
        let key = EmulatedOTPKey(slots: [.one: YubiKeyEmulator.fixtureSecret])

        XCTAssertThrowsError(try YubiKeyOTPHID.challengeResponse(challenge, slot: .two, device: key, timing: timing)) {
            XCTAssertEqual($0 as? HardwareKeyError, .slotNotConfigured)
        }
    }

    func testTouchIsAnnouncedOnceThenAnswered() throws {
        let key = EmulatedOTPKey(slots: [.two: YubiKeyEmulator.fixtureSecret], touchPolls: 3)
        var touches = 0

        let response = try YubiKeyOTPHID.challengeResponse(
            challenge, slot: .two, device: key, timing: timing, onTouchRequired: { touches += 1 }
        )

        XCTAssertEqual(touches, 1)
        XCTAssertEqual(response, YubiKeyEmulator.response(to: challenge))
    }

    func testTouchTheKeyGivesUpOnIsATimeout() {
        let key = EmulatedOTPKey(slots: [.two: YubiKeyEmulator.fixtureSecret], touchPolls: 2, touchIsMissed: true)

        XCTAssertThrowsError(try YubiKeyOTPHID.challengeResponse(challenge, slot: .two, device: key, timing: timing)) {
            XCTAssertEqual($0 as? HardwareKeyError, .timedOut)
        }
    }

    func testCancellingDuringATouchAbandonsTheCommandOnTheKey() {
        let key = EmulatedOTPKey(slots: [.two: YubiKeyEmulator.fixtureSecret], touchPolls: .max)
        var touched = false

        XCTAssertThrowsError(try YubiKeyOTPHID.challengeResponse(
            challenge, slot: .two, device: key, timing: timing,
            isCancelled: { touched }, onTouchRequired: { touched = true }
        )) {
            XCTAssertEqual($0 as? HardwareKeyError, .cancelled)
        }
        XCTAssertTrue(key.wasReset, "The key stops waiting for a touch")
    }

    func testCorruptedResponseIsRejected() {
        let key = EmulatedOTPKey(slots: [.two: YubiKeyEmulator.fixtureSecret], corruptsResponse: true)

        XCTAssertThrowsError(try YubiKeyOTPHID.challengeResponse(challenge, slot: .two, device: key, timing: timing)) {
            XCTAssertEqual($0 as? HardwareKeyError, .communicationFailed)
        }
    }

    func testKeyThatNeverTakesAReportTimesOut() {
        let key = EmulatedOTPKey(slots: [:], staysBusy: true)

        XCTAssertThrowsError(try YubiKeyOTPHID.challengeResponse(challenge, slot: .two, device: key, timing: timing)) {
            XCTAssertEqual($0 as? HardwareKeyError, .timedOut)
        }
    }

    func testDeviceErrorsPassThrough() {
        let key = EmulatedOTPKey(slots: [.two: YubiKeyEmulator.fixtureSecret], failure: .disconnected)

        XCTAssertThrowsError(try YubiKeyOTPHID.challengeResponse(challenge, slot: .two, device: key, timing: timing)) {
            XCTAssertEqual($0 as? HardwareKeyError, .disconnected)
        }
    }
}

extension YubiKeyOTPHIDTests {
    /// `ykcore`'s status report: a reserved byte, firmware major/minor/build,
    /// programming sequence, then the touch level (little-endian).
    func testSlotStatusesComeFromTheTouchLevelFlags() throws {
        // Slot 1 set up without touch, slot 2 set up with touch.
        let both = StatusReportDevice(report: [0, 5, 4, 3, 7, 0x0B, 0, 0])
        XCTAssertEqual(try YubiKeyOTPHID.slotStatuses(device: both), [.one: .setUp(needsTouch: false), .two: .setUp(needsTouch: true)])

        let onlyTwo = StatusReportDevice(report: [0, 5, 4, 3, 7, 0x02, 0, 0])
        XCTAssertEqual(try YubiKeyOTPHID.slotStatuses(device: onlyTwo), [.one: .notSetUp, .two: .setUp(needsTouch: false)])
    }

    func testSlotStatusesIgnoreTouchBeforeFirmware3AndAreUnknownBefore21() throws {
        let firmware2 = StatusReportDevice(report: [0, 2, 2, 0, 1, 0x0F, 0, 0])
        XCTAssertEqual(try YubiKeyOTPHID.slotStatuses(device: firmware2), [.one: .setUp(needsTouch: false), .two: .setUp(needsTouch: false)])

        let firmware20 = StatusReportDevice(report: [0, 2, 0, 5, 1, 0x03, 0, 0])
        XCTAssertEqual(try YubiKeyOTPHID.slotStatuses(device: firmware20), [:])
    }
}

#if os(macOS)
/// `MacYubiKeyConnection`'s queue, one-at-a-time rule and cancellation, over
/// the emulated key in place of IOKit.
extension YubiKeyOTPHIDTests {
    private var connectionTiming: YubiKeyOTPHID.Timing {
        YubiKeyOTPHID.Timing(
            writeTimeout: .milliseconds(200),
            responseTimeout: .milliseconds(200),
            touchTimeout: .seconds(10),
            pollInterval: .zero,
            touchPollInterval: .milliseconds(1),
            sleep: { _ in Thread.sleep(forTimeInterval: 0.001) }
        )
    }

    func testConnectionAnswersThroughTheEmulatedKey() async throws {
        nonisolated(unsafe) let key = EmulatedOTPKey(slots: [.two: YubiKeyEmulator.fixtureSecret])
        let connection = MacYubiKeyConnection(isConnected: { true }, openDevice: { key }, timing: connectionTiming)

        let response = try await connection.response(to: challenge, slot: .two)

        XCTAssertEqual(response, YubiKeyEmulator.response(to: challenge))
    }

    func testConnectionRefusesASecondRequestAndCancelStopsTheKeyWaiting() async throws {
        nonisolated(unsafe) let key = EmulatedOTPKey(slots: [.two: YubiKeyEmulator.fixtureSecret], touchPolls: .max)
        let connection = MacYubiKeyConnection(isConnected: { true }, openDevice: { key }, timing: connectionTiming)
        let challenge = challenge
        let waiting = Task { try await connection.response(to: challenge, slot: .two) }
        // Let the first request reach the key's touch wait.
        try await Task.sleep(for: .milliseconds(100))

        do {
            _ = try await connection.response(to: challenge, slot: .two)
            XCTFail("A second request while one runs must fail")
        } catch {
            XCTAssertEqual(error as? HardwareKeyError, .communicationFailed)
        }
        let busyStatuses = await connection.slotStatuses()
        XCTAssertNil(busyStatuses, "No status read while a challenge waits for a touch")

        waiting.cancel()
        do {
            _ = try await waiting.value
            XCTFail("A cancelled request must not answer")
        } catch {
            XCTAssertEqual(error as? HardwareKeyError, .cancelled)
        }
        XCTAssertTrue(key.wasReset, "Cancelling stops the key waiting for a touch")
        let freedStatuses = await connection.slotStatuses()
        XCTAssertEqual(freedStatuses, [.one: .notSetUp, .two: .setUp(needsTouch: true)])
    }

    func testConnectionReportsNoStatusWithoutAKey() async {
        let connection = MacYubiKeyConnection(
            isConnected: { false },
            openDevice: { throw HardwareKeyError.notConnected },
            timing: connectionTiming
        )

        let statuses = await connection.slotStatuses()

        XCTAssertNil(statuses)
    }
}
#endif

private final class StatusReportDevice: YubiKeyOTPReportDevice {
    let report: [UInt8]
    init(report: [UInt8]) { self.report = report }
    func readFeatureReport() throws -> [UInt8] { report }
    func writeFeatureReport(_ report: [UInt8]) throws { XCTFail("A status read writes nothing") }
}

/// A YubiKey's OTP interface as `ykcore` sees it: it takes 8-byte reports
/// flagged `seq | 0x80`, checks the frame CRC, and answers with
/// `0x40 | seq` reports carrying the HMAC and its complemented CRC.
private final class EmulatedOTPKey: YubiKeyOTPReportDevice {
    private enum State {
        case idle
        case touch(remaining: Int)
        case responding([[UInt8]])
    }

    private let slots: [HardwareKeyConfiguration.Slot: Data]
    private let touchPolls: Int
    private let touchIsMissed: Bool
    private let corruptsResponse: Bool
    private let staysBusy: Bool
    private let failure: HardwareKeyError?
    private var frame = [UInt8](repeating: 0, count: 70)
    private var state = State.idle
    private var pendingResponse: [[UInt8]] = []
    private(set) var receivedCommand: UInt8?
    private(set) var wasReset = false

    init(
        slots: [HardwareKeyConfiguration.Slot: Data],
        touchPolls: Int = 0,
        touchIsMissed: Bool = false,
        corruptsResponse: Bool = false,
        staysBusy: Bool = false,
        failure: HardwareKeyError? = nil
    ) {
        self.slots = slots
        self.touchPolls = touchPolls
        self.touchIsMissed = touchIsMissed
        self.corruptsResponse = corruptsResponse
        self.staysBusy = staysBusy
        self.failure = failure
    }

    func readFeatureReport() throws -> [UInt8] {
        if let failure { throw failure }
        if staysBusy { return [0, 0, 0, 0, 0, 0, 0, 0x80] }
        switch state {
        case .idle:
            return idleStatus
        case .touch(let remaining):
            if remaining <= 0 {
                if touchIsMissed {
                    state = .idle
                    return idleStatus
                }
                state = .responding(pendingResponse)
                return try readFeatureReport()
            }
            state = .touch(remaining: remaining == .max ? remaining : remaining - 1)
            return [0, 0, 0, 0, 0, 0, 0, 0x20 | 15]
        case .responding(var reports):
            guard reports.isEmpty == false else { return [0, 0, 0, 0, 0, 0, 0, 0x40] }
            let report = reports.removeFirst()
            state = .responding(reports)
            return report
        }
    }

    /// Firmware 5.4.3 with each configured slot flagged valid, and touch
    /// flagged when this key waits for one.
    private var idleStatus: [UInt8] {
        var touchLevel: UInt8 = 0
        if slots[.one] != nil { touchLevel |= touchPolls > 0 ? 0x05 : 0x01 }
        if slots[.two] != nil { touchLevel |= touchPolls > 0 ? 0x0A : 0x02 }
        return [0, 5, 4, 3, 1, touchLevel, 0, 0]
    }

    func writeFeatureReport(_ report: [UInt8]) throws {
        XCTAssertEqual(report.count, 8)
        if report[7] == 0x8F {
            wasReset = true
            state = .idle
            return
        }
        XCTAssertEqual(report[7] & 0x80, 0x80)
        let sequence = Int(report[7] & 0x1F)
        if sequence == 0 { frame = [UInt8](repeating: 0, count: 70) }
        frame.replaceSubrange((sequence * 7)..<(sequence * 7 + 7), with: report[0..<7])
        if sequence == 9 { process() }
    }

    private func process() {
        let payload = Array(frame[0..<64])
        let command = frame[64]
        receivedCommand = command
        let crc = UInt16(frame[65]) | UInt16(frame[66]) << 8
        XCTAssertEqual(crc, YubiKeyOTPHID.crc16(payload), "Frame CRC")
        let slot: HardwareKeyConfiguration.Slot? = switch command {
        case 0x30: .one
        case 0x38: .two
        default: nil
        }
        guard let slot, let secret = slots[slot] else {
            state = .idle
            return
        }
        var bytes = [UInt8](YubiKeyEmulator.response(to: Data(payload), secret: secret))
        let responseCRC = ~YubiKeyOTPHID.crc16(bytes)
        bytes += [UInt8(responseCRC & 0xFF), UInt8(responseCRC >> 8)]
        if corruptsResponse { bytes[0] ^= 0xFF }
        bytes += [UInt8](repeating: 0, count: 28 - bytes.count)
        pendingResponse = (0..<4).map { index in
            Array(bytes[(index * 7)..<(index * 7 + 7)]) + [0x40 | UInt8(index)]
        }
        state = touchPolls > 0 ? .touch(remaining: touchPolls) : .responding(pendingResponse)
    }
}
