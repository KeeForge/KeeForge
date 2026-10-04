import CryptoKit
import XCTest
@testable import KeeForge

@MainActor
final class TOTPViewModelTests: XCTestCase {
    private let testKey = SymmetricKey(size: .bits256)

    private func encryptSecret(_ secret: String) -> EncryptedValue {
        try! EncryptedValue.encrypt(secret, using: testKey)
    }

    func testInitComputesInitialCodeAndTimingValues() {
        let vm = TOTPViewModel(config: TOTPConfig(secret: encryptSecret("JBSWY3DPEHPK3PXP"), period: 30, digits: 6, algorithm: .sha1), sessionKey: testKey)

        XCTAssertEqual(vm.period, 30)
        XCTAssertNotEqual(vm.code, "------")
        XCTAssertTrue((1...30).contains(vm.secondsRemaining))
        XCTAssertTrue((0...1).contains(vm.progress))
    }

    func testStartAndStopCanBeCalledRepeatedly() {
        let vm = TOTPViewModel(config: TOTPConfig(secret: encryptSecret("JBSWY3DPEHPK3PXP")), sessionKey: testKey)

        vm.start()
        vm.stop()
        vm.stop()
        vm.start()

        XCTAssertNotEqual(vm.code, "------")
        XCTAssertTrue((1...vm.period).contains(vm.secondsRemaining))

        vm.stop()
    }

    func testGroupedCodeSplitsAnEvenLengthCodeInTheMiddle() {
        XCTAssertEqual(TOTPViewModel.grouped("284019"), "284 019")
        XCTAssertEqual(TOTPViewModel.grouped("12345678"), "1234 5678")
        XCTAssertEqual(TOTPViewModel.grouped("1234567"), "1234567", "Seven digits have no middle to split at")
        XCTAssertEqual(TOTPViewModel.grouped("------"), "--- ---")
    }

    func testUpdatingConfigurationReplacesCodeAndCountdown() {
        let vm = TOTPViewModel(config: TOTPConfig(secret: encryptSecret("JBSWY3DPEHPK3PXP")), sessionKey: testKey)
        vm.start()
        defer { vm.stop() }
        let updated = TOTPConfig(
            secret: encryptSecret("GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"),
            period: 60,
            digits: 8,
            algorithm: .sha256
        )
        let date = Date(timeIntervalSince1970: 1234)

        vm.update(config: updated, sessionKey: testKey, date: date)

        XCTAssertEqual(vm.code, TOTPGenerator.generateCode(config: updated, sessionKey: testKey, date: date))
        XCTAssertEqual(vm.code.count, 8)
        XCTAssertEqual(vm.period, 60)
        XCTAssertEqual(vm.secondsRemaining, 26)
        XCTAssertEqual(vm.progress, 26.0 / 60.0)
    }

    func testUpdatingDecodedSecretAndSessionKeyUsesReplacementKey() throws {
        let vm = TOTPViewModel(config: TOTPConfig(secret: encryptSecret("JBSWY3DPEHPK3PXP")), sessionKey: testKey)
        let replacementKey = SymmetricKey(size: .bits256)
        let updated = TOTPConfig(
            secret: .empty,
            decodedSecret: try EncryptedValue.encrypt(Data("replacement secret".utf8), using: replacementKey)
        )
        let date = Date(timeIntervalSince1970: 1234)

        vm.update(config: updated, sessionKey: replacementKey, date: date)

        XCTAssertEqual(vm.code, TOTPGenerator.generateCode(config: updated, sessionKey: replacementKey, date: date))
        XCTAssertNotEqual(vm.code, "------")
    }

    func testUpdatingToUnreadableSecretDoesNotKeepPreviousCode() {
        let vm = TOTPViewModel(config: TOTPConfig(secret: encryptSecret("JBSWY3DPEHPK3PXP")), sessionKey: testKey)

        vm.update(config: TOTPConfig(secret: encryptSecret("not a valid secret!")), sessionKey: testKey)

        XCTAssertEqual(vm.code, "------")
    }
}
