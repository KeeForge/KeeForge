import XCTest
@testable import KeeForge

/// Gates the four `.xcstrings` catalogs against silently shipping untranslated
/// or drifted German strings. Reads the raw JSON catalog sources straight off
/// the checkout (located via `#filePath`, the same way other tests resolve
/// repo-relative fixtures) rather than the compiled catalogs the app bundles,
/// so a new English key with no German translation fails here before it ever
/// reaches a build.
final class LocalizationTests: XCTestCase {

    // MARK: - String catalog decoding

    private struct StringUnit: Decodable {
        let state: String?
        let value: String?
    }

    private struct Localization: Decodable {
        let stringUnit: StringUnit?
    }

    private struct StringEntry: Decodable {
        let localizations: [String: Localization]?
    }

    private struct StringCatalog: Decodable {
        let strings: [String: StringEntry]
    }

    private struct Catalog {
        let name: String
        let strings: [String: StringEntry]
    }

    // MARK: - Catalog locations

    /// `#filePath` resolves at compile time to this source file's absolute
    /// path on disk. Unit tests run in the simulator but the simulator can
    /// still read the host filesystem, so this is enough to walk back up to
    /// the repository root without hardcoding a developer-specific path.
    private static let repositoryRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // KeeForgeTests/
            .deletingLastPathComponent() // repository root
    }()

    private static let catalogRelativePaths: [String] = [
        "KeeForge/Resources/Localizable.xcstrings",
        "KeeForge/Resources/InfoPlist.xcstrings",
        "AutoFillExtension/Localizable.xcstrings",
        "AutoFillExtension/InfoPlist.xcstrings",
    ]

    private func loadCatalogs() throws -> [Catalog] {
        try Self.catalogRelativePaths.map { relativePath in
            let url = Self.repositoryRoot.appendingPathComponent(relativePath)
            let data = try XCTUnwrap(
                try? Data(contentsOf: url),
                "Could not read catalog at \(url.path)"
            )
            let decoded = try JSONDecoder().decode(StringCatalog.self, from: data)
            return Catalog(name: relativePath, strings: decoded.strings)
        }
    }

    // MARK: - Test 1: every non-empty key is translated into German

    func testAllNonEmptyKeysHaveTranslatedGermanValue() throws {
        let catalogs = try loadCatalogs()
        XCTAssertEqual(catalogs.count, Self.catalogRelativePaths.count)

        for catalog in catalogs {
            let nonEmptyKeys = catalog.strings.keys.filter { $0.isEmpty == false }
            XCTAssertFalse(nonEmptyKeys.isEmpty, "\(catalog.name) has no non-empty keys to check")

            for key in nonEmptyKeys {
                guard let entry = catalog.strings[key] else { continue }
                guard let de = entry.localizations?["de"]?.stringUnit else {
                    XCTFail("\(catalog.name): key \"\(key)\" has no German localization")
                    continue
                }
                XCTAssertEqual(
                    de.state,
                    "translated",
                    "\(catalog.name): key \"\(key)\" German state is \(de.state ?? "nil"), expected \"translated\""
                )
                XCTAssertTrue(
                    (de.value?.isEmpty ?? true) == false,
                    "\(catalog.name): key \"\(key)\" German value is missing or empty"
                )
            }
        }
    }

    // MARK: - Test 2: format-specifier parity between English and German

    func testFormatSpecifiersMatchBetweenEnglishAndGerman() throws {
        let catalogs = try loadCatalogs()

        for catalog in catalogs {
            for (key, entry) in catalog.strings where key.isEmpty == false {
                // Translation completeness is asserted by test 1; skip here
                // rather than double-report the same missing-value failure.
                guard let deValue = entry.localizations?["de"]?.stringUnit?.value else { continue }

                let enValue = entry.localizations?["en"]?.stringUnit?.value ?? key
                let enSpecifiers = Self.normalizedFormatSpecifiers(in: enValue)
                let deSpecifiers = Self.normalizedFormatSpecifiers(in: deValue)

                XCTAssertEqual(
                    enSpecifiers,
                    deSpecifiers,
                    "\(catalog.name): key \"\(key)\" format specifiers differ (en: \(enSpecifiers), de: \(deSpecifiers))"
                )
            }
        }
    }

    /// Extracts every `%`-format specifier from `string`, normalizing
    /// positional specifiers (`%1$@`) to their unpositioned form (`%@`) and
    /// dropping literal `%%` escapes, then sorts so ordering differences
    /// (which are legitimate translation choices) don't fail the comparison.
    private static func normalizedFormatSpecifiers(in string: String) -> [String] {
        let pattern = #"%\d+\$[a-zA-Z@]|%[a-zA-Z@]|%%"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            XCTFail("Failed to compile format-specifier regex")
            return []
        }
        let fullRange = NSRange(string.startIndex..<string.endIndex, in: string)

        var specifiers: [String] = []
        for match in regex.matches(in: string, range: fullRange) {
            guard let matchRange = Range(match.range, in: string) else { continue }
            let raw = String(string[matchRange])
            guard raw != "%%" else { continue }
            specifiers.append(stripPositionalPrefix(raw))
        }
        return specifiers.sorted()
    }

    /// "%1$@" -> "%@", "%2$d" -> "%d"; specifiers with no positional prefix
    /// pass through unchanged.
    private static func stripPositionalPrefix(_ specifier: String) -> String {
        guard specifier.hasPrefix("%"), let dollarIndex = specifier.firstIndex(of: "$") else {
            return specifier
        }
        let conversion = specifier[specifier.index(after: dollarIndex)...]
        return "%" + conversion
    }

    // MARK: - Test 3: keys shared between the two Localizable catalogs stay in sync

    func testSharedLocalizableKeysHaveIdenticalGermanValues() throws {
        let catalogs = try loadCatalogs()
        let appCatalogName = "KeeForge/Resources/Localizable.xcstrings"
        let autoFillCatalogName = "AutoFillExtension/Localizable.xcstrings"

        let appCatalog = try XCTUnwrap(catalogs.first { $0.name == appCatalogName })
        let autoFillCatalog = try XCTUnwrap(catalogs.first { $0.name == autoFillCatalogName })

        let appKeys = Set(appCatalog.strings.keys.filter { $0.isEmpty == false })
        let autoFillKeys = Set(autoFillCatalog.strings.keys.filter { $0.isEmpty == false })
        let sharedKeys = appKeys.intersection(autoFillKeys)

        XCTAssertFalse(sharedKeys.isEmpty, "Expected shared keys between the app and AutoFill Localizable catalogs")

        for key in sharedKeys.sorted() {
            let appValue = appCatalog.strings[key]?.localizations?["de"]?.stringUnit?.value
            let autoFillValue = autoFillCatalog.strings[key]?.localizations?["de"]?.stringUnit?.value
            XCTAssertEqual(
                appValue,
                autoFillValue,
                "Shared key \"\(key)\" has divergent German translations between the app and AutoFill catalogs"
            )
        }
    }

    // MARK: - Test 4: the app bundle advertises German support

    func testBundleAdvertisesGermanLocalization() {
        XCTAssertTrue(
            Bundle.main.localizations.contains("de"),
            "Bundle.main.localizations does not include \"de\": \(Bundle.main.localizations)"
        )
    }
}
