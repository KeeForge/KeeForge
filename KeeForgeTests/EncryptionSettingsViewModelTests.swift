import XCTest
import KDBXKit
@testable import KeeForge

@MainActor
final class EncryptionSettingsViewModelTests: XCTestCase {
    private final class ChangeRecorder {
        var calls: [(cipher: DatabaseCreationCipher?, keyDerivation: EncryptionSettingsKeyDerivation?, isCompressed: Bool?)] = []
    }

    func testOfferedSettingsAreSelectedWithoutACurrentOption() {
        let viewModel = makeViewModel(
            current: summary(cipher: .chaCha20, keyDerivation: preset(.strong), isCompressed: true)
        )

        XCTAssertEqual(viewModel.cipher, .chacha20)
        XCTAssertEqual(viewModel.keyDerivation, .argon2id(.strong))
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

        XCTAssertEqual(viewModel.keyDerivation, .argon2id(.balanced))
    }

    func testSettingsOutsideTheOfferedSetKeepACurrentOption() {
        let viewModel = makeViewModel(
            current: summary(
                cipher: .twofish256CBC,
                keyDerivation: .argon2d(iterations: 2, memoryBytes: 64 << 20, parallelism: 2)
            )
        )

        XCTAssertNil(viewModel.cipher)
        XCTAssertNil(viewModel.keyDerivation)
        XCTAssertTrue(viewModel.showsCurrentCipherOption)
        XCTAssertTrue(viewModel.showsCurrentKDFOption)
        XCTAssertFalse(viewModel.showsAESKDFRounds)
        XCTAssertEqual(viewModel.currentCipherOptionTitle, "Twofish-256-CBC (Current)")
        XCTAssertEqual(viewModel.currentKDFOptionTitle, "Argon2d (Current)")
        XCTAssertFalse(viewModel.hasChanges)
    }

    func testArgon2idWithCustomCostsIsNotMistakenForAPreset() {
        let viewModel = makeViewModel(
            current: summary(keyDerivation: .argon2id(iterations: 2, memoryBytes: 64 << 20, parallelism: 2))
        )

        XCTAssertNil(viewModel.keyDerivation)
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
        XCTAssertNil(recorder.calls.first?.keyDerivation, "An unchanged AES-KDF must not be rewritten")
        XCTAssertEqual(recorder.calls.first?.isCompressed, false)
    }

    func testPerformChangePassesChosenCipherAndPreset() async {
        let recorder = ChangeRecorder()
        let viewModel = makeViewModel(
            current: summary(cipher: .twofish256CBC, keyDerivation: .aesKDF(rounds: 60_000), isCompressed: true),
            recorder: recorder
        )

        viewModel.cipher = .chacha20
        viewModel.keyDerivation = .argon2id(.maximum)
        _ = await viewModel.performChange()

        XCTAssertEqual(recorder.calls.first?.cipher, .chacha20)
        XCTAssertEqual(recorder.calls.first?.keyDerivation, .argon2id(.maximum))
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
        viewModel.keyDerivation = .argon2id(.strong)
        viewModel.keyDerivation = .argon2id(.balanced)

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

        viewModel.keyDerivation = .argon2id(.balanced)
        XCTAssertEqual(
            viewModel.keyDerivationSummary,
            "Argon2id key derivation (\(DatabaseCreationKDFPreset.balanced.parameterSummary))."
        )
    }

    // MARK: - AES-KDF

    func testAESKDFFileIsSelectedWithItsRounds() {
        let viewModel = makeViewModel(current: summary(keyDerivation: .aesKDF(rounds: 60_000)))

        XCTAssertEqual(viewModel.keyDerivation, .aesKDF)
        XCTAssertEqual(viewModel.aesKDFRoundsText, "60000")
        XCTAssertEqual(viewModel.aesKDFRounds, 60_000)
        XCTAssertTrue(viewModel.showsAESKDFRounds)
        XCTAssertFalse(viewModel.showsCurrentKDFOption, "AES-KDF is an offered choice, not a (Current) one")
        XCTAssertNil(viewModel.aesKDFRoundsError)
        XCTAssertFalse(viewModel.hasChanges)
    }

    func testAESKDFIsOfferedAfterTheArgon2idPresets() {
        XCTAssertEqual(
            EncryptionSettingsViewModel.KeyDerivationOption.allCases,
            [.argon2id(.balanced), .argon2id(.strong), .argon2id(.maximum), .aesKDF]
        )
        XCTAssertEqual(EncryptionSettingsViewModel.KeyDerivationOption.aesKDF.displayName, "AES-KDF")
    }

