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

struct DurableFileWriteIO: Sendable {
    var write: @Sendable (Int32, UnsafeRawPointer, Int) -> Int = { Darwin.write($0, $1, $2) }
}

func writeAtomicallyAndDurably(
    _ data: Data, to destinationURL: URL, directoryAnchor: URL? = nil,
    io: DurableFileWriteIO = .init()
) throws {
    let directory = destinationURL.deletingLastPathComponent()
    // An existing granted directory is the boundary when no ancestry is supplied.
    try createDurableDirectory(at: directory, anchor: directoryAnchor ?? directory)
    let temporary = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
    defer { try? FileManager.default.removeItem(at: temporary) }
    let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { Darwin.close(descriptor) }
    try protectDurableFile(at: temporary, descriptor: descriptor)
    try data.withUnsafeBytes { buffer in
        var offset = 0
        while offset < buffer.count {
            guard let base = buffer.baseAddress else { throw CocoaError(.fileWriteUnknown) }
            let count = io.write(descriptor, base.advanced(by: offset), buffer.count - offset)
            if count < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard count > 0 else { throw POSIXError(.EIO) }
            offset += count
        }
    }
    try synchronizeDescriptor(descriptor)
    guard Darwin.rename(temporary.path, destinationURL.path) == 0 else { throw POSIXError(.EIO) }
    try synchronizeDirectory(directory)
}

func protectDurableFile(at url: URL, descriptor: Int32) throws {
    guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    #if os(iOS)
    try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
    #endif
}

func createDurableDirectory(
    at directory: URL, anchor: URL,
    synchronize: @Sendable (URL) throws -> Void = synchronizeDirectory
) throws {
    let root = anchor.standardizedFileURL.resolvingSymlinksInPath()
    let target = directory.standardizedFileURL.resolvingSymlinksInPath()
    let rootParts = root.pathComponents
    let parts = target.pathComponents
    guard parts.starts(with: rootParts),
          try FileManager.default.attributesOfItem(atPath: root.path)[.type] as? FileAttributeType == .typeDirectory else {
        throw CocoaError(.fileWriteNoPermission)
    }
    try synchronize(root)
    var parent = root
    for component in parts.dropFirst(rootParts.count) {
        let child = parent.appendingPathComponent(component, isDirectory: true)
        if Darwin.mkdir(child.path, S_IRWXU) != 0 {
            guard errno == EEXIST,
                  try FileManager.default.attributesOfItem(atPath: child.path)[.type] as? FileAttributeType == .typeDirectory else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        // Reconfirm every in-grant namespace edge, including a previous failed mkdir/fsync.
        try synchronize(child)
        try synchronize(parent)
        parent = child
    }
}

private func synchronizeDescriptor(_ descriptor: Int32) throws {
    while fsync(descriptor) != 0 {
        if errno == EINTR { continue }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

func synchronizeDirectory(_ directory: URL) throws {
    let descriptor = Darwin.open(directory.path, O_RDONLY | O_CLOEXEC)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { Darwin.close(descriptor) }
    try synchronizeDescriptor(descriptor)
}
