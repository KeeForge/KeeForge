import XCTest
@testable import KeeForge

final class CSVReaderTests: XCTestCase {
    func testQuotedFieldsKeepCommasQuotesAndLineBreaks() throws {
        let text = "a,\"b,c\",\"say \"\"hi\"\"\",\"line one\r\nline two\"\r\nnext,row,,\n"

        let records = try CSVReader.records(in: text)

        XCTAssertEqual(records, [
            .init(fields: ["a", "b,c", "say \"hi\"", "line one\r\nline two"], isMalformed: false),
            .init(fields: ["next", "row", "", ""], isMalformed: false),
        ])
    }

    /// Swift folds "\r\n" into one `Character`; a reader that iterated
    /// characters would never see the record break.
    func testEveryLineEndingEndsARecord() throws {
        let records = try CSVReader.records(in: "a\r\nb\rc\nd")

        XCTAssertEqual(records.map(\.fields), [["a"], ["b"], ["c"], ["d"]])
    }

    func testByteOrderMarkAndBlankLinesAreIgnored() throws {
        let records = try CSVReader.records(in: "\u{FEFF}Title,URL\n\nx,y\n\n")

        XCTAssertEqual(records.map(\.fields), [["Title", "URL"], ["x", "y"]])
    }

    func testEmptyQuotedFieldIsARecord() throws {
        XCTAssertEqual(try CSVReader.records(in: "\"\"\n").map(\.fields), [[""]])
    }

    func testUnicodeSurvivesVerbatim() throws {
        let records = try CSVReader.records(in: "Grüße,密码,🔑👩🏽‍💻,\"é\u{301}\"\n")

        XCTAssertEqual(records.first?.fields, ["Grüße", "密码", "🔑👩🏽‍💻", "é\u{301}"])
    }

    func testStrayQuotesMarkTheRecordMalformed() throws {
        let records = try CSVReader.records(in: "ab\"c,d\n\"x\"y,z\nok,fine\n")

        XCTAssertEqual(records.map(\.isMalformed), [true, true, false])
    }

    func testUnterminatedQuoteRejectsTheFile() {
        XCTAssertThrowsError(try CSVReader.records(in: "a,b\n\"never closed,c\nd,e\n")) { error in
            XCTAssertEqual(error as? CSVReader.ReadError, .unterminatedQuotedField(recordIndex: 1))
        }
    }
}

final class ApplePasswordsCSVImporterTests: XCTestCase {
    private let header = "Title,URL,Username,Password,Notes,OTPAuth\n"

    func testMapsEveryColumnOfAnApplePasswordsExport() throws {
        let csv = header + "example.com (me@example.com),https://example.com/,me@example.com,\"p,ss\"\"word \",\"first\nsecond\",\n"

        let preview = try ApplePasswordsCSVImporter.preview(from: Data(csv.utf8))

        XCTAssertTrue(preview.skippedRows.isEmpty)
        let item = try XCTUnwrap(preview.items.first)
        XCTAssertEqual(item.row, 2)
        XCTAssertEqual(item.draft.title, "example.com (me@example.com)")
        XCTAssertEqual(item.draft.url, "https://example.com/")
        XCTAssertEqual(item.draft.username, "me@example.com")
        XCTAssertEqual(item.draft.password, "p,ss\"word ", "passwords are kept verbatim, trailing space included")
        XCTAssertEqual(item.draft.notes, "first\nsecond")
        XCTAssertNil(item.draft.totpConfig)
        XCTAssertTrue(item.draft.customFields.isEmpty)
    }

    func testTOTPLinkBecomesAVerificationCodeStoredVerbatim() throws {
        let link = "otpauth://totp/Example:me@example.com?secret=JBSWY3DPEHPK3PXP&issuer=Example&digits=8&period=60&algorithm=SHA256"
        let csv = header + "Example,https://example.com,me,pw,,\(link)\n"

        let item = try XCTUnwrap(try ApplePasswordsCSVImporter.preview(from: Data(csv.utf8)).items.first)

        let totp = try XCTUnwrap(item.draft.totpConfig)
        XCTAssertEqual(totp.secret, "JBSWY3DPEHPK3PXP")
        XCTAssertEqual(totp.digits, 8)
        XCTAssertEqual(totp.period, 60)
        XCTAssertEqual(totp.algorithm, .sha256)
        XCTAssertEqual(totp.otpauthURI, link)
        XCTAssertFalse(item.keepsUnsupportedVerificationCode)
    }

