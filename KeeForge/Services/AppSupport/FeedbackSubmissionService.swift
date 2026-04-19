import Foundation

struct FeedbackComposerContext: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let prompt: String
    let initialMessage: String
    let errorCode: String
    let errorCategory: String
    let details: String

    var hasErrorContext: Bool {
        errorCode.isEmpty == false || errorCategory.isEmpty == false || details.isEmpty == false
    }

    static var general: FeedbackComposerContext {
        FeedbackComposerContext(
            id: "general-feedback",
            title: "Send Feedback",
            prompt: "Tell us what happened or what would make KeeForge better.",
            initialMessage: "",
            errorCode: "",
            errorCategory: "",
            details: ""
        )
    }

    static func databaseOpenFailure(_ failure: DatabaseOpenFailure) -> FeedbackComposerContext {
        FeedbackComposerContext(
            id: "open-failure-\(failure.errorCode)",
            title: "Send Feedback",
            prompt: "Tell us what you were doing when KeeForge tried to open the database.",
            initialMessage: "KeeForge couldn't open my database.",
            errorCode: failure.errorCode,
            errorCategory: failure.category.rawValue,
            details: """
            Title: \(failure.title)
            Summary: \(failure.summary)
            Technical Details: \(failure.technicalDetails)
            """
        )
    }
}

struct AppFeedbackPayload: Codable, Equatable, Sendable {
    let message: String
    let errorCode: String
    let errorCategory: String
    let appVersion: String
    let buildNumber: String
    let osVersion: String
    let deviceModel: String
    let details: String
    let consentToContact: Bool
    let contact: String
}

struct AppFeedbackEnvironment: Equatable, Sendable {
    let appVersion: String
    let buildNumber: String
    let osVersion: String
    let deviceModel: String

    static func current(bundle: Bundle = .main) -> AppFeedbackEnvironment {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = bundle.object(forInfoDictionaryKey: kCFBundleVersionKey as String) as? String ?? "unknown"
        return AppFeedbackEnvironment(
            appVersion: version,
            buildNumber: build,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            deviceModel: currentDeviceModel()
        )
    }

    private static func currentDeviceModel() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        return mirror.children.reduce(into: "") { result, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            result.append(Character(UnicodeScalar(UInt8(value))))
        }
    }
}

enum FeedbackSubmissionError: LocalizedError, Equatable, Sendable {
    case messageRequired
    case contactRequired
    case invalidResponse(Int)

    var errorDescription: String? {
        switch self {
        case .messageRequired:
            "Add a short message before sending feedback."
        case .contactRequired:
            "Add contact information or turn off follow-up consent."
        case .invalidResponse:
            "KeeForge couldn't submit the feedback right now. Please try again later."
        }
    }
}

enum FeedbackSubmissionService {
    // Replace this placeholder before shipping a real feedback backend.
    static let endpointURL = URL(string: "https://example.com/api/feedback")!

    typealias SendOperation = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static func makePayload(
        message: String,
        consentToContact: Bool,
        contact: String,
        context: FeedbackComposerContext,
        environment: AppFeedbackEnvironment = .current()
    ) throws -> AppFeedbackPayload {
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedMessage.isEmpty == false else {
            throw FeedbackSubmissionError.messageRequired
        }

        let trimmedContact = contact.trimmingCharacters(in: .whitespacesAndNewlines)
        if consentToContact && trimmedContact.isEmpty {
            throw FeedbackSubmissionError.contactRequired
        }

        return AppFeedbackPayload(
            message: sanitize(trimmedMessage),
            errorCode: sanitize(context.errorCode),
            errorCategory: sanitize(context.errorCategory),
            appVersion: sanitize(environment.appVersion),
            buildNumber: sanitize(environment.buildNumber),
            osVersion: sanitize(environment.osVersion),
            deviceModel: sanitize(environment.deviceModel),
            details: sanitize(context.details),
            consentToContact: consentToContact,
            contact: consentToContact ? sanitize(trimmedContact) : ""
        )
    }

    static func submit(
        message: String,
        consentToContact: Bool,
        contact: String,
        context: FeedbackComposerContext,
        environment: AppFeedbackEnvironment = .current(),
        send: @escaping SendOperation = liveSend
    ) async throws -> AppFeedbackPayload {
        let payload = try makePayload(
            message: message,
            consentToContact: consentToContact,
            contact: contact,
            context: context,
            environment: environment
        )

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)

        let (_, response) = try await send(request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw FeedbackSubmissionError.invalidResponse(statusCode)
        }

        return payload
    }

    private static func liveSend(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await URLSession.shared.data(for: request)
    }

    private static func sanitize(_ string: String) -> String {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return "" }

        return trimmed.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
    }
}

@MainActor @Observable
final class FeedbackComposerModel {
    typealias SubmitOperation = @Sendable (
        _ message: String,
        _ consentToContact: Bool,
        _ contact: String,
        _ context: FeedbackComposerContext
    ) async throws -> AppFeedbackPayload

    let context: FeedbackComposerContext
    var message: String
    var consentToContact = false
    var contact = ""
    private(set) var isSubmitting = false
    private(set) var didSubmit = false
    var submissionErrorMessage: String?

    private let submitOperation: SubmitOperation

    init(
        context: FeedbackComposerContext,
        submitOperation: @escaping SubmitOperation = { message, consentToContact, contact, context in
            try await FeedbackSubmissionService.submit(
                message: message,
                consentToContact: consentToContact,
                contact: contact,
                context: context
            )
        }
    ) {
        self.context = context
        self.message = context.initialMessage
        self.submitOperation = submitOperation
    }

    var canSend: Bool {
        let hasMessage = message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let hasContact = contact.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        return isSubmitting == false && hasMessage && (consentToContact == false || hasContact)
    }

    func submit() async {
        guard isSubmitting == false else { return }
        isSubmitting = true
        submissionErrorMessage = nil

        do {
            _ = try await submitOperation(message, consentToContact, contact, context)
            didSubmit = true
            HapticService.success()
        } catch {
            submissionErrorMessage = error.localizedDescription
        }

        isSubmitting = false
    }
}
