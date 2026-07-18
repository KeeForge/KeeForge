import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import KeeForge

final class FeedbackSubmissionServiceTests: XCTestCase {
    func testMakePayloadBuildsMessageAndVisibleErrorDetailsOnly() throws {
        let payload = try FeedbackSubmissionService.makePayload(
            message: "  Opening a database failed after I moved it.  ",
            context: .databaseOpenFailure(
                DatabaseOpenFailure(
                    title: "Database File Unavailable",
                    summary: "KeeForge couldn't find the file.",
                    technicalDetails: "The file couldn’t be opened. [NSCocoaErrorDomain 260]",
                    errorCode: "file.not_found",
                    category: .fileAccess,
                    countsTowardFailedAttempts: false,
                    canChooseDifferentFile: true,
                    diagnostics: DatabaseOpenDiagnostics(
                        lines: [
                            "Unlock Method: password",
                            "Encrypted File SHA-256 Prefix: abcdef1234567890",
                            "Device Model: iPhone16,2",
                        ]
                    )
                )
            )
        )

        XCTAssertEqual(payload.message, "Opening a database failed after I moved it.")
        XCTAssertTrue(payload.details.contains("Category: file_access"))
        XCTAssertTrue(payload.details.contains("Code: file.not_found"))
        XCTAssertTrue(payload.details.contains("Technical Details:"))
        XCTAssertTrue(payload.details.contains("Diagnostics:"))
        XCTAssertTrue(payload.details.contains("Device Model: iPhone16,2"))
        XCTAssertFalse(payload.details.contains("abcdef1234567890abcdef1234567890"))
        XCTAssertNil(payload.consentToContact)
        XCTAssertNil(payload.contact)
        XCTAssertNil(payload.photo)
    }

    func testMakePayloadRequiresMessage() {
        XCTAssertThrowsError(
            try FeedbackSubmissionService.makePayload(
                message: "   ",
                context: .general
            )
        ) { error in
            XCTAssertEqual(error as? FeedbackSubmissionError, .messageRequired)
        }
    }

    func testMakePayloadIncludesContactOnlyWhenFollowUpIsAllowed() throws {
        let withFollowUp = try FeedbackSubmissionService.makePayload(
            message: "Search is slow.",
            context: .general,
            allowFollowUp: true,
            contactEmail: "  user@example.com  "
        )
        XCTAssertEqual(withFollowUp.consentToContact, true)
        XCTAssertEqual(withFollowUp.contact, "user@example.com")

        let withoutFollowUp = try FeedbackSubmissionService.makePayload(
            message: "Search is slow.",
            context: .general,
            allowFollowUp: false,
            contactEmail: "user@example.com"
        )
        XCTAssertNil(withoutFollowUp.consentToContact)
        XCTAssertNil(withoutFollowUp.contact)
    }

    func testMakePayloadValidatesFollowUpEmail() {
        XCTAssertThrowsError(
            try FeedbackSubmissionService.makePayload(
                message: "Search is slow.",
                context: .general,
                allowFollowUp: true,
                contactEmail: "   "
            )
        ) { error in
            XCTAssertEqual(error as? FeedbackSubmissionError, .contactEmailRequired)
        }

        for invalidEmail in ["no-at-sign", "two@@example.com", "user@nodot", "user@.com", "spaced user@example.com"] {
            XCTAssertThrowsError(
                try FeedbackSubmissionService.makePayload(
                    message: "Search is slow.",
                    context: .general,
                    allowFollowUp: true,
                    contactEmail: invalidEmail
                ),
                "expected \(invalidEmail) to be rejected"
            ) { error in
                XCTAssertEqual(error as? FeedbackSubmissionError, .contactEmailInvalid)
            }
        }
    }

    func testMakePayloadRejectsOversizedPhoto() {
        let oversized = AppFeedbackPhoto(
            data: Data(count: FeedbackSubmissionService.maxPhotoByteCount + 1),
            contentType: "image/jpeg"
        )

        XCTAssertThrowsError(
            try FeedbackSubmissionService.makePayload(
                message: "Screenshot attached.",
                context: .general,
                photo: oversized
            )
        ) { error in
            XCTAssertEqual(error as? FeedbackSubmissionError, .photoTooLarge)
        }
    }

