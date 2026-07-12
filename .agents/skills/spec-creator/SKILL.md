---
name: spec-creator
description: >
  Turn a feature request into implementation-ready spec files for a coding agent.
  Use whenever the user wants to plan, scope, or write a spec for a feature about
  to be built: "write a spec for X", "plan feature Y", "how should we build Z",
  "draft an implementation plan". Produces a parent epic plus one file per
  independently-buildable slice. Prefer this skill when the audience is a coding
  agent, not an exec. Auto-applies the KeeForge overlay when the repo looks like
  KeeForge.
---

# Spec Creator

Turns a fuzzy feature request into spec files a coding agent can implement without guessing. Different from a PRD: the audience is an agent, the currency is technical precision, and each slice is small enough to compile and test on its own.

## Workflow

### 1. Restate the request

In one or two sentences, repeat back what you understood. Wait for confirmation. If the user's request is already detailed this is a sanity check; if it's terse ("add biometric unlock") this is where you catch a misread before it propagates.

### 2. Detect the repo

Read the top-level `AGENTS.md` / `CLAUDE.md` and skim the folder layout. Note language, frameworks, and any "stable core" or "do not touch" rules. **If the repo is KeeForge** (Swift 6 + SwiftUI + XcodeGen + `project.yml` + `AutoFillExtension`), also read `references/keeforge-overlay.md` and apply it on top of this workflow.

### 3. Clarify, adaptively

Pick the 3-6 questions that actually matter for this feature and ask them in one concise
message. A question is worth asking when all three are true: the answer changes what gets
built, a reasonable person could answer it more than one way, and the agent can't infer it
from the repo.

Pull from these categories; don't ask all of them, pick what fits:

- **Scope.** New feature, enhancement, or fix? What's explicitly out of scope? Phased rollout?
- **UX.** Entry point? Happy-path flow? Which states need explicit UI (empty, loading, error, offline)?
- **Data.** New persisted data or in-memory only? Where stored? Migration needed?
- **Security.** Touches secrets, new permissions, new network calls, biometric or device-owner checks?

If the user's answers raise more than two new questions, the feature isn't ready to spec;
say so and offer to scope it down instead of pushing through.

### 4. Research, only when warranted

Skip research unless the feature touches a platform API the repo hasn't used before, sits in
a domain with established conventions (passkeys, CryptoKit, KDBX, OAuth, etc.), or the user
asked for prior art. When warranted, browse primary sources (Apple docs, RFCs, named
open-source comparables) and capture short citable bullets, not prose. The KeeForge overlay
names preferred sources.

### 5. Decide whether to split

One epic with N slice files whenever:

- The work crosses more than two of {model, service, viewmodel, view, extension target, persistence}.
- There's a layering boundary where an earlier slice can compile and pass tests before the next one starts.
- A reviewer couldn't reasonably hold the whole change in their head.
- The feature has an obvious phased rollout (flag to opt-in to default).

LoC is a trigger to *check* the criteria above, not the rule itself. Each slice must be
**independently buildable and testable**. That is non-negotiable. A slice that only compiles
after the next one lands is half a slice.

### 6. Write the files

```
docs/specs/<YYYY-MM-DD>-<feature-kebab-case>/   (date = when the spec is written)
|-- epic.md
|-- 01-<slice>.md
|-- 02-<slice>.md
`-- ...
```

Even for a one-slice feature, create the directory and both files; uniform structure beats
saved bytes. Use `assets/epic-template.md` and `assets/slice-template.md`. If a section
genuinely doesn't apply, write `N/A - <reason>` rather than deleting it.

A good slice spec is typically 100-300 lines. If yours is longer, you're probably prescribing
implementation details the agent should handle; cut them. Rule of thumb: if you wrote a line
of code in the spec, ask whether an English sentence would have served equally well.

### 7. Self-check, then present

Before handing off, verify:

- Every slice is independently buildable and testable (read each in isolation).
- Every clarification answer is reflected somewhere in the specs.
- Every slice has a Testing section that names specific scenarios, not "add tests".
- The epic's slice list matches the files on disk, with dependencies marked.
- No slice prescribes signatures, variable names, or tiny algorithms.
- If an overlay applies, its checklist is satisfied.

Present the created files with clickable markdown file links and expect at least one round
of edits. That is the point.

## Templates and overlays

- `assets/epic-template.md` - parent epic scaffold
- `assets/slice-template.md` - per-slice scaffold
- `references/keeforge-overlay.md` - additive rules for KeeForge repos

## What this skill is not

- Not a PRD writer; use a product-spec workflow for exec/customer audiences.
- Not an ADR; use an architecture-decision workflow when the question is "which tech".
- Not a code generator; the skill stops at the spec.

## Failure modes

- **Over-specifying.** Spec reads like pseudocode; trim.
- **Under-clarifying.** Skipped step 3 because "it seemed clear"; go back.
- **Split-for-splitting's-sake.** Two slices that always land together; merge.
- **Testing-as-afterthought.** "Add unit tests" is a failure; rewrite.
