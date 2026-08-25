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

    func testStoredPasswordStartsConcealedAndRequiresAuthenticationToReveal() throws {
        let entry = KPEntry(
            title: "Existing",
            password: try EncryptedValue.encrypt("stored-secret", using: sessionKey)
        )

        let viewModel = EntryEditViewModel(editing: entry, sessionKey: sessionKey)

        XCTAssertFalse(viewModel.isPasswordInitiallyVisible)
        XCTAssertTrue(viewModel.requiresAuthenticationToRevealPassword)
    }

    func testNewPasswordStartsVisibleWithoutRevealAuthentication() {
        let viewModel = EntryEditViewModel(createIn: UUID())

        XCTAssertTrue(viewModel.isPasswordInitiallyVisible)
        XCTAssertFalse(viewModel.requiresAuthenticationToRevealPassword)
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
    // The helpers live on TOTPGenerator, but the KeeOTP revert-vs-rewrite
    // policy is this view model's, so it is exercised through
    // `entryDraftPayload`'s TOTP normalization, using entries that carry a
    // legacy `keeOTPSource` and TOTPGenerator's public base32Decode as an
    // independent ground truth for the round trip.

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

    func testTOTPDigitsOutsideKeeOTPWhitelistRevertsEntirelyToTheOriginalSnapshot() throws {
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
        // The KeeOTP parser only accepts size ∈ {6, 8}; writing size=7 would
        // make the config unreadable on reload, so the whole edit reverts —
        // timing changes included — exactly like a non-canonical secret.
        viewModel.totpDigits = 7
        viewModel.totpPeriod = 60

        let payload = viewModel.entryDraftPayload

        XCTAssertEqual(
            payload.totpConfig,
            EntryDraftPayload.TOTPConfiguration(
                secret: "GEZDGNBVGY3TQOJQ",
                keeOTPSource: keeOTPSource,
                period: 30,
                digits: 6,
                algorithm: .sha1
            )
        )
    }

    // MARK: - otpauth:// enrollment

    func testApplyOTPAuthURISetsFieldsAndPayloadCarriesURIVerbatim() throws {
        let raw = "otpauth://totp/Example:alice@example.com?secret=mfrgg%3D%3D%3D&issuer=Example&period=45&digits=8&algorithm=SHA256"
        let uri = try OTPAuthURI(string: raw)
        let viewModel = EntryEditViewModel(createIn: UUID())

        viewModel.applyOTPAuthURI(uri)

        XCTAssertEqual(viewModel.totpSecret, "MFRGG")
        XCTAssertEqual(viewModel.totpPeriod, 45)
        XCTAssertEqual(viewModel.totpDigits, 8)
        XCTAssertEqual(viewModel.totpAlgorithm, .sha256)
        XCTAssertTrue(viewModel.isDirty)

        let payload = viewModel.entryDraftPayload
        XCTAssertEqual(payload.totpConfig?.otpauthURI, raw)
        XCTAssertEqual(payload.totpConfig?.secret, "MFRGG")
        XCTAssertEqual(payload.totpConfig?.period, 45)
        XCTAssertEqual(payload.totpConfig?.digits, 8)
        XCTAssertEqual(payload.totpConfig?.algorithm, .sha256)
        XCTAssertNil(payload.totpConfig?.keeOTPSource)
    }

    func testEditingPeriodAfterApplyDropsOTPAuthURIButKeepsEditedValues() throws {
        let uri = try OTPAuthURI(string: "otpauth://totp/Example:x?secret=JBSWY3DPEHPK3PXP&period=30")
        let viewModel = EntryEditViewModel(createIn: UUID())
        viewModel.applyOTPAuthURI(uri)
        viewModel.totpPeriod = 60

        let payload = viewModel.entryDraftPayload

        XCTAssertNil(payload.totpConfig?.otpauthURI)
        XCTAssertEqual(payload.totpConfig?.secret, "JBSWY3DPEHPK3PXP")
        XCTAssertEqual(payload.totpConfig?.period, 60)
    }

    func testEditingSecretAfterApplyDropsOTPAuthURIButKeepsEditedSecret() throws {
        let uri = try OTPAuthURI(string: "otpauth://totp/Example:x?secret=JBSWY3DPEHPK3PXP")
        let viewModel = EntryEditViewModel(createIn: UUID())
        viewModel.applyOTPAuthURI(uri)
        viewModel.totpSecret = "GEZDGNBVGY3TQOJQ"

        let payload = viewModel.entryDraftPayload

        XCTAssertNil(payload.totpConfig?.otpauthURI)
        XCTAssertEqual(payload.totpConfig?.secret, "GEZDGNBVGY3TQOJQ")
    }

    func testApplyOTPAuthURIOnKeeOTPEntryRewritesTheQueryAndOmitsTheURI() throws {
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
        let uri = try OTPAuthURI(string: "otpauth://totp/Example:x?secret=JBSWY3DPEHPK3PXP&period=45")

        viewModel.applyOTPAuthURI(uri)

        let payload = viewModel.entryDraftPayload
        XCTAssertNil(payload.totpConfig?.otpauthURI)
        let rewrittenQuery = try XCTUnwrap(payload.totpConfig?.keeOTPSource?.rawQuery)
        XCTAssertTrue(rewrittenQuery.contains("key=JBSWY3DPEHPK3PXP"))
        XCTAssertTrue(rewrittenQuery.contains("step=45"))
    }

    func testRemoveTOTPYieldsNilConfigAndResetsTheForm() throws {
        let uri = try OTPAuthURI(string: "otpauth://totp/Example:x?secret=JBSWY3DPEHPK3PXP&period=45&digits=8&algorithm=SHA256")
        let viewModel = EntryEditViewModel(createIn: UUID())
        viewModel.applyOTPAuthURI(uri)

        viewModel.removeTOTP()

        XCTAssertNil(viewModel.entryDraftPayload.totpConfig)
        XCTAssertEqual(viewModel.totpSecret, "")
        XCTAssertEqual(viewModel.totpPeriod, 30)
        XCTAssertEqual(viewModel.totpDigits, 6)
        XCTAssertEqual(viewModel.totpAlgorithm, .sha1)
    }

    func testManualSecretEntryProducesPayloadWithoutOTPAuthURI() {
        let viewModel = EntryEditViewModel(createIn: UUID())
        viewModel.totpSecret = "JBSWY3DPEHPK3PXP"

        XCTAssertNil(viewModel.entryDraftPayload.totpConfig?.otpauthURI)
    }

    func testApplySetupLinkAppliesParsedConfigurationAndReturnsNil() {
        let viewModel = EntryEditViewModel(createIn: UUID())

        let error = viewModel.applySetupLink(
            "otpauth://totp/Example:x?secret=JBSWY3DPEHPK3PXP&period=45&digits=8&algorithm=SHA256"
        )

        XCTAssertNil(error)
        XCTAssertEqual(viewModel.totpSecret, "JBSWY3DPEHPK3PXP")
        XCTAssertEqual(viewModel.totpPeriod, 45)
        XCTAssertEqual(viewModel.totpDigits, 8)
        XCTAssertEqual(viewModel.totpAlgorithm, .sha256)
    }

    func testApplySetupLinkReturnsUnsupportedTypeForCounterBasedLinks() {
        let viewModel = EntryEditViewModel(createIn: UUID())

        let error = viewModel.applySetupLink("otpauth://hotp/Example:x?secret=JBSWY3DPEHPK3PXP")

        XCTAssertEqual(error, .unsupportedType)
        XCTAssertEqual(viewModel.totpSecret, "")
        XCTAssertFalse(viewModel.isDirty)
    }

    func testApplySetupLinkLeavesFormUntouchedOnInvalidLink() {
        let viewModel = EntryEditViewModel(createIn: UUID())
        viewModel.totpSecret = "JBSWY3DPEHPK3PXP"
        viewModel.totpPeriod = 45

        let error = viewModel.applySetupLink("https://example.com/not-otpauth")

        XCTAssertEqual(error, .notAnOTPAuthURI)
        XCTAssertEqual(viewModel.totpSecret, "JBSWY3DPEHPK3PXP")
        XCTAssertEqual(viewModel.totpPeriod, 45)
    }
    // MARK: - Duplicating an entry

    func testDuplicatingEntryCopiesTheEditableFieldsAndMarksTheTitleAsACopy() throws {
        let entry = KPEntry(
            title: "Bank",
            username: "alice",
            password: try EncryptedValue.encrypt("secret", using: sessionKey),
            url: "https://example.com",
            notes: "recovery codes in the safe",
            tags: ["work"],
            hasTagsElement: true,
            customFields: ["Environment": "Production"],
            totpConfig: TOTPConfig(
                secret: try EncryptedValue.encrypt("JBSWY3DPEHPK3PXP", using: sessionKey),
                period: 45,
                digits: 8,
                algorithm: .sha256
            )
        )
        let parentGroupID = UUID()

        let viewModel = EntryEditViewModel(
            duplicating: entry,
            sessionKey: sessionKey,
            into: parentGroupID
        )

        XCTAssertEqual(viewModel.mode, .create(parentGroupID: parentGroupID))
        // Asserted by shape rather than by string: the suffix is localized.
        XCTAssertTrue(viewModel.title.hasPrefix("Bank"))
        XCTAssertNotEqual(viewModel.title, "Bank")

        let payload = viewModel.entryDraftPayload
        XCTAssertEqual(payload.username, "alice")
        XCTAssertEqual(payload.password, "secret")
        XCTAssertEqual(payload.url, "https://example.com")
        XCTAssertEqual(payload.notes, "recovery codes in the safe")
        XCTAssertEqual(payload.tags, ["work"])
        XCTAssertEqual(payload.customFields["Environment"], "Production")
        XCTAssertEqual(payload.totpConfig?.secret, "JBSWY3DPEHPK3PXP")
        XCTAssertEqual(payload.totpConfig?.period, 45)
        XCTAssertEqual(payload.totpConfig?.digits, 8)
        XCTAssertEqual(payload.totpConfig?.algorithm, .sha256)
    }

    func testDuplicatingEntryKeepsProtectedCustomFieldsProtected() {
        let entry = KPEntry(
            title: "Bank",
            customFields: ["Recovery Code": "12345", "Environment": "Production"],
            protectedStringKeys: ["Recovery Code"]
        )

        let viewModel = EntryEditViewModel(
            duplicating: entry,
            sessionKey: sessionKey,
            into: UUID()
        )

        // The copy is a new entry, so nothing downstream can inherit the
        // original's protection flags — the form has to ask for them.
        XCTAssertEqual(viewModel.entryDraftPayload.protectedCustomFieldKeys, ["Recovery Code"])
    }

    func testDuplicatingEntryWithAnEmptyTitleLeavesItEmpty() {
        let viewModel = EntryEditViewModel(
            duplicating: KPEntry(username: "alice"),
            sessionKey: sessionKey,
            into: UUID()
        )

        XCTAssertEqual(viewModel.title, "")
    }

    func testDuplicatingEntryLeavesThePasskeyAndUnknownXMLWithTheOriginal() throws {
        let entry = KPEntry(
            title: "Passkey",
            customFields: [
                "Environment": "Production",
                PasskeyCredential.credentialIDKey: "credential-id",
                PasskeyCredential.relyingPartyKey: "example.com",
                PasskeyCredential.usernameKey: "alice@example.com",
                PasskeyCredential.userHandleKey: "user-handle",
            ],
            passkeyPrivateKey: try EncryptedValue.encrypt("private-key", using: sessionKey),
            unknownXML: OpaqueXMLNodes(nodes: [.init(insertionIndex: 0, xml: "<Custom/>")])
        )

        let viewModel = EntryEditViewModel(
            duplicating: entry,
            sessionKey: sessionKey,
            into: UUID()
        )

        XCTAssertNil(viewModel.passkeyCredential)
        XCTAssertEqual(viewModel.unknownXMLNodeCount, 0)

        let payload = viewModel.entryDraftPayload
        XCTAssertEqual(payload.customFields["Environment"], "Production")
        for key in PasskeyCredential.allFieldKeys {
            XCTAssertNil(payload.customFields[key])
        }
    }

    func testDuplicateIsSavableUntouchedAndKeepsTheCopiedPasswordProtected() throws {
        let entry = KPEntry(
            title: "Bank",
            password: try EncryptedValue.encrypt("secret", using: sessionKey)
        )

        let viewModel = EntryEditViewModel(
            duplicating: entry,
            sessionKey: sessionKey,
            into: UUID()
        )

        XCTAssertTrue(viewModel.isDirty)
        XCTAssertTrue(viewModel.canSave)
        XCTAssertFalse(viewModel.isPasswordInitiallyVisible)
        XCTAssertTrue(viewModel.requiresAuthenticationToRevealPassword)
    }

    func testNewEntryFormStillOpensEmptyUnsavableAndWithItsPasswordVisible() {
        let viewModel = EntryEditViewModel(createIn: UUID())

        XCTAssertFalse(viewModel.canSave)
        XCTAssertTrue(viewModel.isPasswordInitiallyVisible)
        XCTAssertFalse(viewModel.requiresAuthenticationToRevealPassword)
    }

    // MARK: - The create form's destination group

    func testSetCreateDestinationRetargetsTheFormAndRefreshesInheritedTagSuggestions() {
        let origin = UUID()
        let destination = UUID()
        let viewModel = EntryEditViewModel(
            createIn: origin,
            knownTags: ["home", "work"],
            inheritedTags: ["work"]
        )

        XCTAssertEqual(viewModel.createDestinationGroupID, origin)
        XCTAssertEqual(viewModel.tagSuggestions, ["home"])

        viewModel.setCreateDestination(to: destination, inheritedTags: ["home"])

        XCTAssertEqual(viewModel.createDestinationGroupID, destination)
        XCTAssertEqual(viewModel.mode, .create(parentGroupID: destination))
        XCTAssertEqual(viewModel.tagSuggestions, ["work"])
    }

    func testSetCreateDestinationIsIgnoredWhileEditingAnEntry() {
        let entry = KPEntry(title: "Bank")
        let viewModel = EntryEditViewModel(editing: entry, sessionKey: sessionKey)

        viewModel.setCreateDestination(to: UUID(), inheritedTags: [])

        XCTAssertNil(viewModel.createDestinationGroupID)
        XCTAssertEqual(viewModel.mode, .edit(entryID: entry.id))
    }
}
