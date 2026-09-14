#!/usr/bin/env swift

import CoreFoundation
import CryptoKit
import Foundation

enum RestoreError: Error {
    case invalidInput
    case verificationFailed
}

let managedDefaultsDomain = "com.keevault.app"

func requireManagedDefaultsDomain(_ domain: String) throws {
    guard domain == managedDefaultsDomain else { throw RestoreError.invalidInput }
}

func sha256(_ url: URL) throws -> String {
    let data = try Data(contentsOf: url, options: .mappedIfSafe)
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func propertyListDictionary(at url: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: url)
    guard let dictionary = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
        throw RestoreError.invalidInput
    }
    return dictionary
}

func currentDefaults(for domain: String) -> [String: Any] {
    (CFPreferencesCopyMultiple(
        nil,
        domain as CFString,
        kCFPreferencesCurrentUser,
        kCFPreferencesAnyHost
    ) as? [String: Any]) ?? [:]
}

func writeDefaultsSnapshot(domain: String, output: URL) throws {
    try requireManagedDefaultsDomain(domain)
    let data = try PropertyListSerialization.data(
        fromPropertyList: currentDefaults(for: domain),
        format: .xml,
        options: 0
    )
    try data.write(to: output, options: .atomic)
    print("defaults-snapshot=written")
}

func restoreDefaults(domain: String, input: URL) throws {
    try requireManagedDefaultsDomain(domain)
    let original = try propertyListDictionary(at: input)
    let current = currentDefaults(for: domain)
    for key in current.keys {
        CFPreferencesSetValue(key as CFString, nil, domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }
    for (key, value) in original {
        CFPreferencesSetValue(key as CFString, value as CFPropertyList, domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }
    guard CFPreferencesSynchronize(domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
        throw RestoreError.verificationFailed
    }
    print("defaults-restore=applied")
}

func verifyDefaults(domain: String, input: URL) throws {
    try requireManagedDefaultsDomain(domain)
    let original = try propertyListDictionary(at: input)
    guard (original as NSDictionary).isEqual(currentDefaults(for: domain)) else {
        throw RestoreError.verificationFailed
    }
    print("defaults-verify=matched keys=\(original.count)")
}

func restoreDefaultsFile(original: URL, current: URL, output: URL) throws {
    _ = try propertyListDictionary(at: current)
    let baseline = try propertyListDictionary(at: original)
    let data = try PropertyListSerialization.data(fromPropertyList: baseline, format: .xml, options: 0)
    try data.write(to: output, options: .atomic)
    print("defaults-file-restore=written keys=\(baseline.count)")
}

func verifyDefaultsFile(expected: URL, actual: URL) throws {
    guard (try propertyListDictionary(at: expected) as NSDictionary).isEqual(try propertyListDictionary(at: actual)) else {
        throw RestoreError.verificationFailed
    }
    print("defaults-file-verify=matched")
}

func relativeRegularFiles(in root: URL) throws -> Set<String> {
    let manager = FileManager.default
    let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
        throw RestoreError.invalidInput
    }
    let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
    guard let enumerator = manager.enumerator(atPath: root.path) else {
        throw RestoreError.verificationFailed
    }
    var paths = Set<String>()
    while let relative = enumerator.nextObject() as? String {
        let url = root.appendingPathComponent(relative, isDirectory: false)
        let values = try url.resourceValues(forKeys: keys)
        guard values.isSymbolicLink != true else { throw RestoreError.invalidInput }
        guard values.isRegularFile == true else { continue }
        guard relative.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ $0 != "." && $0 != ".." }) else {
            throw RestoreError.verificationFailed
        }
        paths.insert(relative)
    }
    return paths
}

func manifest(at url: URL) throws -> [String: String] {
    let data = try Data(contentsOf: url)
    guard let records = try JSONSerialization.jsonObject(with: data) as? [String: String], records.isEmpty == false else {
        throw RestoreError.invalidInput
    }
    for value in records.values {
        guard value.count == 64, value.allSatisfy({ $0.isHexDigit }) else { throw RestoreError.invalidInput }
    }
    return records
}

func groupFileURL(for record: String, group: URL) throws -> URL {
    let components = record.split(separator: "/", omittingEmptySubsequences: false)
    guard components.isEmpty == false,
          components.allSatisfy({ $0.isEmpty == false && $0 != "." && $0 != ".." })
    else {
        throw RestoreError.invalidInput
    }
    return components.reduce(group) { $0.appendingPathComponent(String($1), isDirectory: false) }
}

func verifyManifest(root: URL, group: URL, label: String) throws {
    let records = try manifest(at: root.appendingPathComponent("sha256.json"))
    let currentFiles = try relativeRegularFiles(in: group)
    var matched = 0
    var missing = 0
    var mismatched = 0
    for (record, expected) in records {
        do {
            let file = try groupFileURL(for: record, group: group)
            if FileManager.default.fileExists(atPath: file.path) == false {
                missing += 1
            } else if try sha256(file) == expected {
                matched += 1
            } else {
                mismatched += 1
            }
        } catch {
            mismatched += 1
        }
    }
    let unmanifested = currentFiles.subtracting(Set(records.keys)).count
    print("\(label) records=\(records.count) matched=\(matched) missing=\(missing) mismatched=\(mismatched) unmanifested=\(unmanifested)")
    guard missing == 0, mismatched == 0, unmanifested == 0 else { throw RestoreError.verificationFailed }
}

