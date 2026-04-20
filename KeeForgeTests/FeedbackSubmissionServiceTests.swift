import XCTest
@testable import KeeForge

final class FeedbackSubmissionServiceTests: XCTestCase {
    func testMakePayloadBuildsConservativeShape() throws {
        let payload = try FeedbackSubmissionService.makePayload(
            message: "  Opening a database failed after I moved it.  ",
            consentToContact: false,
            contact: "ignored@example.com",
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
            ),
            environment: AppFeedbackEnvironment(
                appVersion: "1.8.1",
                buildNumber: "2",
                osVersion: "iOS 18.4",
                deviceModel: "iPhone17,1"
            )
        )

        XCTAssertEqual(payload.message, "Opening a database failed after I moved it.")
        XCTAssertEqual(payload.errorCode, "file.not_found")
        XCTAssertEqual(payload.errorCategory, "file_access")
        XCTAssertEqual(payload.appVersion, "1.8.1")
        XCTAssertEqual(payload.buildNumber, "2")
        XCTAssertEqual(payload.osVersion, "iOS 18.4")
        XCTAssertEqual(payload.deviceModel, "iPhone17,1")
        XCTAssertTrue(payload.details.contains("Technical Details:"))
        XCTAssertFalse(payload.consentToContact)
        XCTAssertEqual(payload.contact, "")
    }

    func testMakePayloadRequiresMessage() {
        XCTAssertThrowsError(
            try FeedbackSubmissionService.makePayload(
                message: "   ",
                consentToContact: false,
                contact: "",
                context: .general,
                environment: AppFeedbackEnvironment(
                    appVersion: "1.8.1",
                    buildNumber: "2",
                    osVersion: "iOS 18.4",
                    deviceModel: "iPhone17,1"
                )
            )
        ) { error in
            XCTAssertEqual(error as? FeedbackSubmissionError, .messageRequired)
        }
    }

    func testSubmitEncodesPayloadToFeedbackEndpoint() async throws {
        let capture = RequestCapture()
        let environment = AppFeedbackEnvironment(
            appVersion: "1.8.1",
            buildNumber: "2",
            osVersion: "iOS 18.4",
            deviceModel: "iPhone17,1"
        )

        let payload = try await FeedbackSubmissionService.submit(
            message: "Opening my database failed.",
            consentToContact: true,
            contact: "me@example.com",
            context: .general,
            environment: environment,
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
        XCTAssertEqual(payload.contact, "me@example.com")

        let body = try XCTUnwrap(capturedRequest?.httpBody)
        let decodedPayload = try JSONDecoder().decode(AppFeedbackPayload.self, from: body)
        XCTAssertEqual(decodedPayload, payload)
    }
}

private actor RequestCapture {
    private(set) var request: URLRequest?

    func store(_ request: URLRequest) {
        self.request = request
    }
}
