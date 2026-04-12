import CryptoKit
import XCTest
@testable import KeeForge

@MainActor
final class EntryEditViewModelTests: XCTestCase {
    private let sessionKey = SymmetricKey(size: .bits256)

    func testEditingEntryPayloadPreservesReadOnlyPasskeyFields() throws {
        let entry = KPEntry(
            title: "Original",
            username: "alice",
            password: try EncryptedValue.encrypt("secret", using: sessionKey),
            url: "https://example.com",
            customFields: [
                "Environment": "Production",
                PasskeyCredential.credentialIDKey: "credential-id",
                PasskeyCredential.privateKeyPEMKey: "private-key",
                PasskeyCredential.relyingPartyKey: "example.com",
                PasskeyCredential.usernameKey: "alice@example.com",
                PasskeyCredential.userHandleKey: "user-handle",
            ]
        )

        let viewModel = EntryEditViewModel(editing: entry, sessionKey: sessionKey)
        viewModel.title = "Updated"

        let payload = viewModel.entryDraftPayload

        XCTAssertEqual(payload.title, "Updated")
        XCTAssertEqual(payload.customFields["Environment"], "Production")
        XCTAssertEqual(payload.customFields[PasskeyCredential.credentialIDKey], "credential-id")
        XCTAssertEqual(payload.customFields[PasskeyCredential.usernameKey], "alice@example.com")
    }

    func testEditingEntryDecryptsExistingPasswordIntoFormState() throws {
        let entry = KPEntry(
            title: "Original",
            username: "alice",
            password: try EncryptedValue.encrypt("existing-secret", using: sessionKey)
        )

        let viewModel = EntryEditViewModel(editing: entry, sessionKey: sessionKey)

        XCTAssertEqual(viewModel.password, "existing-secret")
    }

    func testIsDirtyTracksFormChanges() {
        let viewModel = EntryEditViewModel(createIn: UUID())

        XCTAssertFalse(viewModel.isDirty)

        viewModel.title = "Created"

        XCTAssertTrue(viewModel.isDirty)
    }

    func testEntryDraftPayloadNormalizesTagsCustomFieldsAndTotp() {
        let viewModel = EntryEditViewModel(createIn: UUID())
        viewModel.tagsText = "personal,  finance\nshared "
        viewModel.customFields = [
            .init(key: "Support PIN", value: "1234"),
            .init(key: " ", value: "ignored"),
        ]
        viewModel.totpSecret = "JBSWY3DPEHPK3PXP"
        viewModel.totpPeriod = 45
        viewModel.totpDigits = 8
        viewModel.totpAlgorithm = .sha256

        let payload = viewModel.entryDraftPayload

        XCTAssertEqual(payload.tags, ["personal", "finance", "shared"])
        XCTAssertEqual(payload.customFields, ["Support PIN": "1234"])
        XCTAssertEqual(
            payload.totpConfig,
            .init(secret: "JBSWY3DPEHPK3PXP", period: 45, digits: 8, algorithm: .sha256)
        )
    }
}
