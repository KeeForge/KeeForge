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
                PasskeyCredential.relyingPartyKey: "example.com",
                PasskeyCredential.usernameKey: "alice@example.com",
                PasskeyCredential.userHandleKey: "user-handle",
            ],
            passkeyPrivateKey: try EncryptedValue.encrypt("private-key", using: sessionKey)
        )

        let viewModel = EntryEditViewModel(editing: entry, sessionKey: sessionKey)
        viewModel.title = "Updated"

        let payload = viewModel.entryDraftPayload

        XCTAssertEqual(payload.title, "Updated")
        XCTAssertEqual(payload.customFields["Environment"], "Production")
        XCTAssertEqual(payload.customFields[PasskeyCredential.credentialIDKey], "credential-id")
        XCTAssertEqual(payload.customFields[PasskeyCredential.usernameKey], "alice@example.com")
        // The sealed private key never enters the draft payload; DatabaseDraft
        // inherits it from the original entry when applying the edit.
        XCTAssertNil(payload.customFields[PasskeyCredential.privateKeyPEMKey])
        XCTAssertNotNil(viewModel.passkeyCredential)
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
        viewModel.pendingTagText = "personal,  finance\nshared "
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

    func testEntryDraftPayloadSplitsTagsOnEverySeparatorAndDedupesExactMatches() {
        let cases: [(text: String, expected: [String])] = [
            ("a;b", ["a", "b"]),
            ("a, b;c\nd", ["a", "b", "c", "d"]),
            (" ; ,, ", []),
            ("a,a", ["a"]),
            ("Work,work", ["Work", "work"]),
        ]

        for (text, expected) in cases {
            let viewModel = EntryEditViewModel(createIn: UUID())
            viewModel.pendingTagText = text

            XCTAssertEqual(
                viewModel.entryDraftPayload.tags,
                expected,
                "Unexpected normalization of tag text \(text.debugDescription)"
            )
        }
    }

    func testEditingEntrySeedsTagTextThatRoundTripsStoredTags() {
        // Case variants sit either side of the ", " join and interior spaces are
        // legal tag content; seeding then normalizing must lose neither.
        let entry = KPEntry(title: "Tagged", tags: ["Work", "work", "New York"], hasTagsElement: true)

        let viewModel = EntryEditViewModel(editing: entry, sessionKey: sessionKey)

        XCTAssertEqual(viewModel.tags, ["Work", "work", "New York"])
        XCTAssertEqual(viewModel.entryDraftPayload.tags, entry.tags)
        XCTAssertFalse(viewModel.isDirty, "Seeding the form is not a user edit")
    }

    // MARK: - Tag suggestions

    func testTagSuggestionsDropAppliedTagsAndRestoreThemWhenTheTagGoesAway() {
        let viewModel = EntryEditViewModel(createIn: UUID(), knownTags: ["finance", "personal", "work"])

        XCTAssertEqual(viewModel.tagSuggestions, ["finance", "personal", "work"])

        // Still being typed, not yet a pill: excluded all the same, or the
        // strip would offer a tag the entry is about to carry.
        viewModel.pendingTagText = "work"
        XCTAssertEqual(viewModel.tagSuggestions, ["finance", "personal"])

        viewModel.commitPendingTag()
        viewModel.pendingTagText = "personal"
        XCTAssertEqual(viewModel.tagSuggestions, ["finance"])

        viewModel.pendingTagText = ""
        XCTAssertEqual(
            viewModel.tagSuggestions,
            ["finance", "personal"],
            "Clearing the field drops only the half-typed token; the committed pill stays applied"
        )
        XCTAssertEqual(viewModel.tags, ["work"])

        viewModel.removeTag("work")
        XCTAssertEqual(
            viewModel.tagSuggestions,
            ["finance", "personal", "work"],
            "Removing the pill puts every suggestion back — exclusions are re-read, never cached"
        )
    }

    func testTagSuggestionsExcludeTagsInheritedFromAncestorGroups() {
        let viewModel = EntryEditViewModel(
            createIn: UUID(),
            knownTags: ["billable", "team", "work"],
            inheritedTags: ["team", "billable"]
        )

        XCTAssertEqual(
            viewModel.tagSuggestions,
            ["work"],
            "A tag the entry already gets from its groups would be a no-op suggestion"
        )
    }

    func testTagSuggestionsKeepCaseVariantsAndTappingInsertsTheExactCasing() {
        let viewModel = EntryEditViewModel(createIn: UUID(), knownTags: ["Work", "work"])
        viewModel.pendingTagText = "work"

        XCTAssertEqual(viewModel.tagSuggestions, ["Work"], "Exact-string identity keeps case variants apart")

        viewModel.appendTagSuggestion("Work")

        XCTAssertEqual(
            viewModel.tags,
            ["work", "Work"],
            "Tapping commits the half-typed token first, so the pills follow the order the user acted"
        )
        XCTAssertEqual(viewModel.entryDraftPayload.tags, ["work", "Work"])
        XCTAssertTrue(viewModel.tagSuggestions.isEmpty)
    }

    func testTappingSuggestionsProducesTheSamePayloadAsTypingThem() {
        let tapped = EntryEditViewModel(createIn: UUID(), knownTags: ["finance", "New York"])
        tapped.pendingTagText = "personal"
        tapped.appendTagSuggestion("finance")
        tapped.appendTagSuggestion("New York")

        let typed = EntryEditViewModel(createIn: UUID())
        typed.pendingTagText = "personal, finance, New York"

        XCTAssertEqual(tapped.entryDraftPayload.tags, typed.entryDraftPayload.tags)
        XCTAssertEqual(tapped.entryDraftPayload.tags, ["personal", "finance", "New York"])

        let fromEmptyField = EntryEditViewModel(createIn: UUID(), knownTags: ["finance"])
        fromEmptyField.appendTagSuggestion("finance")

        XCTAssertEqual(fromEmptyField.tags, ["finance"], "The first tag lands as the first pill")
        XCTAssertTrue(fromEmptyField.pendingTagText.isEmpty)
    }

    func testAppendingATagTheEntryAlreadyCarriesIsANoOp() {
        let viewModel = EntryEditViewModel(createIn: UUID(), knownTags: ["work"])
        viewModel.pendingTagText = " work , personal "

        viewModel.appendTagSuggestion("work")

        XCTAssertEqual(
            viewModel.tags,
            ["work", "personal"],
            "A duplicate tap adds no second pill; the pending token still commits"
        )
        XCTAssertEqual(viewModel.entryDraftPayload.tags, ["work", "personal"])
    }

    func testTagSuggestionsAreEmptyWithoutAPoolOrOnceEveryKnownTagIsApplied() {
        let noTagsInDatabase = EntryEditViewModel(createIn: UUID())
        XCTAssertTrue(noTagsInDatabase.tagSuggestions.isEmpty, "A database with no tags has nothing to offer")

        let everythingApplied = EntryEditViewModel(
            createIn: UUID(),
            knownTags: ["finance", "work"],
            inheritedTags: ["finance"]
        )
        everythingApplied.pendingTagText = "work"

        XCTAssertTrue(
            everythingApplied.tagSuggestions.isEmpty,
            "Typed and inherited tags together can empty the strip, which is when the view renders nothing"
        )
    }

    func testTagSuggestionsNeverOfferATagMissingFromThePool() {
        // The pool comes from the recycled-excluding index, so a tag that
        // survives only in the recycle bin never reaches the editor — and
        // nothing in the editor can resurrect it.
        let entry = KPEntry(title: "Tagged", tags: ["kept"], hasTagsElement: true)
        let viewModel = EntryEditViewModel(
            editing: entry,
            sessionKey: sessionKey,
            knownTags: ["kept", "shared"]
        )

        XCTAssertEqual(viewModel.tagSuggestions, ["shared"])
        XCTAssertFalse(viewModel.tagSuggestions.contains("recycled-only"))
    }

    func testTappingASuggestionMakesTheFormDirty() {
        let entry = KPEntry(title: "Tagged", tags: ["work"], hasTagsElement: true)
        let viewModel = EntryEditViewModel(
            editing: entry,
            sessionKey: sessionKey,
            knownTags: ["finance", "work"]
        )
        XCTAssertFalse(viewModel.isDirty)

        viewModel.appendTagSuggestion("finance")

        XCTAssertTrue(viewModel.isDirty, "Suggestions mutate the applied tags, which is what dirty tracking watches")
        XCTAssertTrue(viewModel.canSave)
    }

    // MARK: - Committing and removing tags

    func testCommittingSplitsTheFieldOnEverySeparator() {
        let viewModel = EntryEditViewModel(createIn: UUID())

        // Typing never commits on its own. Rewriting a focused field's text
        // races the keystrokes still in flight and drops them, so the field is
        // left alone until the user pauses at Return.
        viewModel.pendingTagText = "alpha,beta;gam"
        XCTAssertTrue(viewModel.tags.isEmpty)

        viewModel.commitPendingTag()

        XCTAssertEqual(viewModel.tags, ["alpha", "beta", "gam"], "Return commits the whole field, separators and all")
        XCTAssertEqual(viewModel.pendingTagText, "")
    }

    func testCommittingBlankOrDuplicateTextAddsNoPill() {
        let viewModel = EntryEditViewModel(createIn: UUID())
        viewModel.pendingTagText = "work"
        viewModel.commitPendingTag()

        viewModel.pendingTagText = "   "
        viewModel.commitPendingTag()
        XCTAssertEqual(viewModel.tags, ["work"], "Whitespace is not a tag")

        viewModel.pendingTagText = "work"
        viewModel.commitPendingTag()
        XCTAssertEqual(viewModel.tags, ["work"], "Re-committing a tag the entry carries adds no second pill")
        XCTAssertEqual(viewModel.pendingTagText, "", "The duplicate still leaves the field, so the UI does not stick")
    }

    func testAnUncommittedTokenStillReachesThePayloadAndDirtyTracking() {
        let entry = KPEntry(title: "Tagged", tags: ["work"], hasTagsElement: true)
        let viewModel = EntryEditViewModel(editing: entry, sessionKey: sessionKey)
        XCTAssertFalse(viewModel.isDirty)

        // Saving straight from a half-typed field must not silently drop it.
        viewModel.pendingTagText = "finance"

        XCTAssertTrue(viewModel.isDirty)
        XCTAssertEqual(viewModel.entryDraftPayload.tags, ["work", "finance"])
    }

    func testRemovingAPillDropsItFromThePayloadAndIgnoresUnknownTags() {
        let entry = KPEntry(title: "Tagged", tags: ["work", "finance"], hasTagsElement: true)
        let viewModel = EntryEditViewModel(editing: entry, sessionKey: sessionKey)

        viewModel.removeTag("never-applied")
        XCTAssertEqual(viewModel.tags, ["work", "finance"], "Removing a tag the entry lacks changes nothing")
        XCTAssertFalse(viewModel.isDirty)

        viewModel.removeTag("work")

        XCTAssertEqual(viewModel.tags, ["finance"])
        XCTAssertEqual(viewModel.entryDraftPayload.tags, ["finance"])
        XCTAssertTrue(viewModel.isDirty)
    }

    func testRemovingEveryPillClearsTheEntrysTags() {
        let entry = KPEntry(title: "Tagged", tags: ["work"], hasTagsElement: true)
        let viewModel = EntryEditViewModel(editing: entry, sessionKey: sessionKey)

        viewModel.removeTag("work")

        XCTAssertTrue(viewModel.tags.isEmpty)
        XCTAssertEqual(viewModel.entryDraftPayload.tags, [], "An emptied tag list is a real edit, not a no-op")
        XCTAssertTrue(viewModel.isDirty)
    }

    // MARK: - canSave

    func testCanSaveTruthTableAcrossCreateAndEditModes() throws {
        let createViewModel = EntryEditViewModel(createIn: UUID())
        XCTAssertFalse(createViewModel.canSave, "A fresh create-mode form has nothing to save yet")
        createViewModel.title = "New Entry"
        XCTAssertTrue(createViewModel.canSave, "Any change to a create-mode form makes it saveable")
        createViewModel.title = ""
        XCTAssertFalse(createViewModel.canSave, "Reverting back to the original snapshot makes it unsaveable again")

        let entry = KPEntry(
            title: "Original",
            username: "alice",
            password: try EncryptedValue.encrypt("secret", using: sessionKey)
        )
        let editViewModel = EntryEditViewModel(editing: entry, sessionKey: sessionKey)
        XCTAssertFalse(editViewModel.canSave, "An unmodified edit-mode form has nothing to save")
        editViewModel.username = "bob"
        XCTAssertTrue(editViewModel.canSave, "Any change to an edit-mode form makes it saveable")
    }

    // MARK: - Custom fields

    func testAddCustomFieldAppendsABlankFieldAndRemoveCustomFieldDeletesByID() {
        let viewModel = EntryEditViewModel(createIn: UUID())
        XCTAssertTrue(viewModel.customFields.isEmpty)

        viewModel.addCustomField()
        XCTAssertEqual(viewModel.customFields.count, 1)
        let firstAdded = try! XCTUnwrap(viewModel.customFields.first)
        XCTAssertEqual(firstAdded.key, "")
        XCTAssertEqual(firstAdded.value, "")

        viewModel.addCustomField()
        XCTAssertEqual(viewModel.customFields.count, 2)

        viewModel.removeCustomField(id: firstAdded.id)
        XCTAssertEqual(viewModel.customFields.count, 1)
        XCTAssertFalse(viewModel.customFields.contains(where: { $0.id == firstAdded.id }))
    }

    func testRemoveCustomFieldWithUnknownIDIsANoOp() {
        let viewModel = EntryEditViewModel(createIn: UUID())
        viewModel.addCustomField()
        XCTAssertEqual(viewModel.customFields.count, 1)

        viewModel.removeCustomField(id: UUID())

        XCTAssertEqual(viewModel.customFields.count, 1)
    }

    // MARK: - customFieldAccessibilityIdentifier

    func testCustomFieldAccessibilityIdentifierNormalizesKeyOrFallsBackToIndex() {
        let viewModel = EntryEditViewModel(createIn: UUID())
        let namedField = EntryEditViewModel.CustomField(key: " Support PIN/Code ", value: "1234")
        let blankField = EntryEditViewModel.CustomField(key: "   ", value: "ignored")

        XCTAssertEqual(
            viewModel.customFieldAccessibilityIdentifier(for: namedField, fallbackIndex: 3),
            "entry-edit.custom-field.row.support-pin-code",
            "The key is trimmed, lowercased, and has spaces/slashes normalized to hyphens"
        )
        XCTAssertEqual(
            viewModel.customFieldAccessibilityIdentifier(for: blankField, fallbackIndex: 3),
            "entry-edit.custom-field.row.3",
            "A whitespace-only key falls back to the positional index"
        )
    }

    // MARK: - TOTP secret canonicalization (base32Encode / canonicalBase32Secret)
    //
    // Both helpers are `private static` on EntryEditViewModel, so they are
    // exercised only indirectly through `entryDraftPayload`'s TOTP
    // normalization, using entries that carry a legacy `keeOTPSource` (the
    // only branch that calls canonicalBase32Secret at all) and TOTPGenerator's
    // public base32Decode as an independent ground truth for the round trip.

    func testTOTPSecretUpdateWithValidBase32AndKeeOTPSourceRewritesTheLegacyQueryCanonically() throws {
        let keeOTPSource = KeeOTPSource(fieldName: "otp", rawQuery: "key=GEZDGNBVGY3TQOJQ&step=30&size=6")
        let entry = KPEntry(
            title: "Legacy TOTP",
            totpConfig: TOTPConfig(
                secret: try EncryptedValue.encrypt("GEZDGNBVGY3TQOJQ", using: sessionKey),
                keeOTPSource: keeOTPSource,
                period: 30,
                digits: 6,
                algorithm: .sha1
            )
        )
        let viewModel = EntryEditViewModel(editing: entry, sessionKey: sessionKey)
        // Lowercase, RFC 4648-valid input; canonicalBase32Secret uppercases it
        // before round-tripping through TOTPGenerator.base32Decode/base32Encode.
        viewModel.totpSecret = "jbswy3dpehpk3pxp"

        let payload = viewModel.entryDraftPayload

        // The plain `secret` field preserves exactly what the user typed...
        XCTAssertEqual(payload.totpConfig?.secret, "jbswy3dpehpk3pxp")
        // ...while the rewritten legacy otp query embeds the canonical
        // uppercase form. Both decode to the same bytes via the public
        // decoder either way, since TOTPGenerator.base32Decode is
        // case-insensitive, so this asymmetry is cosmetic, not functional.
        let rewrittenQuery = try XCTUnwrap(payload.totpConfig?.keeOTPSource?.rawQuery)
        XCTAssertTrue(rewrittenQuery.contains("key=JBSWY3DPEHPK3PXP"))
        XCTAssertEqual(
            TOTPGenerator.base32Decode("jbswy3dpehpk3pxp"),
            TOTPGenerator.base32Decode("JBSWY3DPEHPK3PXP"),
            "Sanity check: the two secret representations must decode identically"
        )
    }

    func testTOTPSecretUpdateWithInvalidCharactersAndKeeOTPSourceRevertsEntirelyToTheOriginalSnapshot() throws {
        let keeOTPSource = KeeOTPSource(fieldName: "otp", rawQuery: "key=GEZDGNBVGY3TQOJQ&step=30&size=6")
        let entry = KPEntry(
            title: "Legacy TOTP",
            totpConfig: TOTPConfig(
                secret: try EncryptedValue.encrypt("GEZDGNBVGY3TQOJQ", using: sessionKey),
                keeOTPSource: keeOTPSource,
                period: 30,
                digits: 6,
                algorithm: .sha1
            )
        )
        let viewModel = EntryEditViewModel(editing: entry, sessionKey: sessionKey)
        // '1' is not a valid base32 character (only 2-7 and A-Z), so
        // canonicalBase32Secret must reject this outright.
        viewModel.totpSecret = "1NVALID1"
        // Also attempt a settings change alongside the bad secret; the revert
        // branch must discard both, not just the secret.
        viewModel.totpPeriod = 60

        let payload = viewModel.entryDraftPayload

        XCTAssertEqual(payload.totpConfig?.secret, "GEZDGNBVGY3TQOJQ")
        XCTAssertEqual(payload.totpConfig?.period, 30)
        XCTAssertEqual(payload.totpConfig?.keeOTPSource, keeOTPSource)
    }

    func testTOTPSecretUpdateWithRFC4648PaddingAndKeeOTPSourceIsRejectedAsNonCanonical() throws {
        let keeOTPSource = KeeOTPSource(fieldName: "otp", rawQuery: "key=GEZDGNBVGY3TQOJQ&step=30&size=6")
        let entry = KPEntry(
            title: "Legacy TOTP",
            totpConfig: TOTPConfig(
                secret: try EncryptedValue.encrypt("GEZDGNBVGY3TQOJQ", using: sessionKey),
                keeOTPSource: keeOTPSource,
                period: 30,
                digits: 6,
                algorithm: .sha1
            )
        )
        let viewModel = EntryEditViewModel(editing: entry, sessionKey: sessionKey)
        // "MFRGG===" is a textbook RFC 4648 padded encoding, and differs from
        // the original secret so this counts as a real change. TOTPGenerator's
        // decoder tolerates '=' (it just skips it), but canonicalBase32Secret
        // requires every character to be in the unpadded A-Z/2-7 alphabet, so
        // this must fail the character-range check and trigger the same
        // whole-snapshot revert as any other invalid secret.
        viewModel.totpSecret = "MFRGG==="

        let payload = viewModel.entryDraftPayload

        XCTAssertEqual(payload.totpConfig?.secret, "GEZDGNBVGY3TQOJQ")
        XCTAssertEqual(payload.totpConfig?.keeOTPSource, keeOTPSource)
    }
}
