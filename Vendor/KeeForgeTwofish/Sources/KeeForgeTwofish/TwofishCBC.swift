import CTwofish
import Foundation

public enum TwofishError: Error, Equatable, Sendable {
    case invalidKeyLength(actual: Int)
    case invalidIVLength(actual: Int)
    case invalidBlockLength(actual: Int)
    case invalidCiphertextLength(actual: Int)
    case initializationFailed
    case contextCreationFailed
    case operationFailed
    case invalidPadding
}

public enum TwofishCBC {
    private static let blockSize = 16

    public static func encrypt(_ plaintext: Data, key: Data, iv: Data) throws -> Data {
        guard key.count == 32 else {
            throw TwofishError.invalidKeyLength(actual: key.count)
        }
        guard iv.count == blockSize else {
            throw TwofishError.invalidIVLength(actual: iv.count)
        }

        return try TwofishCore.withContext(key: key, allowedKeyLengths: [32]) { context in
            var paddedPlaintext = [UInt8](plaintext)
            var chain = [UInt8](iv)
            var block = [UInt8](repeating: 0, count: blockSize)
            var encryptedBlock = [UInt8](repeating: 0, count: blockSize)
            var ciphertext = [UInt8]()

            defer {
                secureZero(&paddedPlaintext)
                secureZero(&chain)
                secureZero(&block)
                secureZero(&encryptedBlock)
                secureZero(&ciphertext)
            }

            let paddingLength = blockSize - (paddedPlaintext.count % blockSize)
            paddedPlaintext.append(
                contentsOf: repeatElement(UInt8(paddingLength), count: paddingLength)
            )
            ciphertext.reserveCapacity(paddedPlaintext.count)

            for offset in stride(from: 0, to: paddedPlaintext.count, by: blockSize) {
                for index in 0..<blockSize {
                    block[index] = paddedPlaintext[offset + index] ^ chain[index]
                }

                guard TwofishCore.encryptBlock(block, into: &encryptedBlock, context: context) else {
                    throw TwofishError.operationFailed
                }
                ciphertext.append(contentsOf: encryptedBlock)
                chain = encryptedBlock
            }

            return Data(ciphertext)
        }
    }

    public static func decrypt(_ ciphertext: Data, key: Data, iv: Data) throws -> Data {
        guard key.count == 32 else {
            throw TwofishError.invalidKeyLength(actual: key.count)
        }
        guard iv.count == blockSize else {
            throw TwofishError.invalidIVLength(actual: iv.count)
        }
        guard !ciphertext.isEmpty, ciphertext.count.isMultiple(of: blockSize) else {
            throw TwofishError.invalidCiphertextLength(actual: ciphertext.count)
        }

        return try TwofishCore.withContext(key: key, allowedKeyLengths: [32]) { context in
            let ciphertextBytes = [UInt8](ciphertext)
            var chain = [UInt8](iv)
            var cipherBlock = [UInt8](repeating: 0, count: blockSize)
            var decryptedBlock = [UInt8](repeating: 0, count: blockSize)
            var paddedPlaintext = [UInt8]()

            defer {
                secureZero(&chain)
                secureZero(&cipherBlock)
                secureZero(&decryptedBlock)
                secureZero(&paddedPlaintext)
            }

            paddedPlaintext.reserveCapacity(ciphertextBytes.count)
            for offset in stride(from: 0, to: ciphertextBytes.count, by: blockSize) {
                for index in 0..<blockSize {
                    cipherBlock[index] = ciphertextBytes[offset + index]
                }

                guard TwofishCore.decryptBlock(
                    cipherBlock,
                    into: &decryptedBlock,
                    context: context
                ) else {
                    throw TwofishError.operationFailed
                }
                for index in 0..<blockSize {
                    paddedPlaintext.append(decryptedBlock[index] ^ chain[index])
                }
                chain = cipherBlock
            }

            let paddingLength = Int(paddedPlaintext[paddedPlaintext.count - 1])
            guard (1...blockSize).contains(paddingLength) else {
                throw TwofishError.invalidPadding
            }

            var paddingDifference: UInt8 = 0
            for distanceFromEnd in 0..<blockSize where distanceFromEnd < paddingLength {
                paddingDifference |= paddedPlaintext[paddedPlaintext.count - 1 - distanceFromEnd]
                    ^ UInt8(paddingLength)
            }
            guard paddingDifference == 0 else {
                throw TwofishError.invalidPadding
            }

            return Data(paddedPlaintext.dropLast(paddingLength))
        }
    }
}

