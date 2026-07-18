import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

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
            title: String(localized: "Send Feedback"),
            prompt: String(localized: "Tell us what happened or what would make KeeForge better."),
            initialMessage: "",
            errorCode: "",
            errorCategory: "",
            details: ""
        )
    }

    static func databaseOpenFailure(_ failure: DatabaseOpenFailure) -> FeedbackComposerContext {
        FeedbackComposerContext(
            id: "open-failure-\(failure.errorCode)",
            title: String(localized: "Send Feedback"),
            prompt: String(localized: "Tell us what you were doing when KeeForge tried to open the database."),
            initialMessage: String(localized: "KeeForge couldn't open my database."),
            errorCode: failure.errorCode,
            errorCategory: failure.category.rawValue,
            details: failure.reportDetails
        )
    }
}

struct AppFeedbackPhoto: Codable, Equatable, Sendable {
    /// JPEG image bytes; `JSONEncoder` serializes this as a base64 string.
    let data: Data
    let contentType: String
}

struct AppFeedbackPayload: Codable, Equatable, Sendable {
    let message: String
    let details: String
    // Optional fields are omitted from the JSON entirely when nil so a plain
    // submission stays as narrow as before.
    let consentToContact: Bool?
    let contact: String?
    let photo: AppFeedbackPhoto?
}

enum FeedbackSubmissionError: LocalizedError, Equatable, Sendable {
    case messageRequired
    case contactEmailRequired
    case contactEmailInvalid
    case photoTooLarge
    case photoUnreadable
    case invalidResponse(Int)

    var errorDescription: String? {
        switch self {
        case .messageRequired:
            String(localized: "Add a short message before sending feedback.")
        case .contactEmailRequired:
            String(localized: "Enter an email address for follow-up, or turn follow-up off.")
        case .contactEmailInvalid:
            String(localized: "Enter a valid email address for follow-up.")
        case .photoTooLarge:
            String(localized: "The attached photo is too large. Choose a smaller photo.")
        case .photoUnreadable:
            String(localized: "KeeForge couldn't read that photo. Choose a different one.")
        case .invalidResponse:
            String(localized: "KeeForge couldn't submit the feedback right now. Please try again later.")
        }
    }
}

enum FeedbackSubmissionService {
    static let endpointURL = URL(string: "https://feedback.keeforge.com/api/feedback")!
    static let maxPhotoByteCount = 5 * 1024 * 1024

    typealias SendOperation = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static func makePayload(
        message: String,
        context: FeedbackComposerContext,
        allowFollowUp: Bool = false,
        contactEmail: String = "",
        photo: AppFeedbackPhoto? = nil
    ) throws -> AppFeedbackPayload {
        let trimmedMessage = trim(message)
        guard trimmedMessage.isEmpty == false else {
            throw FeedbackSubmissionError.messageRequired
        }

        var contact: String?
        if allowFollowUp {
            let trimmedEmail = trim(contactEmail)
            guard trimmedEmail.isEmpty == false else {
                throw FeedbackSubmissionError.contactEmailRequired
            }
            guard isLikelyValidEmail(trimmedEmail) else {
                throw FeedbackSubmissionError.contactEmailInvalid
            }
            contact = trimmedEmail
        }

        if let photo {
            guard photo.data.isEmpty == false else {
                throw FeedbackSubmissionError.photoUnreadable
            }
            guard photo.data.count <= maxPhotoByteCount else {
                throw FeedbackSubmissionError.photoTooLarge
            }
        }

        return AppFeedbackPayload(
            message: trimmedMessage,
            details: trim(context.submittedDetails),
            consentToContact: allowFollowUp ? true : nil,
            contact: contact,
            photo: photo
        )
    }