func writeManifest(root: URL, output: URL) throws {
    let group = root.appendingPathComponent("app-group", isDirectory: true)
    var records = [String: String]()
    for relative in try relativeRegularFiles(in: group) {
        records[relative] = try sha256(group.appendingPathComponent(relative))
    }
    guard records.isEmpty == false else { throw RestoreError.invalidInput }
    let data = try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: output, options: .atomic)
    print("group-manifest=written records=\(records.count)")
}

func compareGroups(backup: URL, live: URL) throws {
    let original = try relativeRegularFiles(in: backup)
    let current = try relativeRegularFiles(in: live)
    print("group-compare backup_files=\(original.count) live_files=\(current.count) live_extra=\(current.subtracting(original).count) backup_missing=\(original.subtracting(current).count)")
}

func validateGroup(_ group: URL) throws {
    print("group-validate regular_files=\(try relativeRegularFiles(in: group).count)")
}

func singleDifference(backup: URL, live: URL) throws -> (extra: String, missing: String)? {
    let original = try relativeRegularFiles(in: backup)
    let current = try relativeRegularFiles(in: live)
    let extra = current.subtracting(original)
    let missing = original.subtracting(current)
    guard extra.count == 1, missing.count == 1, let extraPath = extra.first, let missingPath = missing.first else {
        return nil
    }
    return (extraPath, missingPath)
}

func removeProvenFixtureExtra(backup: URL, live: URL, fixture: URL) throws {
    guard let difference = try singleDifference(backup: backup, live: live),
          difference.extra.hasPrefix("databases/"),
          difference.extra.hasSuffix(".kdbx")
    else {
        throw RestoreError.verificationFailed
    }
    let extra = live.appendingPathComponent(difference.extra)
    guard try sha256(extra) == sha256(fixture) else { throw RestoreError.verificationFailed }
    try FileManager.default.removeItem(at: extra)
    print("proven-screenshot-fixture-extra=removed count=1")
}

func path(_ arguments: [String], _ flag: String, count: Int) throws -> URL {
    guard arguments.count == count, let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
        throw RestoreError.invalidInput
    }
    return URL(fileURLWithPath: arguments[index + 1])
}

let arguments = Array(CommandLine.arguments.dropFirst())
do {
    switch arguments.first {
    case "snapshot-defaults" where arguments.count == 5 && arguments[1] == "--domain" && arguments[3] == "--output":
        try writeDefaultsSnapshot(domain: arguments[2], output: URL(fileURLWithPath: arguments[4]))
    case "restore-defaults" where arguments.count == 5 && arguments[1] == "--domain" && arguments[3] == "--input":
        try restoreDefaults(domain: arguments[2], input: URL(fileURLWithPath: arguments[4]))
    case "verify-defaults" where arguments.count == 5 && arguments[1] == "--domain" && arguments[3] == "--input":
        try verifyDefaults(domain: arguments[2], input: URL(fileURLWithPath: arguments[4]))
    case "restore-defaults-file" where arguments.count == 7:
        try restoreDefaultsFile(
            original: try path(arguments, "--original", count: 7),
            current: try path(arguments, "--current", count: 7),
            output: try path(arguments, "--output", count: 7)
        )
    case "verify-defaults-file" where arguments.count == 5:
        try verifyDefaultsFile(
            expected: try path(arguments, "--expected", count: 5),
            actual: try path(arguments, "--actual", count: 5)
        )
    case "write-manifest" where arguments.count == 5 && arguments[1] == "--root" && arguments[3] == "--output":
        try writeManifest(root: URL(fileURLWithPath: arguments[2]), output: URL(fileURLWithPath: arguments[4]))
    case "verify-backup-manifest" where arguments.count == 3 && arguments[1] == "--root":
        let root = URL(fileURLWithPath: arguments[2])
        try verifyManifest(root: root, group: root.appendingPathComponent("app-group"), label: "backup-group-manifest")
    case "verify-restored-group" where arguments.count == 5 && arguments[1] == "--root" && arguments[3] == "--group":
        try verifyManifest(root: URL(fileURLWithPath: arguments[2]), group: URL(fileURLWithPath: arguments[4]), label: "group-restore")
    case "validate-group" where arguments.count == 3 && arguments[1] == "--group":
        try validateGroup(URL(fileURLWithPath: arguments[2]))
    case "compare-groups" where arguments.count == 5 && arguments[1] == "--backup" && arguments[3] == "--live":
        try compareGroups(backup: URL(fileURLWithPath: arguments[2]), live: URL(fileURLWithPath: arguments[4]))
    case "remove-proven-fixture-extra" where arguments.count == 7 && arguments[1] == "--backup" && arguments[3] == "--live" && arguments[5] == "--fixture":
        try removeProvenFixtureExtra(
            backup: URL(fileURLWithPath: arguments[2]),
            live: URL(fileURLWithPath: arguments[4]),
            fixture: URL(fileURLWithPath: arguments[6])
        )
    default:
        throw RestoreError.invalidInput
    }
} catch {
    fputs("restore-helper failed: \(error)\n", stderr)
    exit(1)
}
