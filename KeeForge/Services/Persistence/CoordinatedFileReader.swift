import Darwin
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

    static func readData(from url: URL, maximumByteCount: Int? = nil) throws -> Data {
        var coordinatorError: NSError?
        var result: Result<Data, Error>?

        let coordinator = NSFileCoordinator()
        coordinator.coordinate(
            readingItemAt: url,
            options: [],
            error: &coordinatorError
        ) { coordinatedURL in
            result = Result {
                guard let maximumByteCount else {
                    return try Data(contentsOf: coordinatedURL)
                }
                let byteLimit = max(0, maximumByteCount)
                if let size = try coordinatedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                   size > byteLimit {
                    throw CocoaError(.fileReadTooLarge)
                }
                let handle = try FileHandle(forReadingFrom: coordinatedURL)
                defer { try? handle.close() }
                var data = Data()
                while true {
                    try Task.checkCancellation()
                    // Probe past the limit so a file that grew after preflight is rejected.
                    let readCount = max(1, min(64 * 1024, byteLimit - data.count))
                    guard let chunk = try handle.read(upToCount: readCount), chunk.isEmpty == false else {
                        return data
                    }
                    guard chunk.count <= byteLimit - data.count else {
                        throw CocoaError(.fileReadTooLarge)
                    }
                    data.append(chunk)
                }
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

        guard let writeResult else {
            throw CocoaError(.fileWriteUnknown)
        }

        try writeResult.get()
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

func writeAtomicallyAndDurably(_ data: Data, to destinationURL: URL) throws {
    let fileManager = FileManager.default
    let directoryURL = destinationURL.deletingLastPathComponent()
    try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)

    let tempURL = directoryURL.appendingPathComponent(".\(UUID().uuidString).tmp", isDirectory: false)
    defer {
        try? fileManager.removeItem(at: tempURL)
    }

    try data.withUnsafeBytes { buffer in
        let fd = open(tempURL.path, O_WRONLY | O_CREAT | O_TRUNC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw POSIXError(.EIO)
        }
        defer { close(fd) }

        guard let baseAddress = buffer.bindMemory(to: UInt8.self).baseAddress else {
            throw CocoaError(.fileWriteUnknown)
        }

        var totalWritten = 0
        while totalWritten < data.count {
            let bytesWritten = write(fd, baseAddress.advanced(by: totalWritten), data.count - totalWritten)
            if bytesWritten < 0 {
                throw POSIXError(.EIO)
            }
            totalWritten += bytesWritten
        }

        if fsync(fd) != 0 {
            throw POSIXError(.EIO)
        }
    }

    if rename(tempURL.path, destinationURL.path) != 0 {
        throw POSIXError(.EIO)
    }

    let directoryFD = open(directoryURL.path, O_RDONLY)
    guard directoryFD >= 0 else {
        throw POSIXError(.EIO)
    }
    defer { close(directoryFD) }

    if fsync(directoryFD) != 0 {
        throw POSIXError(.EIO)
    }
}

func createDurableDirectory(at directory: URL) throws {
    let manager = FileManager.default
    if manager.fileExists(atPath: directory.path) {
        try synchronizeDirectory(directory)
        try synchronizeDirectory(directory.deletingLastPathComponent())
        return
    }
    let parent = directory.deletingLastPathComponent()
    try createDurableDirectory(at: parent)
    do { try manager.createDirectory(at: directory, withIntermediateDirectories: false) }
    catch {
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else { throw error }
    }
    try synchronizeDirectory(directory)
    try synchronizeDirectory(parent)
}

func synchronizeDirectory(_ directory: URL) throws {
    let descriptor = Darwin.open(directory.path, O_RDONLY)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { Darwin.close(descriptor) }
    guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