    static func submit(
        message: String,
        context: FeedbackComposerContext,
        allowFollowUp: Bool = false,
        contactEmail: String = "",
        photo: AppFeedbackPhoto? = nil,
        send: @escaping SendOperation = liveSend
    ) async throws -> AppFeedbackPayload {
        let payload = try makePayload(
            message: message,
            context: context,
            allowFollowUp: allowFollowUp,
            contactEmail: contactEmail,
            photo: photo
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

    static func isLikelyValidEmail(_ email: String) -> Bool {
        guard email.contains(" ") == false else { return false }
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let local = parts[0]
        let domain = parts[1]
        return local.isEmpty == false
            && domain.contains(".")
            && domain.hasPrefix(".") == false
            && domain.hasSuffix(".") == false
    }

    private static func liveSend(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await URLSession.shared.data(for: request)
    }

    private static func trim(_ string: String) -> String {
        string.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Re-encodes a user-picked image into a bounded JPEG attachment. Downscaling
/// through `CGImageSourceCreateThumbnailAtIndex` also drops photo metadata
/// (EXIF, GPS) so location data never leaves the device.
enum FeedbackPhotoProcessor {
    static let maxPixelSize = 2048
    static let jpegQuality: Double = 0.75

    static func makeAttachment(from rawData: Data) throws -> AppFeedbackPhoto {
        guard rawData.isEmpty == false,
              let source = CGImageSourceCreateWithData(rawData as CFData, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw FeedbackSubmissionError.photoUnreadable
        }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]

        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            throw FeedbackSubmissionError.photoUnreadable
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw FeedbackSubmissionError.photoUnreadable
        }

        let destinationProperties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: jpegQuality,
        ]
        CGImageDestinationAddImage(destination, image, destinationProperties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw FeedbackSubmissionError.photoUnreadable
        }

        let jpegData = output as Data
        guard jpegData.count <= FeedbackSubmissionService.maxPhotoByteCount else {
            throw FeedbackSubmissionError.photoTooLarge
        }

        return AppFeedbackPhoto(data: jpegData, contentType: "image/jpeg")
    }
}

@MainActor @Observable
final class FeedbackComposerModel {
    typealias SubmitOperation = @Sendable (
        _ message: String,
        _ context: FeedbackComposerContext,
        _ allowFollowUp: Bool,
        _ contactEmail: String,
        _ photo: AppFeedbackPhoto?
    ) async throws -> AppFeedbackPayload

    let context: FeedbackComposerContext
    var message: String
    var allowFollowUp = false
    var contactEmail = ""
    private(set) var attachedPhoto: AppFeedbackPhoto?
    private(set) var isProcessingPhoto = false
    private(set) var isSubmitting = false
    private(set) var didSubmit = false
    var submissionErrorMessage: String?
    var photoErrorMessage: String?

    private let submitOperation: SubmitOperation

    init(
        context: FeedbackComposerContext,
        submitOperation: @escaping SubmitOperation = { message, context, allowFollowUp, contactEmail, photo in
            try await FeedbackSubmissionService.submit(
                message: message,
                context: context,
                allowFollowUp: allowFollowUp,
                contactEmail: contactEmail,
                photo: photo
            )
        }
    ) {
        self.context = context
        self.message = context.initialMessage
        self.submitOperation = submitOperation
    }

    var canSend: Bool {
        guard isSubmitting == false, isProcessingPhoto == false else { return false }
        guard message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return false }
        if allowFollowUp {
            return contactEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
        return true
    }

    func attachPhoto(rawData: Data) async {
        guard isProcessingPhoto == false else { return }
        isProcessingPhoto = true
        photoErrorMessage = nil

        do {
            attachedPhoto = try await Task.detached(priority: .userInitiated) {
                try FeedbackPhotoProcessor.makeAttachment(from: rawData)
            }.value
        } catch {
            attachedPhoto = nil
            photoErrorMessage = error.localizedDescription
        }

        isProcessingPhoto = false
    }

    func removePhoto() {
        attachedPhoto = nil
    }

    func submit() async {
        guard isSubmitting == false else { return }
        isSubmitting = true
        submissionErrorMessage = nil

        do {
            _ = try await submitOperation(message, context, allowFollowUp, contactEmail, attachedPhoto)
            didSubmit = true
            HapticService.success()
        } catch {
            submissionErrorMessage = error.localizedDescription
        }

        isSubmitting = false
    }
}
