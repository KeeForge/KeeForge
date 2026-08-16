import Foundation

/// Zeroes key material with `memset_s`, which the compiler may not elide.
///
/// Only wipe buffers this code created and uniquely owns: `Data.withUnsafeMutableBytes`
/// on a shared or bridged buffer copies first, so the wipe would miss the original.
enum SecureWipe {
    static func wipe(_ buffer: UnsafeMutableRawBufferPointer) {
        guard let baseAddress = buffer.baseAddress, !buffer.isEmpty else { return }
        _ = memset_s(baseAddress, buffer.count, 0, buffer.count)
    }

    static func wipe(_ data: inout Data) {
        data.withUnsafeMutableBytes { wipe($0) }
    }

    static func wipe<Element>(_ elements: inout [Element]) {
        elements.withUnsafeMutableBytes { wipe($0) }
    }

    /// A `Data` whose backing buffer is zeroed when its last holder — including any
    /// bridged `NSData` — releases it.
    static func wipingData(copying bytes: some ContiguousBytes) -> Data {
        bytes.withUnsafeBytes { source in
            guard !source.isEmpty else { return Data() }
            let pointer = UnsafeMutableRawPointer.allocate(byteCount: source.count, alignment: 1)
            UnsafeMutableRawBufferPointer(start: pointer, count: source.count).copyBytes(from: source)
            return Data(bytesNoCopy: pointer, count: source.count, deallocator: .custom { pointer, count in
                wipe(UnsafeMutableRawBufferPointer(start: pointer, count: count))
                pointer.deallocate()
            })
        }
    }
}
