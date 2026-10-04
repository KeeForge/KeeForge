# View structure and performance

- Inspect expensive computation in `body`, view initializers, and frequently evaluated collection expressions. Establish input size and frequency before claiming a performance defect. Prefer deriving data at the existing owner; a cache needs explicit invalidation and must respect secret lifetimes and lock cleanup.
- Extract a dedicated `View` when it narrows observation dependencies, preserves identity, or separates a substantial concern. Small private view helpers and related types in one file can remain when readable; line count and file count are not performance evidence.
- Look for unstable collection IDs, unnecessary type erasure, and conditional branches that recreate stateful platform views. KeeForge's `ForEach` plus `onMove` rule requires one concrete row type; retain its established modifier-based solution.
- Consider lazy stacks for genuinely large scroll collections. Keep view initialization cheap, but do not defer required initial state or duplicate an existing task merely to move code out of an initializer.
- Prefer modern formatting for user-visible values where behavior is equivalent. Preserve exact formats used by protocols, identifiers, database data, and tests. User-facing text changes must retain localization coverage.
- Distinguish SDK deprecation from stylistic modernization. Check the actual SDK declaration and both deployment targets before replacing APIs such as enumerated collection iteration, animation macros, tabs, or font scaling. Do not infer runtime availability from the compiler accepting syntax.
- Prefer current SwiftUI APIs when they preserve behavior: value-aware animation, supported `onChange` overloads, semantic foreground styles, and interpolation instead of concatenated `Text`. Verify the current call site's behavior before recommending a migration.
- Replace `GeometryReader` only when a supported layout API expresses the same sizing contract. Avoid substituting screen bounds for container geometry.
- Shared platform shims, extension target allow-lists, accessibility identifiers, and the compact/iPad/Mac shell split are maintained contracts. Consult their owners before simplifying an apparently redundant modifier or conditional.

Measure or demonstrate an observable consequence before assigning severity to a performance concern. API style suggestions alone should not dominate a review.
