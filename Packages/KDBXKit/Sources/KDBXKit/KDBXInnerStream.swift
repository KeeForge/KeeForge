import Foundation

/// The inner random stream that masks protected XML values.
///
/// It is one keystream spanning every protected value in document order, so a
/// reader or writer keeps one instance and feeds it values in that order.
/// XOR-based: the same call encodes and decodes.
public struct KDBXInnerStream {
    private enum Mode {
        case none
        case salsa20(initialState: [UInt32])
        case chacha20(KDBXCrypto.ChaCha20Keystream)
    }

    private var mode: Mode
    private var salsaCounterLow: UInt32 = 0
    private var salsaCounterHigh: UInt32 = 0
    private var keystreamBlock: [UInt8] = []
    private var offset = 0

    /// Throws `ParseError.unsupportedProtectedFieldStream` for stream IDs other
    /// than none, Salsa20, and ChaCha20.
    public init(streamID: UInt32, key: Data) throws {
        switch streamID {
        case KDBXContainer.innerStreamNone:
            mode = .none

        case KDBXContainer.innerStreamSalsa20:
            let hashedKey = KDBXCrypto.sha256(key)
            let nonce = Data([0xE8, 0x30, 0x09, 0x4B, 0x97, 0x20, 0x5D, 0x2A])
            var state = [UInt32](repeating: 0, count: 16)
            state[0] = 0x61707865
            state[5] = 0x3320646e
            state[10] = 0x79622d32
            state[15] = 0x6b206574

            hashedKey.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
                for i in 0..<4 {
                    state[1 + i] = ptr.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self).littleEndian
                    state[11 + i] = ptr.loadUnaligned(fromByteOffset: (i + 4) * 4, as: UInt32.self).littleEndian
                }
            }

            nonce.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
                state[6] = ptr.loadUnaligned(fromByteOffset: 0, as: UInt32.self).littleEndian
                state[7] = ptr.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian
            }

            mode = .salsa20(initialState: state)

        case KDBXContainer.innerStreamChaCha20:
            let keyHash = KDBXCrypto.sha512(key)
            guard let keystream = KDBXCrypto.ChaCha20Keystream(
                key: Data(keyHash.prefix(32)),
                nonce: Data(keyHash[32..<44])
            ) else {
                throw KDBXContainer.ParseError.innerHeaderInvalid
            }
            mode = .chacha20(keystream)

        default:
            throw KDBXContainer.ParseError.unsupportedProtectedFieldStream(streamID)
        }
    }

    public mutating func apply(_ data: Data) -> Data {
        guard !data.isEmpty else { return data }

        switch mode {
        case .none:
            return data
        case .salsa20(let initialState):
            return xorSalsa20(data, initialState: initialState)
        case .chacha20(var keystream):
            let result = keystream.xor(data)
            mode = .chacha20(keystream)
            return result
        }
    }

    private mutating func xorSalsa20(_ input: Data, initialState: [UInt32]) -> Data {
        var output = [UInt8](repeating: 0, count: input.count)

        input.withUnsafeBytes { (inputPtr: UnsafeRawBufferPointer) in
            var readOffset = 0
            while readOffset < input.count {
                if offset >= keystreamBlock.count {
                    keystreamBlock = Self.makeSalsa20Block(
                        initialState: initialState,
                        counterLow: salsaCounterLow,
                        counterHigh: salsaCounterHigh
                    )
                    offset = 0
                    let nextLow = salsaCounterLow &+ 1
                    if nextLow == 0 {
                        salsaCounterHigh &+= 1
                    }
                    salsaCounterLow = nextLow
                }

                let chunkLength = min(input.count - readOffset, keystreamBlock.count - offset)
                for index in 0..<chunkLength {
                    output[readOffset + index] = inputPtr[readOffset + index] ^ keystreamBlock[offset + index]
                }
                readOffset += chunkLength
                offset += chunkLength
            }
        }

        return Data(output)
    }

    private static func makeSalsa20Block(
        initialState: [UInt32],
        counterLow: UInt32,
        counterHigh: UInt32
    ) -> [UInt8] {
        var state = initialState
        state[8] = counterLow
        state[9] = counterHigh

        var working = state
        for _ in 0..<10 {
            salsaQuarterRound(&working, 0, 4, 8, 12)
            salsaQuarterRound(&working, 5, 9, 13, 1)
            salsaQuarterRound(&working, 10, 14, 2, 6)
            salsaQuarterRound(&working, 15, 3, 7, 11)

            salsaQuarterRound(&working, 0, 1, 2, 3)
            salsaQuarterRound(&working, 5, 6, 7, 4)
            salsaQuarterRound(&working, 10, 11, 8, 9)
            salsaQuarterRound(&working, 15, 12, 13, 14)
        }

        for i in 0..<16 {
            working[i] = working[i] &+ state[i]
        }

        return serializeWords(working)
    }

    private static func salsaQuarterRound(_ state: inout [UInt32], _ a: Int, _ b: Int, _ c: Int, _ d: Int) {
        state[b] ^= rotl(state[a] &+ state[d], by: 7)
        state[c] ^= rotl(state[b] &+ state[a], by: 9)
        state[d] ^= rotl(state[c] &+ state[b], by: 13)
        state[a] ^= rotl(state[d] &+ state[c], by: 18)
    }

    private static func rotl(_ value: UInt32, by amount: UInt32) -> UInt32 {
        (value << amount) | (value >> (32 - amount))
    }

    private static func serializeWords(_ words: [UInt32]) -> [UInt8] {
        var block: [UInt8] = []
        block.reserveCapacity(64)
        for word in words {
            var little = word.littleEndian
            withUnsafeBytes(of: &little) { bytes in
                block.append(contentsOf: bytes)
            }
        }
        return block
    }
}
