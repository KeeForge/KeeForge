#if os(macOS)
import Foundation
import Observation

/// The green tick a Mac window shows for 1.5 seconds where a value was copied:
/// which entry and field, until it clears. It holds no copied value.
@MainActor @Observable
final class MacCopyFeedback {
    enum Field: Equatable {
        case username
        case password
        case url
        case verificationCode
        /// The detail pane's second and later website rows; 1 is the first URL after `url`.
        case additionalURL(Int)
        case customField(String)
        case passkeyRelyingParty
        case passkeyUsername

        var copiedLabel: String {
            switch self {
            case .username: String(localized: "Username copied")
            case .password: String(localized: "Password copied")
            case .url, .additionalURL: String(localized: "URL copied")
            case .verificationCode: String(localized: "Verification code copied")
            case .customField(let name): String(localized: "\(name) copied")
            case .passkeyRelyingParty: String(localized: "Relying party copied")
            case .passkeyUsername: String(localized: "Passkey username copied")
            }
        }
    }

    struct Copied: Equatable {
        let entryID: UUID
        let field: Field
    }

    static let duration: Duration = .milliseconds(1500)

    private(set) var copied: Copied?
    @ObservationIgnored private(set) var clearTask: Task<Void, Never>?
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void

    init(sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.sleep = sleep
    }

    /// Marks a copy that happened; a later copy restarts the duration.
    func show(_ field: Field, for entryID: UUID) {
        clearTask?.cancel()
        let copied = Copied(entryID: entryID, field: field)
        self.copied = copied
        clearTask = Task { [weak self, sleep] in
            do { try await sleep(Self.duration) } catch { return }
            guard let self, self.copied == copied, Task.isCancelled == false else { return }
            self.copied = nil
            self.clearTask = nil
        }
    }

    /// Wraps a clipboard write so the tick shows only once the value was really copied.
    func recording(
        _ field: Field,
        for entryID: UUID,
        copy: @escaping @MainActor (String) -> Void = { ClipboardService.copy($0) }
    ) -> @MainActor (String) -> Void {
        { [weak self] value in
            copy(value)
            self?.show(field, for: entryID)
        }
    }

    func field(copiedFor entryID: UUID) -> Field? {
        copied?.entryID == entryID ? copied?.field : nil
    }

    func clear() {
        clearTask?.cancel()
        clearTask = nil
        copied = nil
    }
}
#endif
