# Candidate soak

Shipping is the user's call. These are targets, not gates — but they are **always measured and
always reported**. Never summarize the soak as "looks fine"; give the four numbers and a
recommendation, then let the user decide.

Targets for the **current** build (a minor release; patches use 24h — see [Shortened soak](patch.md#shortened-soak)):

| Signal | Where to read it | Target |
| --- | --- | --- |
| Time since each App Store build reached external testers | platform distribution timestamps recorded in [artifact verification and beta distribution](candidate.md#verify-all-three-artifacts-assign-the-app-store-builds-and-distribute-when-approved) | 48h |
| Unique installs of each exact App Store build | App Store Connect → each platform's TestFlight | 5 |
| New crash signatures for each App Store build | TestFlight → Crashes, and Xcode Organizer | 0 |
| Open P0/P1 reports | TestFlight → Feedback, `feedback.keeforge.com` | none |

For the direct Mac artifact, record install success on clean Apple-silicon and Intel hardware/VMs,
launch/quarantine behavior, and the full Sparkle update cycle separately; it has no TestFlight
metrics.

For a first public direct release, local HTTPS fixtures prove only feed parsing, signature metadata,
and the staging/publish guards. They do not prove a public update cycle. Keep that result as pending
until a later real version can update an installed public asset; no fixed next version is required.
Shipping with that observation still pending is owner go-decision input, never an automatic waiver.

Report each App Store signal as **met** or **short**, with its actual value, and report direct Mac
install/update results separately. State plainly what is being accepted by shipping early.
"18h of a 48h target, 2 iOS installs, 1 Mac install, no crashes, one P2 open" is useful; "soak
complete" is not. Both App Store builds and the direct artifact must still be the same accepted RC.

Two habits keep this honest when the targets are relaxed:

- **A new build resets the clock.** Elapsed time and installs belong to one build; they do not
  carry over from the candidate it replaced. Report the current build's numbers, never the
  version's cumulative ones.
- **Record what was accepted.** When shipping short of target, note which signals were short in
  the `v{version}` tag message ([post-approval shipped tag](../../ship-release/SKILL.md#create-the-shipped-tag-after-review-approval-and-final-go)). This costs nothing and makes the pattern visible over several
  releases, which is the thing worth knowing.

Watch all three feedback channels: screenshot feedback, Send Beta Feedback text, and crash
reports — all under **TestFlight → Feedback** in App Store Connect.

Some candidates deserve a real hold regardless of the clock. Say so explicitly, and recommend
against shipping short, when the build touches `KDBXParser`, `KDBX3Parser`, `KDBXWriter`,
`KDBXXMLSerializer`, or the local/cloud save paths — a bad write reaches users' real vaults, and
the App Store rollback story is "ship another version."

When the user is satisfied, go to **[production shipping](../../ship-release/SKILL.md)**. Do not create `v{version}` until both platform
submissions have code approval and the final go decision.

**Stopping endpoint:** distributing beta candidates and staging an owner direct ZIP is a valid
handoff distinct from production ship. Leave the production tag, public GitHub release, Pages feed
deployment, legal declarations, and final go decision untouched until explicitly requested.
