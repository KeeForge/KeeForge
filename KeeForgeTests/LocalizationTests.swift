import XCTest
@testable import KeeForge

/// Gates the four `.xcstrings` catalogs against silently shipping untranslated
/// or drifted German strings. Reads the raw JSON catalog sources — not the
/// compiled catalogs the app bundles — so a new English key with no German
/// translation fails here before it ever reaches a build.
///
/// The raw catalogs are copied verbatim into this test bundle at build time by
/// a `postCompileScripts` phase on the `KeeForgeTests` target (see `project.yml`),
/// under disambiguated names. Reading them from `Bundle(for:)` — rather than
/// off the source checkout — keeps the test correct on Xcode Cloud, where the
/// test action runs on machines that do not have the repository checkout.
final class LocalizationTests: XCTestCase {

    // MARK: - String catalog decoding

    private struct StringUnit: Decodable {
        let state: String?
        let value: String?
    }

    private struct Variations: Decodable {
        let plural: [String: Localization]?
    }

    private struct Localization: Decodable {
        let stringUnit: StringUnit?
        let variations: Variations?

        /// Every concrete unit this localization carries: the flat unit for
        /// plain strings, or one per plural branch for `variations` entries.
        var allStringUnits: [StringUnit] {
            if let stringUnit {
                return [stringUnit]
            }
            return variations?.plural?.values.flatMap(\.allStringUnits) ?? []
        }
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

    /// A raw catalog bundled into the test bundle. `name` is the catalog's
    /// logical repo-relative path (preserved for assertions and messages);
    /// `bundleResource` is the disambiguated filename the `postBuildScripts`
    /// phase copies it to inside the `.xctest` bundle.
    private struct CatalogSource {
        let name: String
        let bundleResource: String
    }

    private static let catalogSources: [CatalogSource] = [
        CatalogSource(name: "KeeForge/Resources/Localizable.xcstrings", bundleResource: "KeeForge_Localizable"),
        CatalogSource(name: "KeeForge/Resources/InfoPlist.xcstrings", bundleResource: "KeeForge_InfoPlist"),
        CatalogSource(name: "AutoFillExtension/Localizable.xcstrings", bundleResource: "AutoFillExtension_Localizable"),
        CatalogSource(name: "AutoFillExtension/InfoPlist.xcstrings", bundleResource: "AutoFillExtension_InfoPlist"),
    ]

    private func loadCatalogs() throws -> [Catalog] {
        let bundle = Bundle(for: LocalizationTests.self)
        return try Self.catalogSources.map { source in
            let url = try XCTUnwrap(
                bundle.url(forResource: source.bundleResource, withExtension: "xcstrings"),
                "Could not locate bundled catalog \(source.bundleResource).xcstrings for \(source.name)"
            )
            let data = try XCTUnwrap(
                try? Data(contentsOf: url),
                "Could not read catalog at \(url.path) for \(source.name)"
            )
            let decoded = try JSONDecoder().decode(StringCatalog.self, from: data)
            return Catalog(name: source.name, strings: decoded.strings)
        }
    }

    // MARK: - Test 1: every non-empty key is translated into German

    func testAllNonEmptyKeysHaveTranslatedGermanValue() throws {
        let catalogs = try loadCatalogs()
        XCTAssertEqual(catalogs.count, Self.catalogSources.count)

        for catalog in catalogs {
            let nonEmptyKeys = catalog.strings.keys.filter { $0.isEmpty == false }
            XCTAssertFalse(nonEmptyKeys.isEmpty, "\(catalog.name) has no non-empty keys to check")

            for key in nonEmptyKeys {
                guard let entry = catalog.strings[key] else { continue }
                let germanUnits = entry.localizations?["de"]?.allStringUnits ?? []
                guard germanUnits.isEmpty == false else {
                    XCTFail("\(catalog.name): key \"\(key)\" has no German localization")
                    continue
                }
                for de in germanUnits {
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
    }

    // MARK: - Test 2: format-specifier parity between English and German

    func testFormatSpecifiersMatchBetweenEnglishAndGerman() throws {
        let catalogs = try loadCatalogs()

        for catalog in catalogs {
            for (key, entry) in catalog.strings where key.isEmpty == false {
                // Translation completeness is asserted by test 1; skip here
                // rather than double-report the same missing-value failure.
                if let deValue = entry.localizations?["de"]?.stringUnit?.value {
                    let enValue = entry.localizations?["en"]?.stringUnit?.value ?? key
                    let enSpecifiers = Self.normalizedFormatSpecifiers(in: enValue)
                    let deSpecifiers = Self.normalizedFormatSpecifiers(in: deValue)

                    XCTAssertEqual(
                        enSpecifiers,
                        deSpecifiers,
                        "\(catalog.name): key \"\(key)\" format specifiers differ (en: \(enSpecifiers), de: \(deSpecifiers))"
                    )
                }

                // Plural entries: each German branch must use specifiers from
                // the English "other" branch (the general form; branches like
                // "one" legitimately drop the number).
                if let dePlural = entry.localizations?["de"]?.variations?.plural {
                    let enOther = entry.localizations?["en"]?.variations?.plural?["other"]?.stringUnit?.value ?? key
                    let enSpecifiers = Set(Self.normalizedFormatSpecifiers(in: enOther))
                    for (category, branch) in dePlural {
                        guard let deValue = branch.stringUnit?.value else { continue }
                        let deSpecifiers = Set(Self.normalizedFormatSpecifiers(in: deValue))
                        XCTAssertTrue(
                            deSpecifiers.isSubset(of: enSpecifiers),
                            "\(catalog.name): key \"\(key)\" plural branch \"\(category)\" uses specifiers \(deSpecifiers) not present in the English form \(enSpecifiers)"
                        )
                    }
                }
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
