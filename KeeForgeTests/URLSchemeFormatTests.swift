import XCTest
@testable import KeeForge

/// Guards against ITMS-90158. The declared URL schemes are built from build
/// settings (`db-$(DROPBOX_APP_KEY)`, `msauth.$(PRODUCT_BUNDLE_IDENTIFIER)`), so a
/// malformed key or placeholder silently produces an illegal scheme that only
/// App Store Connect rejects — after the archive has already been uploaded.
/// The unit tests are hosted by KeeForge.app, so `Bundle.main` here is the app
/// bundle with the settings already substituted.
final class URLSchemeFormatTests: XCTestCase {
    /// RFC1738 §2.1: scheme = alphanumeric, then alphanumerics, "+", "-", ".".
    private static let validScheme = try! NSRegularExpression(
        pattern: "^[A-Za-z][A-Za-z0-9+.-]*$"
    )

    func testDeclaredURLSchemesAreRFC1738Compliant() throws {
        let schemes = try declaredURLSchemes()
        XCTAssertFalse(schemes.isEmpty, "Expected the app bundle to declare at least one URL scheme")

        for scheme in schemes {
            let range = NSRange(scheme.startIndex..., in: scheme)
            XCTAssertNotNil(
                Self.validScheme.firstMatch(in: scheme, range: range),
                "URL scheme '\(scheme)' is not RFC1738-compliant; App Store Connect rejects it with ITMS-90158"
            )
        }
    }

    func testDropboxSchemeIsSubstituted() throws {
        let schemes = try declaredURLSchemes()
        let dropboxSchemes = schemes.filter { $0.hasPrefix("db-") }

        XCTAssertEqual(dropboxSchemes.count, 1, "Expected exactly one Dropbox OAuth scheme")
        XCTAssertFalse(
            dropboxSchemes.contains("db-$(DROPBOX_APP_KEY)"),
            "DROPBOX_APP_KEY was not substituted into the Dropbox URL scheme"
        )
    }

    private func declaredURLSchemes() throws -> [String] {
        let urlTypes = try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]],
            "Missing CFBundleURLTypes in the host app bundle"
        )

        return urlTypes.flatMap { ($0["CFBundleURLSchemes"] as? [String]) ?? [] }
    }
}
