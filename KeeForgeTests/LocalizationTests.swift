import XCTest
@testable import KeeForge

/// Gates the four `.xcstrings` catalogs against silently shipping untranslated
/// or drifted strings in any shipped translation locale. Reads the raw JSON
/// catalog sources — not the compiled catalogs the app bundles — so a new
/// English key with no translation fails here before it ever reaches a build.
///
/// The raw catalogs are copied verbatim into this test bundle at build time by
/// a `postCompileScripts` phase on the `KeeForgeTests` and `KeeForgeMacTests`
/// targets (see `project.yml`), under disambiguated names. Reading them from `Bundle(for:)` — rather than
/// off the source checkout — keeps the test correct on Xcode Cloud, where the
/// test action runs on machines that do not have the repository checkout.
final class LocalizationTests: XCTestCase {

    // MARK: - Shipped locales

    /// Every locale KeeForge ships a translation for, beyond the source
    /// language `en`. Add a locale here once its catalogs are fully
    /// translated to bring it under every check in this file.
    private static let shippedTranslationLocales = ["de", "fr"]

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

    // MARK: - Test 1: every non-empty key is translated into each shipped locale

    func testAllNonEmptyKeysHaveTranslatedValueForShippedLocales() throws {
        let catalogs = try loadCatalogs()
        XCTAssertEqual(catalogs.count, Self.catalogSources.count)

        for catalog in catalogs {
            let nonEmptyKeys = catalog.strings.keys.filter { $0.isEmpty == false }
            XCTAssertFalse(nonEmptyKeys.isEmpty, "\(catalog.name) has no non-empty keys to check")

            for key in nonEmptyKeys {
                guard let entry = catalog.strings[key] else { continue }
                for locale in Self.shippedTranslationLocales {
                    let units = entry.localizations?[locale]?.allStringUnits ?? []
                    guard units.isEmpty == false else {
                        XCTFail("\(catalog.name): key \"\(key)\" has no \(locale) localization")
                        continue
                    }
                    for unit in units {
                        XCTAssertEqual(
                            unit.state,
                            "translated",
                            "\(catalog.name): key \"\(key)\" \(locale) state is \(unit.state ?? "nil"), expected \"translated\""
                        )
                        XCTAssertTrue(
                            (unit.value?.isEmpty ?? true) == false,
                            "\(catalog.name): key \"\(key)\" \(locale) value is missing or empty"
                        )
                    }
                }
            }
        }
    }

    // MARK: - Test 2: format-specifier parity between English and each shipped locale

    func testFormatSpecifiersMatchBetweenEnglishAndShippedLocales() throws {
        let catalogs = try loadCatalogs()

        for catalog in catalogs {
            for (key, entry) in catalog.strings where key.isEmpty == false {
                for locale in Self.shippedTranslationLocales {
                    // Translation completeness is asserted by test 1; skip here
                    // rather than double-report the same missing-value failure.
                    if let localizedValue = entry.localizations?[locale]?.stringUnit?.value {
                        let enValue = entry.localizations?["en"]?.stringUnit?.value ?? key
                        let enSpecifiers = Self.normalizedFormatSpecifiers(in: enValue)
                        let localizedSpecifiers = Self.normalizedFormatSpecifiers(in: localizedValue)

                        XCTAssertEqual(
                            enSpecifiers,
                            localizedSpecifiers,
                            "\(catalog.name): key \"\(key)\" format specifiers differ (en: \(enSpecifiers), \(locale): \(localizedSpecifiers))"
                        )
                    }

                    // Plural entries: the localized "other" branch (the general
                    // form) must carry exactly the English "other" specifiers;
                    // branches like "one" legitimately drop the number, so
                    // subset suffices.
                    if let localizedPlural = entry.localizations?[locale]?.variations?.plural {
                        let enOther = entry.localizations?["en"]?.variations?.plural?["other"]?.stringUnit?.value ?? key
                        let enSpecifiers = Set(Self.normalizedFormatSpecifiers(in: enOther))
                        for (category, branch) in localizedPlural {
                            guard let localizedValue = branch.stringUnit?.value else { continue }
                            let localizedSpecifiers = Set(Self.normalizedFormatSpecifiers(in: localizedValue))
                            if category == "other" {
                                XCTAssertEqual(
                                    localizedSpecifiers,
                                    enSpecifiers,
                                    "\(catalog.name): key \"\(key)\" \(locale) plural branch \"other\" must match the English specifiers exactly"
                                )
                            } else {
                                XCTAssertTrue(
                                    localizedSpecifiers.isSubset(of: enSpecifiers),
                                    "\(catalog.name): key \"\(key)\" \(locale) plural branch \"\(category)\" uses specifiers \(localizedSpecifiers) not present in the English form \(enSpecifiers)"
                                )
                            }
                        }
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

    func testSharedLocalizableKeysHaveIdenticalValuesForShippedLocales() throws {
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
            for locale in Self.shippedTranslationLocales {
                let appValue = appCatalog.strings[key]?.localizations?[locale]?.stringUnit?.value
                let autoFillValue = autoFillCatalog.strings[key]?.localizations?[locale]?.stringUnit?.value
                XCTAssertEqual(
                    appValue,
                    autoFillValue,
                    "Shared key \"\(key)\" has divergent \(locale) translations between the app and AutoFill catalogs"
                )
            }
        }
    }

    // MARK: - Test 4: the app bundle advertises every shipped locale

    func testBundleAdvertisesShippedLocalizations() {
        for locale in Self.shippedTranslationLocales {
            XCTAssertTrue(
                Bundle.main.localizations.contains(locale),
                "Bundle.main.localizations does not include \"\(locale)\": \(Bundle.main.localizations)"
            )
        }
    }
}
