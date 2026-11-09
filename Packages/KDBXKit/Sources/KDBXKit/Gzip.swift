import Foundation
import zlib

/// The payload compression KDBX calls GZip.
enum Gzip {
    /// Decompresses gzip, falling back to zlib and raw deflate, which some
    /// producers write despite the flag. Refuses output over `maxOutputSize`.
    static func decompress(_ data: Data, maxOutputSize: Int) throws -> Data {
        for windowBits in [MAX_WBITS + 16, MAX_WBITS, -MAX_WBITS] {
            if let output = try? inflate(data, windowBits: windowBits, maxOutputSize: maxOutputSize), !output.isEmpty {
                return output
            }
        }
        throw KDBXCrypto.CryptoError.decompressionFailed
    }

    static func compress(_ data: Data) throws -> Data {
        var stream = z_stream()
        guard deflateInit2_(
            &stream,
            Z_DEFAULT_COMPRESSION,
            Z_DEFLATED,
            MAX_WBITS + 16,
            MAX_MEM_LEVEL,
            Z_DEFAULT_STRATEGY,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        ) == Z_OK else {
            throw KDBXCrypto.CryptoError.compressionFailed
        }
        defer { deflateEnd(&stream) }

        return try data.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(data.count)
            return try drain(&stream, failure: .compressionFailed) { deflate(&$0, Z_FINISH) }
        }
    }

    private static func inflate(_ data: Data, windowBits: Int32, maxOutputSize: Int) throws -> Data {
        var stream = z_stream()
        guard inflateInit2_(&stream, windowBits, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw KDBXCrypto.CryptoError.decompressionFailed
        }
        defer { inflateEnd(&stream) }

        return try data.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(data.count)
            return try drain(&stream, maxOutputSize: maxOutputSize, failure: .decompressionFailed) { zlib.inflate(&$0, Z_NO_FLUSH) }
        }
    }

    /// Runs `step` until it reports the end of the stream. Any other result
    /// than progress fails, including a truncated input, which zlib reports
    /// as `Z_BUF_ERROR`.
    private static func drain(
        _ stream: inout z_stream,
        maxOutputSize: Int = .max,
        failure: KDBXCrypto.CryptoError,
        step: (inout z_stream) -> Int32
    ) throws -> Data {
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)

        while true {
            let status = buffer.withUnsafeMutableBufferPointer { buffer in
                stream.next_out = buffer.baseAddress
                stream.avail_out = uInt(buffer.count)
                return step(&stream)
            }
            output.append(contentsOf: buffer.prefix(buffer.count - Int(stream.avail_out)))

            guard output.count <= maxOutputSize else { throw failure }
            if status == Z_STREAM_END {
                return output
            }
            guard status == Z_OK else { throw failure }
        }
    }
}
