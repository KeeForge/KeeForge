#if os(macOS)
import AppKit
import AuthenticationServices
@preconcurrency import MSAL
import XCTest
@testable import KeeForge

/// Slice 03 of the macOS port: the provider auth paths must no longer throw
/// the slice-01 "isn't available in this Mac build yet" stub error, and the
/// desktop auth configuration they build must be well-formed. The interactive
/// auth itself opens a browser / web session and is covered by the manual
/// acceptance pass, not unit tests.
@MainActor
final class CloudProviderDesktopAuthTests: XCTestCase {
    override func setUp() {
        super.setUp()
        CloudAccountStore.clearAll()
    }

    override func tearDown() {
        CloudAccountStore.clearAll()
        super.tearDown()
    }

    // MARK: - Stub error removal

    func testDropboxAuthenticateNoLongerThrowsMacStubError() async throws {
        guard configuredDropboxAppKey == nil else {
            throw XCTSkip("A real Dropbox app key is configured; skipping so the desktop OAuth flow does not open a browser.")
        }

        do {
            _ = try await DropboxCloudProvider.shared.authenticate(from: makeAnchorWindow())
            XCTFail("Expected invalidConfiguration when no Dropbox app key is configured")
        } catch let error as CloudProviderError {
            // The mac path now runs the real desktop OAuth pipeline; without an
            // app key it must stop at the well-defined configuration gate, not
            // the slice-01 "unavailable" stub.
            XCTAssertEqual(error, .invalidConfiguration)
        }
    }

    func testOneDriveAuthenticateNoLongerThrowsMacStubError() async throws {
        guard configuredOneDriveClientID == nil else {
            throw XCTSkip("A real OneDrive client ID is configured; skipping so MSAL does not present a web session.")
        }

        do {
            _ = try await OneDriveCloudProvider.shared.authenticate(from: makeAnchorWindow())
            XCTFail("Expected invalidConfiguration when no OneDrive client ID is configured")
        } catch let error as CloudProviderError {
            XCTAssertEqual(error, .invalidConfiguration)
        }
    }

    // MARK: - Well-formed desktop auth configuration

    func testOneDriveWebviewParametersPresentFromAnchorContentViewController() throws {
        let window = makeAnchorWindow()
        let parameters = OneDriveCloudProvider.makeWebviewParameters(from: window)

        XCTAssertNotNil(window.contentViewController)
        XCTAssertIdentical(parameters.parentViewController, window.contentViewController)
    }

    func testDropboxDesktopScopeRequestIsWellFormed() {
        let scopeRequest = DropboxCloudProvider.makeScopeRequest()

        XCTAssertEqual(scopeRequest.scopes, DropboxCloudProvider.requestedScopes)
        XCTAssertTrue(scopeRequest.scopes.contains("files.content.write"))
    }

    func testMacBundleRegistersOAuthRedirectSchemes() throws {
        let urlTypes = try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]]
        )
        let schemes = urlTypes.flatMap { ($0["CFBundleURLSchemes"] as? [String]) ?? [] }

        // Dropbox's desktop OAuth completes via the db-<appkey> scheme handled
        // by onOpenURL -> handleRedirectURL; MSAL requires the msauth scheme.
        XCTAssertTrue(schemes.contains { $0.hasPrefix("db-") })
        XCTAssertTrue(schemes.contains("msauth.com.keevault.app"))
    }

    func testOneDriveHandleRedirectURLDefersToOtherHandlersOnMac() throws {
        // MSAL has no handleMSALResponse on macOS: the web session intercepts
        // the msauth redirect internally, so the provider must decline the URL
        // and let other handlers (e.g. Dropbox, file opens) inspect it.
        let url = try XCTUnwrap(URL(string: "msauth.com.keevault.app://auth"))
        XCTAssertFalse(OneDriveCloudProvider.shared.handleRedirectURL(url))
    }

    // MARK: - Helpers

    private final class AnchorViewController: NSViewController {
        override func loadView() {
            view = NSView()
        }
    }

    private func makeAnchorWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.contentViewController = AnchorViewController()
        return window
    }

    private var configuredDropboxAppKey: String? {
        configuredInfoValue(forKey: "DropboxAppKey", placeholders: [
            "DROPBOX_APP_KEY",
            "CI_PLACEHOLDER_DROPBOX_APP_KEY",
        ])
    }

    private var configuredOneDriveClientID: String? {
        configuredInfoValue(forKey: "OneDriveClientID", placeholders: [
            "$(ONEDRIVE_CLIENT_ID)",
            "ONEDRIVE_CLIENT_ID",
            "YOUR_ONEDRIVE_CLIENT_ID",
            "00000000-0000-0000-0000-000000000000",
        ])
    }

    /// Mirrors the providers' own placeholder filtering so the authenticate
    /// tests only run when the config gate is guaranteed to trip.
    private func configuredInfoValue(forKey key: String, placeholders: Set<String>) -> String? {
        guard let rawValue = Bundle.main.object(forInfoDictionaryKey: key) as? String else {
            return nil
        }

        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !placeholders.contains(trimmed) else {
            return nil
        }

        return trimmed
    }
}
#endif
