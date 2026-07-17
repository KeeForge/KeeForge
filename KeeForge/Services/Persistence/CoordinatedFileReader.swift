import Foundation

enum CoordinatedFileReader {
    enum TimeoutError: Error, LocalizedError, Equatable, Sendable {
        case timedOut

        var errorDescription: String? {
            String(localized: "The database file did not respond in time. Check that its server or network connection is available.")
        }
    }

    /// Runs blocking file-provider work without tying up the caller's actor and
    /// returns after a bounded interval if an unavailable provider never calls
    /// back. The underlying system call may finish later; `FirstResult` ensures
    /// only the first completion resumes the caller.
    static func performBlocking<T: Sendable>(
        timeout: Duration,
        operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        let firstResult = FirstResult<T>()

        Task.detached(priority: .userInitiated) {
            let result = Result { try operation() }
            await firstResult.complete(with: result)
        }

        Task.detached {
            do {
                try await Task.sleep(for: timeout)
                await firstResult.complete(with: .failure(TimeoutError.timedOut))
            } catch {
                // A cancelled timeout must not replace the file operation's result.
            }
        }

        return try await firstResult.value()
    }

    static func readData(from url: URL) throws -> Data {
        var coordinatorError: NSError?
        var result: Result<Data, Error>?

        let coordinator = NSFileCoordinator()
        coordinator.coordinate(
            readingItemAt: url,
            options: [],
            error: &coordinatorError
        ) { coordinatedURL in
            result = Result { try Data(contentsOf: coordinatedURL) }
        }

        if let coordinatorError {
            throw coordinatorError
        }
        return try result!.get()
    }

    static func readDataPrefix(from url: URL, byteCount: Int) throws -> Data {
        var coordinatorError: NSError?
        var result: Result<Data, Error>?

        let coordinator = NSFileCoordinator()
        coordinator.coordinate(
            readingItemAt: url,
            options: [],
            error: &coordinatorError
        ) { coordinatedURL in
            result = Result {
                let handle = try FileHandle(forReadingFrom: coordinatedURL)
                defer { try? handle.close() }
                return try handle.read(upToCount: byteCount) ?? Data()
            }
        }

        if let coordinatorError {
            throw coordinatorError
        }

        guard let result else {
            throw CocoaError(.fileReadUnknown)
        }

        return try result.get()
    }

    static func writeData(_ data: Data, to url: URL, options: Data.WritingOptions = [.atomic]) throws {
        var coordinatorError: NSError?
        var writeResult: Result<Void, Error>?

        let coordinator = NSFileCoordinator()
        coordinator.coordinate(
            writingItemAt: url,
            options: [],
            error: &coordinatorError
        ) { coordinatedURL in
            writeResult = Result { try data.write(to: coordinatedURL, options: options) }
        }

        if let coordinatorError {
            throw coordinatorError
        }
        try writeResult!.get()
    }
}

private actor FirstResult<Value: Sendable> {
    private var result: Result<Value, Error>?
    private var continuation: CheckedContinuation<Value, Error>?

    func value() async throws -> Value {
        if let result {
            return try result.get()
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func complete(with result: Result<Value, Error>) {
        guard self.result == nil else { return }
        self.result = result

        if let continuation {
            self.continuation = nil
            continuation.resume(with: result)
        }
    }
}
