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
}
