# KeeForge Design System

KeeForge's iOS design, written down so the Mac redesign (and any new screen) can reuse it. It describes the shipping iPhone and iPad UI. Where this folder and the code disagree, the code wins: `KeeForge/Views/Components/Theme.swift` and `KeeForge/Resources/Theme.xcassets` are the source of the tokens, and the views under `KeeForge/Views/` are the source of the components. Update this folder in the same change when either moves.

- [tokens.json](tokens.json): colors (light and dark, with usage and contrast notes), text styles, spacing, radii and sizes. Sizes are points at the default Dynamic Type size.
- [components.md](components.md): KeeForge's own parts and the native controls it relies on.
- The brand mark is the gold key in `KeeForge.icon/Assets/KeeForge-key-foreground.svg`.

KeeForge is a KeePass password manager for iPhone, iPad and Mac. Its look is native iOS: system bars, Liquid Glass buttons, inset-grouped lists and Dynamic Type, with a small set of its own tokens on top. Reach for the system control first and add a KeeForge token only where the system has no answer.

## Principles

- **Native first.** Use the system navigation bar, toolbar, glass buttons, search field, menus, alerts, sheets and inset-grouped `List`. Do not draw your own versions of them. KeeForge's own parts are the ones iOS has no equivalent for: home tiles, entry icons, badges, the strength meter, colored passwords and verification codes.
- **Name things by what people recognize.** "Database Details", "Recycle Bin", "Verification Codes", not internal names.
- **Secrets are calm.** Passwords stay hidden until asked for, with no decoration beyond the digit and symbol colors that help someone read one aloud.
- **Color never carries meaning alone.** Every state has a word (a badge, a notice line, a rating) beside its color.

## Content

- Title Case for buttons, menu items, screen and section titles: "Select Key File", "Change Master Key…", "Show All Credentials".
- Sentence case for footers, notices and messages: "The entry will be moved to the recycle bin."
- End a command that opens a further step with an ellipsis: "Export…", "Import Passwords…".
- Speak to the person as "you"; KeeForge refers to itself by name only when it must ("KeeForge creates KDBX 4 databases…").
- Say what happened and what to do next. Failure titles name the problem ("Wrong Password"), the summary says how to fix it.
- Join short facts with a middle dot: "Passwords.kdbx · Dropbox", "Face ID · Locks after 1 minute".
- No emoji. No exclamation marks.

## Color

- Tint with the system tint. The user can choose an accent, so `accent` is only the default; never paint a literal `accent` where `.tint` would follow their choice.
- Put `card` on `ground`; put `card-2` wells inside a `card`. On the iPad sidebar, cards use `card-raised`.
- Set primary text in `label` and everything secondary (usernames, file names, counts, summaries, footers) in `label-secondary`.
- Use `success`, `warning` and `danger` for state only, and always beside a word. Keep tile and monogram hues (`accent`, `tile-tags`, `tile-trash`) out of state.
- Use `danger-soft` behind `danger` content (the Expired badge, the failure card), and `accent-soft` behind tinted badges and row circles.
- Color passwords letter by letter: letters in `label`, digits in `digit`, symbols in `symbol`.
- Keep `brand-ink` and `brand-key` for the app icon, launch screen and covers. They never appear in UI chrome.
- Several real pairs miss 4.5:1 in light mode (`success`, `warning`, `digit`, `symbol` text on `card`, and white on `tile-codes` and `tile-trash`). Each token's usage note says where; keep them paired with a word or a larger size, and do not add new small text in those colors.

## Type

- Use Dynamic Type text styles, never fixed sizes. The sizes listed are the default (Large) size.
- `row-title` for names, `subhead` for the line under a name, `footnote` for folder paths and footers.
- Use `mono` for anything a person might type back: passwords (`password`, `mono-body`), verification codes (`code-large`, `code-row`) and error codes (`error-code`).
- Use `tile-count` with monospaced digits so counts line up.
- Uppercase only inside badges (`badge`).
- Let text wrap at accessibility sizes: rows stack their badges under the name, tiles go to one column, summaries drop their line limit.

## Layout

- Lists are the system inset-grouped `List`, so the system sets their 16pt side inset, rounded section corners and row heights. Do not restyle rows into custom cards.
- Divider lines start under a row's text column, not under its icon.
- Rows: icon, then `space-icon-text`, then a text stack with `space-text-line` between lines; badges trail at the right. Entry rows have no chevron; navigation rows (databases, groups, tags, settings) keep the system chevron.
- The vault root opens on four home tiles in two columns, `space-tile-gap` apart, then the top-level groups.
- Root screens use the system large title, level with the bar buttons (inline-large).
- From iOS 26, Search and New sit in the bottom toolbar; Lock, Sort and More sit at the top.

## Shape and depth

- `radius-card` with continuous corners for tiles and cards KeeForge draws itself. Entry icons round at a quarter of their side.
- No shadows of KeeForge's own. Depth comes from `card` on `ground` and from system glass.
- Borders only on the failure card: 1pt of its tint at 35% opacity.

## Iconography

- SF Symbols only, at the text style they sit beside. Outline glyphs, except where iOS fills them (`trash.fill` on the Recycle Bin tile, `lock.fill`, `person.badge.key.fill`).
- Collections: `key` All, `timer` Verification Codes, `tag` Tags, `trash.fill` Recycle Bin.
- Entry markers: `person.badge.key.fill` passkey, `timer` verification code.
- Read-only uses `eyeglasses` (never a lock, which already means Lock Database; never an eye, which means reveal).
- Key files use `key.horizontal`; regenerate uses `arrow.clockwise`.
- An entry with the default KeePass icon shows a monogram: one or two letters in `monogram` on a top-to-bottom gradient of its tint, darkened 25% at the bottom. The tint is picked from the title among `accent`, `tile-tags` and `tile-trash`.
- The brand mark is the gold key (ink `brand-key`) on `brand-ink`.

## Motion

- System transitions only. Codes change with a numeric content transition; favicons fade in. Nothing else animates.

## Bringing it to macOS

The Mac app today uses system colors and controls (`Theme.State` maps `success`, `warning` and `danger` to the system green, orange and red there). To redesign it from this system:

- Keep native first: the window toolbar, sidebar `List`, `Table`, `Form` with `.grouped` style, menus and sheets stay system controls. Do not port iOS bar buttons, the bottom toolbar or large titles.
- Bring over the tokens that have no Mac equivalent: `card`, `card-2`, `fill`, `label-secondary`, `success`, `warning`, `danger`, `danger-soft`, `digit`, `symbol` and the tile hues. Prefer the system accent on Mac unless the person chose one.
- Keep the parts: home tiles (in the sidebar or a collection's overview), entry icons with monograms, status badges, the strength meter, colored passwords, verification code rows and the failure card. They carry the brand across platforms.
- Use macOS text styles in place of iOS sizes: rows use `.body` names over `.callout`/`.subheadline` details, which is what the Mac row does today. Keep monospaced faces for secrets.
- Scale sizes to Mac density: entry icons 24–28pt in lists, controls at regular size, no 44pt touch targets.
- Keep hover and keyboard parity: every row action in a context menu also lives in the menu bar with a shortcut.
