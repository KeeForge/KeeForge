import Foundation

enum CoordinatedFileReader {
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
