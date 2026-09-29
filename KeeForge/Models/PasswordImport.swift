import Foundation

/// A password export file read into entries, before anything touches the
/// database. Holds plaintext passwords: keep it only as long as the import
/// screen is open.
struct PasswordImportPreview: Sendable {
    struct Item: Sendable, Equatable {
        /// 1-based, counting the header as row 1 — what a spreadsheet shows.
        let row: Int
        let draft: EntryDraftPayload
        /// The verification-code link was not a TOTP link KeeForge can
        /// generate codes for, so it is kept as the protected
        /// `PasswordImport.unsupportedOTPFieldName` field instead.
        let keepsUnsupportedVerificationCode: Bool
    }

    struct SkippedRow: Sendable, Equatable {
        let row: Int
        let reason: SkipReason
    }

    enum SkipReason: Sendable, Equatable {
        case columnCountMismatch
        case malformedQuoting
        case noLoginData
    }

    let items: [Item]
    let skippedRows: [SkippedRow]

    var verificationCodeCount: Int {
        items.count(where: { $0.draft.totpConfig != nil })
    }

    var unsupportedVerificationCodeCount: Int {
        items.count(where: { $0.keepsUnsupportedVerificationCode })
    }

    /// Rows that look like a login the database already holds, or one an
    /// earlier row of the same file already adds.
    func likelyDuplicateRows(existing: [PasswordImport.LoginIdentity]) -> Set<Int> {
        var seen = Set(existing.map(PasswordImport.DuplicateKey.init))
        var duplicates: Set<Int> = []
        for item in items {
            let key = PasswordImport.DuplicateKey(PasswordImport.LoginIdentity(item.draft))
            if seen.insert(key).inserted == false {
                duplicates.insert(item.row)
            }
        }
        return duplicates
    }
}

enum PasswordImportError: Error, Equatable, LocalizedError {
    case fileTooLarge
    case notUTF8Text
    case unrecognizedFormat
    case unterminatedQuotedField(row: Int)
    case noRows

    var errorDescription: String? {
        switch self {
        case .fileTooLarge:
            String(localized: "This file is too large to be a password export.")
        case .notUTF8Text:
            String(localized: "This file is not a text file KeeForge can read.")
        case .unrecognizedFormat:
            String(localized: "This file is not an Apple Passwords export. KeeForge can currently import only the CSV file that the Passwords app exports.")
        case .unterminatedQuotedField(let row):
            String(localized: "The file is damaged: a quoted value that starts in row \(row) never ends. Export your passwords again and retry.")
        case .noRows:
            String(localized: "This export file contains no passwords.")
        }
    }
}

enum PasswordImport {
    /// Custom field that keeps an `OTPAuth` value KeeForge cannot turn into
    /// codes, such as an HOTP link, so it is not lost.
    static let unsupportedOTPFieldName = "OTPAuth"

    /// Well above any real export; bounds what a mistaken pick loads into memory.
    static let maximumFileSize = 16 * 1024 * 1024

    struct LoginIdentity: Sendable, Equatable {
        var title: String
        var username: String
        var url: String

        init(title: String, username: String, url: String) {
            self.title = title
            self.username = username
            self.url = url
        }

        init(_ draft: EntryDraftPayload) {
            self.init(title: draft.title, username: draft.username, url: draft.url)
        }
    }

    /// Same website and user name. The title only decides when there is no
    /// website, where the user name alone would match far too much.
    fileprivate struct DuplicateKey: Hashable {
        let url: String
        let username: String
        let title: String?

        init(_ identity: LoginIdentity) {
            let url = Self.normalizedURL(identity.url)
            self.url = url
            username = identity.username.trimmingCharacters(in: .whitespacesAndNewlines)
            title = url.isEmpty ? identity.title.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        }

        /// Only the scheme and host ignore case; the rest of an address can
        /// tell two logins apart (`/Tenant` and `/tenant`).
        static func normalizedURL(_ rawURL: String) -> String {
            let url = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let scheme: String
            let remainder: Substring
            if let separator = url.range(of: "://") {
                scheme = url[..<separator.lowerBound].lowercased() + "://"
                remainder = url[separator.upperBound...]
            } else {
                // A bare `example.com/Path` still starts with its host.
                scheme = ""
                remainder = url[...]
            }

            let authorityEnd = remainder.firstIndex { "/?#".contains($0) } ?? remainder.endIndex
            let authority = remainder[..<authorityEnd]
            let hostStart = authority.lastIndex(of: "@").map(authority.index(after:)) ?? authority.startIndex
            return scheme
                + authority[..<hostStart]
                + authority[hostStart...].lowercased()
                + remainder[authorityEnd...]
        }
    }
}