    /// An HOTP or otherwise unusable link is still login data: it must land
    /// in the entry, protected, rather than vanish.
    func testUnsupportedVerificationLinkIsKeptAsAProtectedField() throws {
        let link = "otpauth://hotp/Example?secret=JBSWY3DPEHPK3PXP&counter=1"
        let csv = header + "Example,https://example.com,me,pw,,\(link)\n"

        let preview = try ApplePasswordsCSVImporter.preview(from: Data(csv.utf8))
        let item = try XCTUnwrap(preview.items.first)

        XCTAssertNil(item.draft.totpConfig)
        XCTAssertEqual(item.draft.customFields, [PasswordImport.unsupportedOTPFieldName: link])
        XCTAssertEqual(item.draft.protectedCustomFieldKeys, [PasswordImport.unsupportedOTPFieldName])
        XCTAssertTrue(item.keepsUnsupportedVerificationCode)
        XCTAssertEqual(preview.unsupportedVerificationCodeCount, 1)
        XCTAssertEqual(preview.verificationCodeCount, 0)
    }

    func testColumnsAreMatchedByNameInAnyOrderAndCase() throws {
        let csv = "password,USERNAME,url,Title\r\nsecret,me,https://example.com,Example\r\n"

        let item = try XCTUnwrap(try ApplePasswordsCSVImporter.preview(from: Data(csv.utf8)).items.first)

        XCTAssertEqual(item.draft.title, "Example")
        XCTAssertEqual(item.draft.username, "me")
        XCTAssertEqual(item.draft.password, "secret")
        XCTAssertEqual(item.draft.url, "https://example.com")
        XCTAssertEqual(item.draft.notes, "")
    }

    func testRowsThatCannotBeImportedAreReportedWithReasons() throws {
        let csv = header
            + "Good,https://a.example,me,pw,,\n"
            + "Short,https://b.example,me\n"
            + "Bad\"Quote,https://c.example,me,pw,,\n"
            + ",,,,,\n"
            + " , , , , , \n"
            + "Only Notes,,,,a note,\n"

        let preview = try ApplePasswordsCSVImporter.preview(from: Data(csv.utf8))

        XCTAssertEqual(preview.items.map(\.row), [2, 7])
        XCTAssertEqual(preview.skippedRows, [
            .init(row: 3, reason: .columnCountMismatch),
            .init(row: 4, reason: .malformedQuoting),
            .init(row: 5, reason: .noLoginData),
            .init(row: 6, reason: .noLoginData),
        ])
    }

    func testRowNumbersCountRecordsNotLines() throws {
        let csv = header + "One,,,,\"multi\nline\nnote\",\n" + "Two,,,,,\n"

        let preview = try ApplePasswordsCSVImporter.preview(from: Data(csv.utf8))

        XCTAssertEqual(preview.items.map(\.row), [2, 3])
    }

    /// Only Apple's own columns are accepted: an arbitrary CSV must not be
    /// presented as compatible, and an extra column would be dropped silently.
    func testFilesThatAreNotAnApplePasswordsExportAreRejected() {
        let rejected = [
            "name,url,username,password,note\nx,y,z,w,v\n",
            "Title,URL,Username,Password,Notes,OTPAuth,Group\na,b,c,d,e,f,g\n",
            "Title,URL,Username,Notes\na,b,c,d\n",
            "Title,URL,Username,Password,Password\na,b,c,d,e\n",
            "\"Title\"x,URL,Username,Password\na,b,c,d\n",
            "",
        ]
        for csv in rejected {
            XCTAssertThrowsError(try ApplePasswordsCSVImporter.preview(from: Data(csv.utf8)), csv) { error in
                XCTAssertEqual(error as? PasswordImportError, .unrecognizedFormat, csv)
            }
        }
    }

    func testOlderSafariExportWithoutNotesOrOTPAuthIsAccepted() throws {
        let csv = "Title,URL,Username,Password\nOld,https://old.example,me,pw\n"

        XCTAssertEqual(try ApplePasswordsCSVImporter.preview(from: Data(csv.utf8)).items.count, 1)
    }

    func testHeaderOnlyFileHasNoPasswords() {
        XCTAssertThrowsError(try ApplePasswordsCSVImporter.preview(from: Data(header.utf8))) { error in
            XCTAssertEqual(error as? PasswordImportError, .noRows)
        }
    }

