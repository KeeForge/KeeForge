import XCTest

/// The rules in the package's `AGENTS.md` and the tests named after them
/// stay in step: every rule ID names a test, and every test ID is a rule.
final class SpecificationTests: XCTestCase {
    func testEveryRuleNamesATestAndEveryTestNamesARule() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let specification = testsDirectory.appendingPathComponent("../../AGENTS.md").standardizedFileURL
        let rules = ids(in: try String(contentsOf: specification, encoding: .utf8), matching: #/\*\*([A-Z][0-9]+) /#)
        XCTAssertGreaterThanOrEqual(rules.count, 20, "Rule IDs not found in \(specification.path)")

        var tested = Set<String>()
        let sources = try FileManager.default.contentsOfDirectory(at: testsDirectory, includingPropertiesForKeys: nil)
        for source in sources where source.pathExtension == "swift" {
            tested.formUnion(ids(in: try String(contentsOf: source, encoding: .utf8), matching: #/func test([A-Z][0-9]+)[A-Z]/#))
        }

        XCTAssertEqual(rules.subtracting(tested), [], "Rules without a test named after them")
        XCTAssertEqual(tested.subtracting(rules), [], "Tests named after a rule the specification does not have")
    }

    private func ids(in text: String, matching pattern: Regex<(Substring, Substring)>) -> Set<String> {
        Set(text.matches(of: pattern).map { String($0.output.1) })
    }
}
