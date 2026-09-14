#!/usr/bin/env swift

import CryptoKit
import Foundation

enum VerificationError: LocalizedError {
    case invalidSignature

    var errorDescription: String? {
        switch self {
        case .invalidSignature:
            return "Sparkle Ed25519 signature does not match the archive and embedded SUPublicEDKey"
        }
    }
}

func verify(appURL: URL, zipURL: URL, signatureURL: URL) throws {
    let infoURL = appURL.appendingPathComponent("Contents/Info.plist")
    let infoData = try Data(contentsOf: infoURL)
    let info = try PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any]
    guard let publicKeyText = info?["SUPublicEDKey"] as? String,
          let publicKey = Data(base64Encoded: publicKeyText) else {
        throw NSError(domain: "KeeForgeSparkleVerification", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "missing or malformed SUPublicEDKey"])
    }

    let attributes = try String(contentsOf: signatureURL, encoding: .utf8)
    let expression = try NSRegularExpression(pattern: "sparkle:edSignature=\\\"([^\\\"]+)\\\"")
    let range = NSRange(attributes.startIndex..., in: attributes)
    guard let match = expression.firstMatch(in: attributes, range: range),
          let signatureRange = Range(match.range(at: 1), in: attributes),
          let signature = Data(base64Encoded: String(attributes[signatureRange])) else {
        throw NSError(domain: "KeeForgeSparkleVerification", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "missing or malformed Sparkle Ed25519 signature"])
    }
    guard publicKey.count == 32, signature.count == 64 else {
        throw NSError(domain: "KeeForgeSparkleVerification", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "unexpected Ed25519 key or signature length"])
    }

    let archive = try Data(contentsOf: zipURL, options: .mappedIfSafe)
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
    guard key.isValidSignature(signature, for: archive) else {
        throw VerificationError.invalidSignature
    }

    let digest = SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined()
    print("algorithm=Ed25519 via CryptoKit Curve25519.Signing")
    print("public_key_bytes=\(publicKey.count)")
    print("signature_bytes=\(signature.count)")
    print("archive_bytes=\(archive.count)")
    print("archive_sha256=\(digest)")
    print("result=pass")
}

func runSelfTest() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("keeforge-sparkle-ed25519-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }

    let appURL = root.appendingPathComponent("KeeForge.app")
    let contentsURL = appURL.appendingPathComponent("Contents")
    let zipURL = root.appendingPathComponent("fixture.zip")
    let signatureURL = root.appendingPathComponent("signature.txt")
    try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
    let info = ["SUPublicEDKey": "11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo="]
    let infoData = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    try infoData.write(to: contentsURL.appendingPathComponent("Info.plist"))
    try Data().write(to: zipURL)
    try "sparkle:edSignature=\"5VZDAMNgrHKQhuLMgG6CioSHfx645dl02HPgZSJJAVVfuIIVkKM7rMYeOXAc+bRr0lv18FlbviRlUUFDjnoQCw==\" length=\"0\"\n"
        .write(to: signatureURL, atomically: true, encoding: .utf8)

    try verify(appURL: appURL, zipURL: zipURL, signatureURL: signatureURL)
    try Data([0]).write(to: zipURL)
    do {
        try verify(appURL: appURL, zipURL: zipURL, signatureURL: signatureURL)
        throw NSError(domain: "KeeForgeSparkleVerification", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "changed archive unexpectedly verified"])
    } catch VerificationError.invalidSignature {
        print("negative_changed_archive=result=fail")
    }
    print("self_test=pass")
}

let arguments = Array(CommandLine.arguments.dropFirst())
do {
    if arguments == ["--self-test"] {
        try runSelfTest()
    } else if arguments.count == 3 {
        try verify(
            appURL: URL(fileURLWithPath: arguments[0]),
            zipURL: URL(fileURLWithPath: arguments[1]),
            signatureURL: URL(fileURLWithPath: arguments[2])
        )
    } else {
        fputs("usage: verify_sparkle_ed25519.swift APP ZIP SIGNATURE_FILE\n       verify_sparkle_ed25519.swift --self-test\n", stderr)
        exit(2)
    }
} catch {
    fputs("error: \(error.localizedDescription)\n", stderr)
    exit(1)
}
