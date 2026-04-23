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
                    canChooseDifferentFile: true
                )
            )
        )

        XCTAssertEqual(payload.message, "Opening a database failed after I moved it.")
        XCTAssertTrue(payload.details.contains("Category: file_access"))
        XCTAssertTrue(payload.details.contains("Code: file.not_found"))
        XCTAssertTrue(payload.details.contains("Technical Details:"))
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
        XCTAssertNil(jsonObject["contact"])
        XCTAssertNil(jsonObject["appVersion"])
        XCTAssertNil(jsonObject["buildNumber"])
        XCTAssertNil(jsonObject["osVersion"])
        XCTAssertNil(jsonObject["deviceModel"])
    }
}

private actor RequestCapture {
    private(set) var request: URLRequest?

    func store(_ request: URLRequest) {
        self.request = request
    }
}