    func testSubmitEncodesPayloadToFeedbackEndpoint() async throws {
        let capture = RequestCapture()

        let payload = try await FeedbackSubmissionService.submit(
            message: "Opening my database failed.",
            context: .general,
            send: { request in
                await capture.store(request)
                return (
                    Data(),
                    HTTPURLResponse(
                        url: request.url ?? FeedbackSubmissionService.endpointURL,
                        statusCode: 202,
                        httpVersion: nil,
                        headerFields: nil
                    )!
                )
            }
        )

        let capturedRequest = await capture.request
        XCTAssertEqual(capturedRequest?.url, FeedbackSubmissionService.endpointURL)
        XCTAssertEqual(capturedRequest?.httpMethod, "POST")
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(payload.details, "")

        let body = try XCTUnwrap(capturedRequest?.httpBody)
        let decodedPayload = try JSONDecoder().decode(AppFeedbackPayload.self, from: body)
        XCTAssertEqual(decodedPayload, payload)

        let jsonObject = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(jsonObject["message"], "Opening my database failed.")
        XCTAssertEqual(jsonObject["details"], "")
        XCTAssertNil(jsonObject["consentToContact"])
        XCTAssertNil(jsonObject["contact"])
        XCTAssertNil(jsonObject["photo"])
        XCTAssertNil(jsonObject["appVersion"])
        XCTAssertNil(jsonObject["buildNumber"])
        XCTAssertNil(jsonObject["osVersion"])
        XCTAssertNil(jsonObject["deviceModel"])
    }

    func testSubmitEncodesFollowUpAndBase64PhotoFields() async throws {
        let capture = RequestCapture()
        let photo = AppFeedbackPhoto(data: Data([0xFF, 0xD8, 0xFF, 0xE0]), contentType: "image/jpeg")

        _ = try await FeedbackSubmissionService.submit(
            message: "Screenshot attached.",
            context: .general,
            allowFollowUp: true,
            contactEmail: "user@example.com",
            photo: photo,
            send: { request in
                await capture.store(request)
                return (
                    Data(),
                    HTTPURLResponse(
                        url: request.url ?? FeedbackSubmissionService.endpointURL,
                        statusCode: 202,
                        httpVersion: nil,
                        headerFields: nil
                    )!
                )
            }
        )

        let capturedRequest = await capture.request
        let body = try XCTUnwrap(capturedRequest?.httpBody)
        let jsonObject = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(jsonObject["consentToContact"] as? Bool, true)
        XCTAssertEqual(jsonObject["contact"] as? String, "user@example.com")

        let photoObject = try XCTUnwrap(jsonObject["photo"] as? [String: Any])
        XCTAssertEqual(photoObject["contentType"] as? String, "image/jpeg")
        let base64 = try XCTUnwrap(photoObject["data"] as? String)
        XCTAssertEqual(Data(base64Encoded: base64), photo.data)
    }

    func testPhotoProcessorProducesBoundedJPEG() throws {
        let attachment = try FeedbackPhotoProcessor.makeAttachment(from: makePNGData(width: 3000, height: 2000))

        XCTAssertEqual(attachment.contentType, "image/jpeg")
        XCTAssertLessThanOrEqual(attachment.data.count, FeedbackSubmissionService.maxPhotoByteCount)

        let source = try XCTUnwrap(CGImageSourceCreateWithData(attachment.data as CFData, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
        let width = try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? Int)
        let height = try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? Int)
        XCTAssertLessThanOrEqual(max(width, height), FeedbackPhotoProcessor.maxPixelSize)
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.jpeg.identifier)
    }

    func testPhotoProcessorRejectsNonImageData() {
        XCTAssertThrowsError(
            try FeedbackPhotoProcessor.makeAttachment(from: Data("not an image".utf8))
        ) { error in
            XCTAssertEqual(error as? FeedbackSubmissionError, .photoUnreadable)
        }
    }

    private func makePNGData(width: Int, height: Int) throws -> Data {
        let context = try XCTUnwrap(
            CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())

        let output = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }
}

private actor RequestCapture {
    private(set) var request: URLRequest?

    func store(_ request: URLRequest) {
        self.request = request
    }
}
