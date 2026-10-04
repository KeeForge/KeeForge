# Exhaustive subsystem campaigns

Use only when the requested scope calls for a complete subsystem inventory. This adds
coverage accounting and preservation review to the main skill, not permission to edit.

1. Pin the source revision and inventory every owned test, including cases located in
   shared suites, support, UI smoke, and script self-tests. Assign by production
   responsibility rather than filename prefix. Record available baseline execution
   evidence by target and destination; run the missing focused baseline before cleanup.
   If a required baseline cannot run, report the limit rather than treating it as green.
2. Use independent read-only agents for separable areas when available. Each reads its
   assigned tests and production paths and records each declaration as retain, repair,
   consolidate, or delete with evidence. Split table rows only when their disposition
   differs. Keep one owner for shared files and centralize all Xcode execution.
3. Review the inventory by contract. Name the retained suite for every guarantee and
   where any unique assertion must move. Account for platform, lifecycle, transport,
   storage, and independent-oracle distinctions before proposing an entire layer's
   removal. Resolve evidence gaps before that removal.
4. If authorized, apply coherent batches and validate retained coverage. Review deleted
   assertions against the retained tests independently of the implementation author;
   use separate reviewers for independent boundaries when useful. For a contract whose
   sensitivity is in doubt, introduce a narrow intentional fault in an isolated copy,
   confirm the retained test fails for that reason, and restore the source exactly.
   Record faults not exercised; do not claim mutation testing from inspection alone.
5. Keep discovered product defects separate from test cleanup. Repair them only within
   the user's authorized scope, with failing-control and passing-candidate evidence.
   Follow the repository's Git policy when incorporating newer work and reassess
   overlapping changes; ensure new regressions retain coverage after consolidation.
6. Reconcile the inventory and report unreviewed or unverified portions explicitly.
   Summarize preserved contracts, fixes, removed duplication/support, meaningful runtime
   evidence when available, and any unresolved findings. Test/support/production line
   counts are optional context, never a target or proof of successful preservation.
