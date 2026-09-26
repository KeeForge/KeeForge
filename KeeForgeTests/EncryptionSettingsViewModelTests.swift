import XCTest
@testable import KeeForge

@MainActor
final class EncryptionSettingsViewModelTests: XCTestCase {
    private final class ChangeRecorder {
        var calls: [(cipher: DatabaseCreationCipher?, kdfPreset: DatabaseCreationKDFPreset?, isCompressed: Bool?)] = []
    }

    func testOfferedSettingsAreSelectedWithoutACurrentOption() {
        let viewModel = makeViewModel(
            current: summary(cipher: .chacha20, keyDerivation: preset(.strong), isCompressed: true)
        )

        XCTAssertEqual(viewModel.cipher, .chacha20)
        XCTAssertEqual(viewModel.kdfPreset, .strong)
        XCTAssertTrue(viewModel.isCompressed)
        XCTAssertFalse(viewModel.showsCurrentCipherOption)
        XCTAssertFalse(viewModel.showsCurrentKDFOption)
        XCTAssertFalse(viewModel.hasChanges)
    }

    func testPresetMatchIgnoresParallelism() {
        let viewModel = makeViewModel(
            current: summary(
                keyDerivation: .argon2id(
                    iterations: DatabaseCreationKDFPreset.balanced.iterations,
                    memoryBytes: DatabaseCreationKDFPreset.balanced.memoryBytes,
                    parallelism: 7
                )
            )
        )

        XCTAssertEqual(viewModel.kdfPreset, .balanced)
    }

    func testSettingsOutsideTheOfferedSetKeepACurrentOption() {
        let viewModel = makeViewModel(
            current: summary(cipher: .twofish256CBC, keyDerivation: .aesKDF(rounds: 60_000))
        )

        XCTAssertNil(viewModel.cipher)
        XCTAssertNil(viewModel.kdfPreset)
        XCTAssertTrue(viewModel.showsCurrentCipherOption)
        XCTAssertTrue(viewModel.showsCurrentKDFOption)
        XCTAssertEqual(viewModel.currentCipherOptionTitle, "Twofish-256-CBC (Current)")
        XCTAssertEqual(viewModel.currentKDFOptionTitle, "AES-KDF (Current)")
        XCTAssertFalse(viewModel.hasChanges)
    }

    func testArgon2idWithCustomCostsIsNotMistakenForAPreset() {
        let viewModel = makeViewModel(
            current: summary(keyDerivation: .argon2id(iterations: 2, memoryBytes: 64 << 20, parallelism: 2))
        )

        XCTAssertNil(viewModel.kdfPreset)
        XCTAssertTrue(viewModel.showsCurrentKDFOption)
    }

    func testPerformChangePassesOnlyTheChangedSettings() async {
        let recorder = ChangeRecorder()
        let viewModel = makeViewModel(
            current: summary(cipher: .aes256CBC, keyDerivation: .aesKDF(rounds: 60_000), isCompressed: true),
            recorder: recorder
        )

        viewModel.isCompressed = false
        XCTAssertTrue(viewModel.hasChanges)
        let succeeded = await viewModel.performChange()

        XCTAssertTrue(succeeded)
        XCTAssertEqual(recorder.calls.count, 1)
        XCTAssertNil(recorder.calls.first?.cipher)
        XCTAssertNil(recorder.calls.first?.kdfPreset)
        XCTAssertEqual(recorder.calls.first?.isCompressed, false)
    }

    func testPerformChangePassesChosenCipherAndPreset() async {
        let recorder = ChangeRecorder()
        let viewModel = makeViewModel(
            current: summary(cipher: .twofish256CBC, keyDerivation: .aesKDF(rounds: 60_000), isCompressed: true),
            recorder: recorder
        )

        viewModel.cipher = .chacha20
        viewModel.kdfPreset = .maximum
        _ = await viewModel.performChange()

        XCTAssertEqual(recorder.calls.first?.cipher, .chacha20)
        XCTAssertEqual(recorder.calls.first?.kdfPreset, .maximum)
        XCTAssertNil(recorder.calls.first?.isCompressed)
    }