@_spi(Testing)
public enum TwofishBlock {
    public static func encrypt(_ plaintext: Data, key: Data) throws -> Data {
        try crypt(plaintext, key: key, operation: TwofishCore.encryptBlock)
    }

    public static func decrypt(_ ciphertext: Data, key: Data) throws -> Data {
        try crypt(ciphertext, key: key, operation: TwofishCore.decryptBlock)
    }

    private static func crypt(
        _ input: Data,
        key: Data,
        operation: (
            [UInt8],
            inout [UInt8],
            KeeForgeTwofishContextRef
        ) -> Bool
    ) throws -> Data {
        guard input.count == 16 else {
            throw TwofishError.invalidBlockLength(actual: input.count)
        }
        let allowedKeyLengths: Set<Int> = [16, 24, 32]
        guard allowedKeyLengths.contains(key.count) else {
            throw TwofishError.invalidKeyLength(actual: key.count)
        }

        return try TwofishCore.withContext(key: key, allowedKeyLengths: allowedKeyLengths) { context in
            var inputBytes = [UInt8](input)
            var outputBytes = [UInt8](repeating: 0, count: 16)
            defer {
                secureZero(&inputBytes)
                secureZero(&outputBytes)
            }

            guard operation(inputBytes, &outputBytes, context) else {
                throw TwofishError.operationFailed
            }
            return Data(outputBytes)
        }
    }
}

private enum TwofishCore {
    private static let initialized: Bool = kf_twofish_initialize() == 1

    static func withContext<Result>(
        key: Data,
        allowedKeyLengths: Set<Int>,
        _ body: (KeeForgeTwofishContextRef) throws -> Result
    ) throws -> Result {
        guard allowedKeyLengths.contains(key.count) else {
            throw TwofishError.invalidKeyLength(actual: key.count)
        }
        guard initialized else {
            throw TwofishError.initializationFailed
        }

        var context: KeeForgeTwofishContextRef?
        let created = key.withUnsafeBytes { keyBytes in
            kf_twofish_context_create(keyBytes.bindMemory(to: UInt8.self).baseAddress, key.count, &context)
        }
        guard created == 1, let context else {
            throw TwofishError.contextCreationFailed
        }
        defer { kf_twofish_context_destroy(context) }

        return try body(context)
    }

    static func encryptBlock(
        _ input: [UInt8],
        into output: inout [UInt8],
        context: KeeForgeTwofishContextRef
    ) -> Bool {
        input.withUnsafeBytes { inputBytes in
            output.withUnsafeMutableBytes { outputBytes in
                kf_twofish_encrypt_block(
                    context,
                    inputBytes.bindMemory(to: UInt8.self).baseAddress,
                    outputBytes.bindMemory(to: UInt8.self).baseAddress
                ) == 1
            }
        }
    }

    static func decryptBlock(
        _ input: [UInt8],
        into output: inout [UInt8],
        context: KeeForgeTwofishContextRef
    ) -> Bool {
        input.withUnsafeBytes { inputBytes in
            output.withUnsafeMutableBytes { outputBytes in
                kf_twofish_decrypt_block(
                    context,
                    inputBytes.bindMemory(to: UInt8.self).baseAddress,
                    outputBytes.bindMemory(to: UInt8.self).baseAddress
                ) == 1
            }
        }
    }
}

private func secureZero(_ bytes: inout [UInt8]) {
    bytes.withUnsafeMutableBytes { buffer in
        kf_twofish_secure_zero(buffer.baseAddress, buffer.count)
    }
}