    func testChoosingAESKDFPassesTheDefaultRounds() async {
        let recorder = ChangeRecorder()
        let viewModel = makeViewModel(current: summary(keyDerivation: preset(.balanced)), recorder: recorder)
        XCTAssertFalse(viewModel.showsAESKDFRounds)

        viewModel.keyDerivation = .aesKDF

        XCTAssertTrue(viewModel.showsAESKDFRounds)
        XCTAssertEqual(viewModel.aesKDFRounds, DatabaseCreationDefaults.aesKDFRounds)
        XCTAssertTrue(viewModel.canSave)
        let succeeded = await viewModel.performChange()

        XCTAssertTrue(succeeded)
        XCTAssertEqual(recorder.calls.count, 1)
        XCTAssertNil(recorder.calls.first?.cipher, "Choosing AES-KDF must not touch the cipher")
        XCTAssertEqual(recorder.calls.first?.keyDerivation, .aesKDF(rounds: DatabaseCreationDefaults.aesKDFRounds))
        XCTAssertNil(recorder.calls.first?.isCompressed)
    }

    func testChangingAESKDFRoundsPassesTheNewRounds() async {
        let recorder = ChangeRecorder()
        let viewModel = makeViewModel(current: summary(keyDerivation: .aesKDF(rounds: 60_000)), recorder: recorder)

        viewModel.aesKDFRoundsText = "060000"
        XCTAssertFalse(viewModel.hasChanges, "The same rounds are not a change")

        viewModel.aesKDFRoundsText = "2000000"
        XCTAssertTrue(viewModel.canSave)
        _ = await viewModel.performChange()

        XCTAssertEqual(recorder.calls.first?.keyDerivation, .aesKDF(rounds: 2_000_000))
    }

    func testInvalidAESKDFRoundsBlockSaving() async {
        let recorder = ChangeRecorder()
        let viewModel = makeViewModel(current: summary(keyDerivation: .aesKDF(rounds: 60_000)), recorder: recorder)

        for text in ["", "0", "12a", "-5", "1 000", String(KDBXKeyDerivation.aesKDFMaxRounds + 1)] {
            viewModel.aesKDFRoundsText = text
            XCTAssertNil(viewModel.aesKDFRounds, text)
            XCTAssertNotNil(viewModel.aesKDFRoundsError, text)
            XCTAssertTrue(viewModel.hasChanges, text)
            XCTAssertFalse(viewModel.canSave, text)
            let succeeded = await viewModel.performChange()
            XCTAssertFalse(succeeded, text)
        }
        XCTAssertTrue(recorder.calls.isEmpty)
        XCTAssertEqual(viewModel.keyDerivationSummary, "AES-KDF")

        viewModel.aesKDFRoundsText = String(KDBXKeyDerivation.aesKDFMaxRounds)
        XCTAssertNil(viewModel.aesKDFRoundsError)
        XCTAssertTrue(viewModel.canSave)
    }

    func testLeavingAESKDFIgnoresItsRoundsField() async {
        let recorder = ChangeRecorder()
        let viewModel = makeViewModel(current: summary(keyDerivation: .aesKDF(rounds: 60_000)), recorder: recorder)

        viewModel.aesKDFRoundsText = ""
        viewModel.keyDerivation = .argon2id(.balanced)

        XCTAssertFalse(viewModel.showsAESKDFRounds)
        XCTAssertNil(viewModel.aesKDFRoundsError)
        XCTAssertTrue(viewModel.canSave)
        _ = await viewModel.performChange()

        XCTAssertEqual(recorder.calls.first?.keyDerivation, .argon2id(.balanced))
    }

    func testAESKDFSummaryFollowsTheEditedRounds() {
        let viewModel = makeViewModel(current: summary(keyDerivation: preset(.balanced)))

        viewModel.keyDerivation = .aesKDF
        viewModel.aesKDFRoundsText = "250000"

        let expected = KDBXFileSummary(
            formatVersion: .kdbx4(minor: 0),
            cipher: .aes256CBC,
            isCompressed: true,
            keyDerivation: .aesKDF(rounds: 250_000)
        )
        let rounds = expected.keyDerivationDetailText ?? ""
        XCTAssertEqual(viewModel.keyDerivationSummary, "AES-KDF key derivation (\(rounds)).")
    }

    func testAESKDFParametersMatchWhatKeePassWrites() throws {
        let parameters = try EncryptionSettingsKeyDerivation.aesKDF(rounds: 123_456).kdfParameters()

        XCTAssertEqual(parameters.bytes("$UUID"), KDBXKeyDerivation.Algorithm.aesKDF.uuid)
        XCTAssertEqual(parameters["R"], .uint64(123_456))
        XCTAssertEqual(parameters.bytes("S")?.count, 32, "AES-KDF takes a 256-bit seed")
        XCTAssertEqual(Set(parameters.entries.keys), ["$UUID", "R", "S"])
    }

    // MARK: - Benchmark

    private final class BenchmarkProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls = 0
        private var _onMain: [Bool] = []
        private var _running = 0
        private var _maxRunning = 0
        let release = DispatchSemaphore(value: 0)
        var holds = false
        var calls: Int { lock.withLock { _calls } }
        var onMain: [Bool] { lock.withLock { _onMain } }
        var maxRunning: Int { lock.withLock { _maxRunning } }