/// The CSV the Passwords app (and Safari before it) exports:
/// `Title,URL,Username,Password,Notes,OTPAuth`.
enum ApplePasswordsCSVImporter {
    private enum Column: String, CaseIterable {
        case title = "title"
        case url = "url"
        case username = "username"
        case password = "password"
        case notes = "notes"
        case otpAuth = "otpauth"
    }

    /// Older Safari exports lack `Notes`, and `OTPAuth` arrived later still.
    private static let requiredColumns: Set<Column> = [.title, .url, .username, .password]

    static func preview(from data: Data) throws -> PasswordImportPreview {
        guard data.count <= PasswordImport.maximumFileSize else {
            throw PasswordImportError.fileTooLarge
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw PasswordImportError.notUTF8Text
        }

        let records: [CSVReader.Record]
        do {
            records = try CSVReader.records(in: text)
        } catch CSVReader.ReadError.unterminatedQuotedField(let recordIndex) {
            throw PasswordImportError.unterminatedQuotedField(row: recordIndex + 1)
        }

        guard let header = records.first else {
            throw PasswordImportError.unrecognizedFormat
        }
        let columns = try columnIndices(header: header)

        var items: [PasswordImportPreview.Item] = []
        var skippedRows: [PasswordImportPreview.SkippedRow] = []
        for (offset, record) in records.dropFirst().enumerated() {
            let row = offset + 2
            if record.isMalformed {
                skippedRows.append(.init(row: row, reason: .malformedQuoting))
            } else if record.fields.count != header.fields.count {
                skippedRows.append(.init(row: row, reason: .columnCountMismatch))
            } else if let item = item(from: record.fields, row: row, columns: columns) {
                items.append(item)
            } else {
                skippedRows.append(.init(row: row, reason: .noLoginData))
            }
        }

        guard items.isEmpty == false || skippedRows.isEmpty == false else {
            throw PasswordImportError.noRows
        }
        return PasswordImportPreview(items: items, skippedRows: skippedRows)
    }

    /// Every column must be one this importer maps, so no value in the file
    /// is dropped without the user being told.
    private static func columnIndices(header: CSVReader.Record) throws -> [Column: Int] {
        guard header.isMalformed == false else {
            throw PasswordImportError.unrecognizedFormat
        }
        var indices: [Column: Int] = [:]
        for (index, name) in header.fields.enumerated() {
            let normalized = name.trimmingCharacters(in: .whitespaces).lowercased()
            guard let column = Column(rawValue: normalized), indices[column] == nil else {
                throw PasswordImportError.unrecognizedFormat
            }
            indices[column] = index
        }
        guard requiredColumns.isSubset(of: indices.keys) else {
            throw PasswordImportError.unrecognizedFormat
        }
        return indices
    }

    private static func item(
        from fields: [String],
        row: Int,
        columns: [Column: Int]
    ) -> PasswordImportPreview.Item? {
        func value(_ column: Column) -> String {
            columns[column].map { fields[$0] } ?? ""
        }

        let otpAuth = value(.otpAuth).trimmingCharacters(in: .whitespacesAndNewlines)
        var draft = EntryDraftPayload(
            title: value(.title),
            username: value(.username),
            password: value(.password),
            url: value(.url),
            notes: value(.notes)
        )

        let hasLoginData = [draft.title, draft.username, draft.password, draft.url, draft.notes, otpAuth]
            .contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
        guard hasLoginData else { return nil }

        var keepsUnsupportedVerificationCode = false
        if otpAuth.isEmpty == false {
            if let uri = try? OTPAuthURI(string: otpAuth) {
                draft.totpConfig = EntryDraftPayload.TOTPConfiguration(
                    secret: uri.secret,
                    period: uri.period,
                    digits: uri.digits,
                    algorithm: uri.algorithm,
                    otpauthURI: uri.rawURI
                )
            } else {
                draft.customFields[PasswordImport.unsupportedOTPFieldName] = otpAuth
                draft.protectedCustomFieldKeys.insert(PasswordImport.unsupportedOTPFieldName)
                keepsUnsupportedVerificationCode = true
            }
        }

        return PasswordImportPreview.Item(
            row: row,
            draft: draft,
            keepsUnsupportedVerificationCode: keepsUnsupportedVerificationCode
        )
    }
}