    func testReturningToTheCurrentValuesIsNotAChange() async {
        let recorder = ChangeRecorder()
        let viewModel = makeViewModel(
            current: summary(cipher: .twofish256CBC, keyDerivation: preset(.balanced)),
            recorder: recorder
        )

        viewModel.cipher = .aes256
        viewModel.cipher = nil
        viewModel.kdfPreset = .strong
        viewModel.kdfPreset = .balanced

        XCTAssertFalse(viewModel.hasChanges)
        let succeeded = await viewModel.performChange()
        XCTAssertFalse(succeeded)
        XCTAssertTrue(recorder.calls.isEmpty)
    }

    func testFailureShowsMessageAndEditingClearsIt() async {
        let viewModel = EncryptionSettingsViewModel(
            current: summary(isCompressed: true),
            changeOperation: { _, _, _ in
                throw DatabaseViewModel.EncryptionSettingsError.pendingUploadsExist
            }
        )

        viewModel.isCompressed = false
        let succeeded = await viewModel.performChange()

        XCTAssertFalse(succeeded)
        XCTAssertFalse(viewModel.isWorking)
        XCTAssertEqual(
            viewModel.changeError,
            EncryptionSettingsViewModel.message(for: DatabaseViewModel.EncryptionSettingsError.pendingUploadsExist)
        )

        viewModel.cipher = .chacha20
        XCTAssertNil(viewModel.changeError)
    }

    func testMessagesCoverEveryRejection() {
        let errors: [DatabaseViewModel.EncryptionSettingsError] = [
            .sessionUnavailable,
            .databaseIsReadOnly,
            .saveInProgress,
            .unsavedChanges,
            .pendingUploadsExist,
            .conflict,
        ]
        let messages = errors.map { EncryptionSettingsViewModel.message(for: $0) }

        XCTAssertEqual(Set(messages).count, errors.count)
        for (error, message) in zip(errors, messages) {
            XCTAssertNotEqual(message, error.localizedDescription, "\(error) has no user-facing message")
        }
        XCTAssertEqual(
            EncryptionSettingsViewModel.message(for: SaveError.reencryptionVerificationFailed),
            SaveError.reencryptionVerificationFailed.localizedDescription
        )
    }

    func testKeyDerivationSummaryDescribesTheSelection() throws {
        let viewModel = makeViewModel(
            current: summary(keyDerivation: .aesKDF(rounds: 60_000))
        )

        let rounds = try XCTUnwrap(viewModel.current.keyDerivationDetailText)
        XCTAssertEqual(viewModel.keyDerivationSummary, "AES-KDF key derivation (\(rounds)).")

        viewModel.kdfPreset = .balanced
        XCTAssertEqual(
            viewModel.keyDerivationSummary,
            "Argon2id key derivation (\(DatabaseCreationKDFPreset.balanced.parameterSummary))."
        )
    }

    // MARK: - Helpers

    private func makeViewModel(
        current: KDBXFileSummary,
        recorder: ChangeRecorder = ChangeRecorder()
    ) -> EncryptionSettingsViewModel {
        EncryptionSettingsViewModel(current: current) { cipher, kdfPreset, isCompressed in
            recorder.calls.append((cipher, kdfPreset, isCompressed))
        }
    }

    private func summary(
        cipher: KDBXOuterCipher = .aes256CBC,
        keyDerivation: KDBXFileSummary.KeyDerivation = .argon2id(
            iterations: DatabaseCreationKDFPreset.balanced.iterations,
            memoryBytes: DatabaseCreationKDFPreset.balanced.memoryBytes,
            parallelism: 2
        ),
        isCompressed: Bool = true
    ) -> KDBXFileSummary {
        KDBXFileSummary(
            formatVersion: .kdbx4(minor: 0),
            cipher: cipher,
            isCompressed: isCompressed,
            keyDerivation: keyDerivation
        )
    }

    private func preset(_ preset: DatabaseCreationKDFPreset) -> KDBXFileSummary.KeyDerivation {
        .argon2id(iterations: preset.iterations, memoryBytes: preset.memoryBytes, parallelism: 2)
    }
}
