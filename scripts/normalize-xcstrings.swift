#!/usr/bin/env swift
//
// Rewrite .xcstrings files in Xcode's canonical String Catalog format.
//
// Xcode's String Catalog editor reserializes `.xcstrings` files whenever the
// project is opened or built, using a distinctive style: space-padded ` : `
// separators, keys sorted with `localizedStandardCompare`, expanded empty
// objects (`{`, blank line, `}`), literal UTF-8, unescaped slashes, and no
// trailing newline. Tools and coding agents that edit these files as plain
// JSON write a different style and key order, so every round trip through
// Xcode produces a massive whitespace/reordering diff.
//
// Running this normalizer after any programmatic edit makes the committed file
// byte-identical to what Xcode would produce, so opening the project yields no
// spurious diff — only genuinely new or changed strings show up.
//
// It is written in Swift (not Python) on purpose: the key order depends on
// Foundation's `localizedStandardCompare`, which cannot be faithfully
// reproduced elsewhere. Using the same comparator Xcode uses guarantees a
// byte-identical result on this machine.
//
// Usage:
//   swift scripts/normalize-xcstrings.swift [--check] [FILE ...]
//
// With no FILE args, every tracked *.xcstrings in the repo is processed.
// --check writes nothing and exits non-zero if any file is not canonical.

import Foundation

/// Serialize a single JSON scalar exactly as Foundation would (literal UTF-8,
/// unescaped slashes), by round-tripping it through JSONSerialization.
func emitScalar(_ value: Any) -> String {
    let wrapped = try! JSONSerialization.data(withJSONObject: [value], options: [.withoutEscapingSlashes])
    var s = String(data: wrapped, encoding: .utf8)!
    s.removeFirst() // "["
    s.removeLast()  // "]"
    return s
}

func emit(_ value: Any, _ level: Int) -> String {
    let ind = String(repeating: "  ", count: level)
    let child = String(repeating: "  ", count: level + 1)

    if let dict = value as? [String: Any] {
        if dict.isEmpty { return "{\n\n" + ind + "}" }
        let keys = dict.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let parts = keys.map { key in
            child + emitScalar(key) + " : " + emit(dict[key]!, level + 1)
        }
        return "{\n" + parts.joined(separator: ",\n") + "\n" + ind + "}"
    }
    if let arr = value as? [Any] {
        if arr.isEmpty { return "[\n\n" + ind + "]" }
        let parts = arr.map { child + emit($0, level + 1) }
        return "[\n" + parts.joined(separator: ",\n") + "\n" + ind + "]"
    }
    return emitScalar(value)
}

func canonical(_ path: String) -> String {
    let data = try! Data(contentsOf: URL(fileURLWithPath: path))
    let obj = try! JSONSerialization.jsonObject(with: data)
    return emit(obj, 0) // Xcode writes no trailing newline.
}

func trackedXcstrings() -> [String] {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = ["git", "ls-files", "*.xcstrings"]
    let pipe = Pipe()
    p.standardOutput = pipe
    try! p.run()
    p.waitUntilExit()
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return out.split(separator: "\n").map(String.init)
}

var args = Array(CommandLine.arguments.dropFirst())
let check = args.contains("--check")
args.removeAll { $0.hasPrefix("--") }
let files = args.isEmpty ? trackedXcstrings() : args

var drifted: [String] = []
for path in files {
    let want = canonical(path)
    let have = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    if want == have { continue }
    drifted.append(path)
    if !check {
        try! want.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

if check {
    if !drifted.isEmpty {
        print("Not canonical (run: swift scripts/normalize-xcstrings.swift):")
        drifted.forEach { print("  \($0)") }
        exit(1)
    }
    exit(0)
}
drifted.forEach { print("normalized \($0)") }
