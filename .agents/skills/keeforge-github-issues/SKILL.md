---
name: keeforge-github-issues
description: >
  Create, edit, comment on, close, reopen, classify, or change project fields for issues in
  KeeForge/KeeForge. Use whenever an action will mutate a KeeForge GitHub issue. Do not use for
  read-only issue searches or reviews that will not change GitHub state.
---

# KeeForge GitHub Issues

Apply this workflow before every GitHub issue mutation, including mutations requested as part of
another workflow. Keep the mutation within the user's authorized scope.

## Required preflight

1. Read the live README for [KeeForge project 1](https://github.com/orgs/KeeForge/projects/1/)
   in the current session. Do not rely on memory or a cached summary. Follow its current workflow
   and field guidance. If the README cannot be accessed, stop before mutating the issue and explain
   what is blocked.
2. Read the issue's current title, body, type, comments, state, and project fields when it already
   exists. For a new issue, check for likely duplicates before creating it.
3. Identify any source material that came from a private or external channel, such as email,
   in-app feedback, support conversations, private messages, logs, or attachments. Treat it as
   source context, not text to publish.

## Privacy and public wording

- Never put personally identifiable information from an external channel into an issue, comment,
  title, project field, or attachment. Omit names, email addresses, account identifiers, device
  identifiers, exact locations, and other details that could identify the reporter.
- Never quote an external user's message verbatim. Paraphrase the relevant behavior, impact, and
  reproduction details in neutral language, even when the original wording seems harmless.
- Include only the minimum diagnostic detail needed to understand or reproduce the issue. Inspect
  logs, screenshots, and attachments before publishing them; remove secrets and identifying data.
- Do not mention the external reporter or channel unless provenance is necessary. If it is, use a
  generic phrase such as "A user reported" without identifying the person.

## Classification

Set the GitHub issue type from the substance of the issue, not from a requested label, template,
or existing value that appears inaccurate:

- **Bug**: KeeForge behaves incorrectly, crashes, regresses, loses data, or violates intended
  behavior.
- **Feature**: the requested outcome adds or expands user-facing product capability.
- **Task**: internal engineering, maintenance, documentation, research, release, or operational
  work that is neither a product defect nor a user-facing capability request.

Use the repository's currently configured type values. If an issue contains materially separate
concerns, keep the primary type accurate and propose separate issues rather than forcing an
ambiguous classification.

## Project tracking

- Add every created or updated issue to
  [KeeForge project 1](https://github.com/orgs/KeeForge/projects/1/) unless the user explicitly says
  not to track that issue there. If an existing issue is missing from the project, add it as part
  of the requested update.
- Follow the live project README when choosing or changing fields and status.
- Whenever moving an issue to **Triaged**, set **Effort** to **Low**, **Medium**, or **High** in the
  same workflow. Use a reasonable qualitative estimate based on implementation scope, uncertainty,
  and validation cost. Never leave Effort unset on a newly Triaged item.

## Comments and replies

When replying to another user, write concise, friendly, natural prose. Address the question or
next step directly, avoid process-heavy boilerplate, and do not use em dashes. Paraphrase any
external source material under the privacy rules above.

## Mutate and verify

Use an available GitHub connector or authenticated GitHub tooling. Apply only the requested issue
changes plus the required type and project bookkeeping above. Afterward, read back the issue and
project item to verify the public text, issue type, state, project membership, status, and Effort.
Report the issue link and summarize the mutations. If a multi-step mutation only partially
succeeds, stop, disclose the partial state, and do not claim completion.