        func measure(_ parameters: KDBXVariantMap) throws -> Double {
            lock.withLock {
                _calls += 1
                _onMain.append(Thread.isMainThread)
                _running += 1
                _maxRunning = max(_maxRunning, _running)
            }
            if holds { release.wait() }
            lock.withLock { _running -= 1 }
            XCTAssertNotNil(parameters.bytes("$UUID"))
            return 0.64
        }
    }

    private func makeBenchmarkViewModel(_ probe: BenchmarkProbe) -> EncryptionSettingsViewModel {
        EncryptionSettingsViewModel(current: summary(), measure: { try probe.measure($0) }) { _, _, _ in }
    }

    func testBenchmarkRunsOffTheMainThreadOnlyWhenAsked() async {
        let probe = BenchmarkProbe()
        let viewModel = makeBenchmarkViewModel(probe)
        viewModel.keyDerivation = .argon2id(.strong)
        viewModel.keyDerivation = .aesKDF
        viewModel.aesKDFRoundsText = "2000"
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(probe.calls, 0, "Nothing runs without the button")
        XCTAssertFalse(viewModel.isBenchmarking)

        let task = viewModel.benchmark()
        XCTAssertTrue(viewModel.isBenchmarking)
        XCTAssertFalse(viewModel.canBenchmark)
        await task?.value

        XCTAssertEqual(probe.calls, 1)
        XCTAssertEqual(probe.onMain, [false])
        XCTAssertEqual(viewModel.benchmarkSeconds, 0.64)
        XCTAssertFalse(viewModel.isBenchmarking)
        XCTAssertTrue(viewModel.hasChanges, "The benchmark does not undo the edit")
    }

    func testBenchmarkIsRefusedForInvalidRoundsOrTheCurrentOption() {
        let probe = BenchmarkProbe()
        let viewModel = makeBenchmarkViewModel(probe)
        viewModel.keyDerivation = .aesKDF
        viewModel.aesKDFRoundsText = "0"
        XCTAssertFalse(viewModel.canBenchmark)
        XCTAssertNil(viewModel.benchmark())

        let current = EncryptionSettingsViewModel(current: summary(keyDerivation: .argon2d(iterations: 2, memoryBytes: 64 << 20, parallelism: 2)),
                                                  measure: { try probe.measure($0) }) { _, _, _ in }
        XCTAssertFalse(current.canBenchmark, "\"(Current)\" is not a setting KeeForge writes")
        XCTAssertEqual(current.currentKDFOptionTitle, "Argon2d (Current)")
        XCTAssertEqual(probe.calls, 0)
    }

    func testCancelledBenchmarkDiscardsItsResultAndTheNextWaitsForIt() async {
        let probe = BenchmarkProbe()
        probe.holds = true
        let viewModel = makeBenchmarkViewModel(probe)
        let first = viewModel.benchmark()
        while probe.calls == 0 { await Task.yield() }

        viewModel.keyDerivation = .argon2id(.maximum)
        XCTAssertFalse(viewModel.isBenchmarking)
        let second = viewModel.benchmark()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(probe.calls, 1, "A derivation cannot stop midway, so the next waits for it")

        probe.release.signal()
        await first?.value
        while probe.calls < 2 { await Task.yield() }
        viewModel.cancelBenchmark()
        probe.release.signal()
        await second?.value

        XCTAssertNil(viewModel.benchmarkSeconds, "A cancelled measurement is never shown")
        XCTAssertFalse(viewModel.isBenchmarking)
        XCTAssertEqual(probe.maxRunning, 1)
    }

    func testSavingCancelsABenchmark() async {
        let probe = BenchmarkProbe()
        probe.holds = true
        let recorder = ChangeRecorder()
        let viewModel = EncryptionSettingsViewModel(current: summary(), measure: { try probe.measure($0) }) { cipher, kdf, compressed in
            recorder.calls.append((cipher, kdf, compressed))
        }
        viewModel.cipher = .chacha20
        let benchmark = viewModel.benchmark()
        while probe.calls == 0 { await Task.yield() }

        let saved = await viewModel.performChange()
        probe.release.signal()
        await benchmark?.value

        XCTAssertTrue(saved)
        XCTAssertEqual(recorder.calls.count, 1)
        XCTAssertNil(viewModel.benchmarkSeconds)
        XCTAssertFalse(viewModel.isBenchmarking)
    }

    func testRealMeasurementDerivesTheSelectedParameters() throws {
        let parameters = try EncryptionSettingsKeyDerivation.aesKDF(rounds: 1_000).kdfParameters()
        XCTAssertGreaterThanOrEqual(try EncryptionSettingsViewModel.measureDerivation(parameters), 0)
    }

    // MARK: - Helpers

    private func makeViewModel(
        current: KDBXFileSummary,
        recorder: ChangeRecorder = ChangeRecorder()
    ) -> EncryptionSettingsViewModel {
        EncryptionSettingsViewModel(current: current) { cipher, keyDerivation, isCompressed in
            recorder.calls.append((cipher, keyDerivation, isCompressed))
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
