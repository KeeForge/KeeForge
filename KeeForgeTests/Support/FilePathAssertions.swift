import Foundation
import XCTest

/// Asserts two file URLs name the same file, comparing canonical paths.
///
/// A resolved bookmark reports `/private/var/...` while `FileManager`'s
/// temporary directory reports the `/var` symlink, so comparing `.path`
/// directly fails on an unsandboxed macOS build even though both URLs name one
/// file. (A sandboxed build hides this: its temporary directory lives inside
/// the app container, where no such symlink is involved.) Foundation
/// normalises toward `/var` — `resolvingSymlinksInPath()` strips a leading
/// `/private` when the file exists — so putting both sides through it is what
/// makes the comparison hold in either environment.
func XCTAssertEqualFilePaths(
    _ actual: URL?,
    _ expected: URL?,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(
        actual?.resolvingSymlinksInPath().path,
        expected?.resolvingSymlinksInPath().path,
        message(),
        file: file,
        line: line
    )
}