    func testUnterminatedQuoteNamesTheRowItStartsIn() {
        let csv = header + "Good,,,,,\n\"Broken,,,,,\n"

        XCTAssertThrowsError(try ApplePasswordsCSVImporter.preview(from: Data(csv.utf8))) { error in
            XCTAssertEqual(error as? PasswordImportError, .unterminatedQuotedField(row: 3))
        }
    }

    func testNonUTF8FileIsRejected() {
        XCTAssertThrowsError(try ApplePasswordsCSVImporter.preview(from: Data([0x54, 0xFF, 0xFE, 0x00]))) { error in
            XCTAssertEqual(error as? PasswordImportError, .notUTF8Text)
        }
    }

    func testOversizedFileIsRejectedBeforeParsing() {
        let data = Data(count: PasswordImport.maximumFileSize + 1)

        XCTAssertThrowsError(try ApplePasswordsCSVImporter.preview(from: data)) { error in
            XCTAssertEqual(error as? PasswordImportError, .fileTooLarge)
        }
    }

    func testLikelyDuplicatesMatchWebsiteAndUserNameAgainstTheDatabaseAndEarlierRows() throws {
        let csv = header
            + "Anything,HTTPS://Example.com/login ,me,new-password,,\n"
            + "Other,https://example.com/login,someone-else,pw,,\n"
            + "Fresh,https://fresh.example,me,pw,,\n"
            + "Fresh again,https://fresh.example,me,pw,,\n"
            + "No Site,,me,pw,,\n"
            + "No Site Twin,,me,pw,,\n"
        let preview = try ApplePasswordsCSVImporter.preview(from: Data(csv.utf8))

        let duplicates = preview.likelyDuplicateRows(existing: [
            .init(title: "Stored", username: "me", url: "https://example.com/login"),
            .init(title: "No Site", username: "me", url: ""),
        ])

        XCTAssertEqual(duplicates, [2, 5, 6])
    }
}

@MainActor
final class PasswordImportViewModelTests: XCTestCase {
    private final class ImportRecorder {
        var calls: [(drafts: [EntryDraftPayload], groupID: UUID)] = []
        var outcome: DatabaseViewModel.PasswordImportOutcome = .saved
        var error: Error?
    }

    private let groupID = UUID()
    private let fileURL = URL(fileURLWithPath: "/tmp/Passwords.csv")

    private func preview(_ csv: String) throws -> PasswordImportPreview {
        try ApplePasswordsCSVImporter.preview(
            from: Data(("Title,URL,Username,Password,Notes,OTPAuth\n" + csv).utf8)
        )
    }

    private func makeViewModel(
        loaded: PasswordImportPreview? = nil,
        loadError: PasswordImportError? = nil,
        existing: [PasswordImport.LoginIdentity] = [],
        recorder: ImportRecorder = ImportRecorder()
    ) -> PasswordImportViewModel {
        PasswordImportViewModel(
            destinationGroupID: groupID,
            duplicateCandidates: { existing },
            importOperation: { drafts, groupID in
                recorder.calls.append((drafts, groupID))
                if let error = recorder.error {
                    throw error
                }
                return recorder.outcome
            },
            fileLoader: { _ in
                if let loadError {
                    throw loadError
                }
                return try XCTUnwrap(loaded)
            }
        )
    }

    func testLoadingAFileShowsItsPreviewAndSkipsLikelyDuplicatesByDefault() async throws {
        let viewModel = makeViewModel(
            loaded: try preview("A,https://a.example,me,pw,,\nB,https://b.example,me,pw,,\n,,,,,\n"),
            existing: [.init(title: "Stored", username: "me", url: "https://a.example")]
        )

        await viewModel.loadFile(at: fileURL)

        XCTAssertEqual(viewModel.fileName, "Passwords.csv")
        XCTAssertEqual(viewModel.likelyDuplicateRows, [2])
        XCTAssertTrue(viewModel.skipsLikelyDuplicates)
        XCTAssertEqual(viewModel.itemsToImport.map(\.draft.title), ["B"])
        XCTAssertTrue(viewModel.canImport)

        viewModel.skipsLikelyDuplicates = false
        XCTAssertEqual(viewModel.itemsToImport.map(\.draft.title), ["A", "B"])
    }

