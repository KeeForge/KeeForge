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

    var submittedDetails: String {
        var components: [String] = []

        if errorCategory.isEmpty == false {
            components.append("Category: \(errorCategory)")
        }

        if errorCode.isEmpty == false {
            components.append("Code: \(errorCode)")
        }

        if details.isEmpty == false {
            components.append(details)
        }

        return components.joined(separator: "\n")
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
    let details: String
}

enum FeedbackSubmissionError: LocalizedError, Equatable, Sendable {
    case messageRequired
    case invalidResponse(Int)

    var errorDescription: String? {
        switch self {
        case .messageRequired:
            "Add a short message before sending feedback."
        case .invalidResponse:
            "KeeForge couldn't submit the feedback right now. Please try again later."
        }
    }
}

enum FeedbackSubmissionService {
    static let endpointURL = URL(string: "https://feedback.keeforge.com/api/feedback")!

    typealias SendOperation = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static func makePayload(
        message: String,
        context: FeedbackComposerContext
    ) throws -> AppFeedbackPayload {
        let trimmedMessage = trim(message)
        guard trimmedMessage.isEmpty == false else {
            throw FeedbackSubmissionError.messageRequired
        }

        return AppFeedbackPayload(
            message: trimmedMessage,
            details: trim(context.submittedDetails)
        )
    }

    static func submit(
        message: String,
        context: FeedbackComposerContext,
        send: @escaping SendOperation = liveSend
    ) async throws -> AppFeedbackPayload {
        let payload = try makePayload(
            message: message,
            context: context
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

    private static func trim(_ string: String) -> String {
        string.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor @Observable
final class FeedbackComposerModel {
    typealias SubmitOperation = @Sendable (
        _ message: String,
        _ context: FeedbackComposerContext
    ) async throws -> AppFeedbackPayload

    let context: FeedbackComposerContext
    var message: String
    private(set) var isSubmitting = false
    private(set) var didSubmit = false
    var submissionErrorMessage: String?

    private let submitOperation: SubmitOperation

    init(
        context: FeedbackComposerContext,
        submitOperation: @escaping SubmitOperation = { message, context in
            try await FeedbackSubmissionService.submit(
                message: message,
                context: context
            )
        }
    ) {
        self.context = context
        self.message = context.initialMessage
        self.submitOperation = submitOperation
    }

    var canSend: Bool {
        isSubmitting == false && message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    func submit() async {
        guard isSubmitting == false else { return }
        isSubmitting = true
        submissionErrorMessage = nil

        do {
            _ = try await submitOperation(message, context)
            didSubmit = true
            HapticService.success()
        } catch {
            submissionErrorMessage = error.localizedDescription
        }

        isSubmitting = false
    }
}