    func testImportAddsTheChosenRowsToTheChosenGroupAndReportsCounts() async throws {
        let recorder = ImportRecorder()
        let viewModel = makeViewModel(
            loaded: try preview("A,https://a.example,me,pw,,\nB,https://b.example,me,pw-b,,\nShort,x\n"),
            existing: [.init(title: "Stored", username: "me", url: "https://a.example")],
            recorder: recorder
        )
        let otherGroup = UUID()
        await viewModel.loadFile(at: fileURL)
        viewModel.destinationGroupID = otherGroup

        await viewModel.performImport()

        XCTAssertEqual(recorder.calls.count, 1)
        XCTAssertEqual(recorder.calls.first?.groupID, otherGroup)
        XCTAssertEqual(recorder.calls.first?.drafts.map(\.title), ["B"])
        XCTAssertEqual(recorder.calls.first?.drafts.first?.password, "pw-b")
        XCTAssertEqual(
            viewModel.summary,
            .init(importedCount: 1, skippedCount: 2, outcome: .saved)
        )
        XCTAssertNil(viewModel.preview, "plaintext rows are dropped once the import is done")
        XCTAssertFalse(viewModel.canImport)
    }

    func testConflictOutcomeIsReportedAsNotYetSaved() async throws {
        let recorder = ImportRecorder()
        recorder.outcome = .awaitingConflictResolution
        let viewModel = makeViewModel(loaded: try preview("A,,me,pw,,\n"), recorder: recorder)
        await viewModel.loadFile(at: fileURL)

        await viewModel.performImport()

        XCTAssertEqual(viewModel.summary?.outcome, .awaitingConflictResolution)
    }

    /// The entries are already staged when the write fails, so the import
    /// must finish rather than invite a second tap that stages them again.
    func testFailedSaveFinishesTheImportInsteadOfOfferingARetry() async throws {
        let recorder = ImportRecorder()
        recorder.outcome = .saveFailed(message: "Disk full.")
        let viewModel = makeViewModel(loaded: try preview("A,,me,pw,,\n"), recorder: recorder)
        await viewModel.loadFile(at: fileURL)

        await viewModel.performImport()

        XCTAssertEqual(viewModel.summary?.outcome, .saveFailed(message: "Disk full."))
        XCTAssertFalse(viewModel.canImport)
        await viewModel.performImport()
        XCTAssertEqual(recorder.calls.count, 1)
    }

    func testFailedImportKeepsThePreviewAndShowsTheError() async throws {
        let recorder = ImportRecorder()
        recorder.error = DatabaseViewModel.PasswordImportFailure.destinationUnavailable
        let viewModel = makeViewModel(loaded: try preview("A,,me,pw,,\n"), recorder: recorder)
        await viewModel.loadFile(at: fileURL)

        await viewModel.performImport()

        XCTAssertNil(viewModel.summary)
        XCTAssertNotNil(viewModel.preview)
        XCTAssertEqual(viewModel.errorMessage, String(localized: "The selected group no longer exists. Choose another group."))
        XCTAssertTrue(viewModel.canImport, "the user can pick another group and retry")
    }

    func testUnreadableFileShowsTheErrorAndNoPreview() async {
        let viewModel = makeViewModel(loadError: PasswordImportError.unrecognizedFormat)

        await viewModel.loadFile(at: fileURL)

        XCTAssertNil(viewModel.preview)
        XCTAssertEqual(viewModel.errorMessage, PasswordImportError.unrecognizedFormat.localizedDescription)
        XCTAssertFalse(viewModel.canImport)
        XCTAssertFalse(viewModel.isLoading)
    }

    func testNothingToImportCannotBeConfirmed() async throws {
        let recorder = ImportRecorder()
        let viewModel = makeViewModel(loaded: try preview(",,,,,\n"), recorder: recorder)
        await viewModel.loadFile(at: fileURL)

        XCTAssertFalse(viewModel.canImport)
        await viewModel.performImport()
        XCTAssertTrue(recorder.calls.isEmpty)
    }

    /// Locking or leaving the screen mid-read must not let the file's
    /// contents land afterwards.
    func testDiscardingDuringALoadDropsItsResult() async throws {
        let loaded = try preview("A,,me,pw,,\n")
        let gate = AsyncStream<Void>.makeStream()
        let viewModel = PasswordImportViewModel(
            destinationGroupID: groupID,
            duplicateCandidates: { [] },
            importOperation: { _, _ in .saved },
            fileLoader: { _ in
                for await _ in gate.stream { break }
                return loaded
            }
        )

        let load = Task { await viewModel.loadFile(at: fileURL) }
        while viewModel.isLoading == false {
            await Task.yield()
        }
        viewModel.discardPreview()
        gate.continuation.yield()
        await load.value

        XCTAssertNil(viewModel.preview)
        XCTAssertNil(viewModel.fileName)
        XCTAssertFalse(viewModel.isLoading)
    }
}
