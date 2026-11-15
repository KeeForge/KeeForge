# Components

Token names refer to [tokens.json](tokens.json). Native controls come first; the rest are KeeForge's own parts.

## GlassBarButton

The navigation and toolbar buttons: always the system's own Liquid Glass buttons, grouped into capsules by the system.

### Use
- Put actions in `ToolbarItem`s and let the system draw them. Related trailing actions (Lock, Sort, More) share one capsule.
- The confirming action (Save, Create, Done, Use) uses `.glassProminent`, which fills it with the tint and draws its label in `on-accent`.
- Cancel and Close stay plain glass on the leading side.
- Tint glyphs with the system tint (`accent` by default); a state glyph such as read-only uses `warning`.
- From iOS 26, Search and New sit in the bottom toolbar; Lock, Sort and More at the top.

### Don't
- Draw white circles, custom capsules or shadows to imitate glass.
- Put two lock glyphs in one bar: Lock Database owns `lock.fill`.

### The consumer provides
Toolbar items with SF Symbol labels or short Title Case text.

## GroupedList

Lists are the system inset-grouped `List`: a header in footnote `label-secondary`, rows on `card`, a footer under the section.

### Use
- Let the system set the 16pt inset, the rounded section corners and row heights.
- Align each row's divider with its text column (`.alignmentGuide(.listRowSeparatorLeading)` on the text stack), so it never runs under the icon.
- Footers are sentence case and short.
- Label/value rows use `LabeledContent`: the label in `label`, the value trailing in `label-secondary`.

### Don't
- Rebuild sections as custom cards or add shadows.

### The consumer provides
Sections of rows, optional header and footer text.

## DatabaseRow

A database in the Databases list: storage icon, name, file and source, and a status line.

### Use
- The icon is the storage source (iPhone, Dropbox, OneDrive, WebDAV, FTP) tinted with the tint on a `card-2` tile.
- Name in `row-title`; badges (Quick Launch, Read-Only) sit after the name and move to their own line when they do not fit.
- Second line: file name, then " · " and the cloud provider, in `subhead` `label-secondary`.
- Status line: "Last synced 5 minutes ago" or "Last opened 3 days ago" in `footnote` `label-secondary`, hidden when usage stats are off. Sync warnings show in `warning` with a glyph and always stay visible.
- Trailing system chevron.

### The consumer provides
Name, file name, source, badges, and an optional status line.

## EntryRow

An entry in any list: icon, title, username, optional folder path, and trailing badges. No chevron.

### Use
- `EntryIcon` at `size-entry-icon`, then `space-icon-text`, then the text stack with `space-text-line` gaps.
- Title in `row-title` `label` ("(untitled)" when empty); username in `subhead` `label-secondary`; folder path in `footnote` `label-secondary`, one line, truncated at the head, shown in collections and search.
- Trailing, in this order: an Expired `StatusBadge` (danger), then `RowBadge` circles for a passkey (`person.badge.key.fill`) and a verification code (`timer`).
- A row badge is a `caption-2` semibold glyph in the tint on a `size-badge` circle of `accent-soft`.
- Long-press opens the row menu: the copy actions (Username, Password, Verification Code), then Duplicate, Move to Group, Change Icon and Select Entries, then Delete, with a divider between the three groups and an icon on every item.

### The consumer provides
The entry, its resolved username, an optional custom icon and folder path.

## SummaryRow

A hub row in App Settings and Database Details: an icon, a title, and a line saying what is set behind it.

### Use
- A system `Label` with an SF Symbol in the tint; title in `body`; summary in `subhead` `label-secondary`, up to two lines (unlimited at accessibility sizes).
- Join facts with " · ": "Face ID · Locks after 1 minute", "AES-256 · Argon2d".
- When something needs attention, add a `warning` dot of `size-status-dot` at the trailing edge and say what it is in the summary; the dot never stands alone.
- System chevron; the row pushes the page behind it.

### The consumer provides
Title, SF Symbol name, summary text, and whether it needs attention.

## VerificationCodeRow

A verification code in the Codes list: the entry's header, then the live code with its countdown and copy button.

### Use
- Header: `EntryIcon`, title in `row-title`, username in `subhead`, and a tertiary chevron; tapping it opens the entry.
- Below it a `card-2` box with `radius-entry-icon` corners: the code in `code-large` in the tint, grouped in threes, then a countdown ring of `size-badge` with the seconds in `caption-2` `label-secondary`, then the copy button.
- The code changes with a numeric transition. VoiceOver reads it digit by digit and the ring as "24 seconds remaining".

### The consumer provides
The entry and its one-time password configuration.

## HomeTile

The four tiles at the top of a vault: All, Verification Codes, Tags and Recycle Bin, with their counts.

### Use
- Two columns `space-tile-gap` apart; one column at accessibility sizes.
- Each tile is a `card` (`card-raised` in the iPad sidebar) with `radius-card` continuous corners, padding `space-tile-y` by `space-tile-x`, at least `size-tile` tall.
- Top row: a `size-tile-circle` circle in its hue with a semibold `tile-glyph` glyph, and the count trailing in `tile-count` `label-secondary`. Title at the bottom in `row-title`.
- Hues: the tint for All (`key`), `tile-codes` for Verification Codes (`timer`), `tile-tags` for Tags (`tag`), `tile-trash` for Recycle Bin (`trash.fill`).
- The whole tile is one button; VoiceOver reads the title and the count.

### The consumer provides
The four counts and an action per tile.

## EntryIcon

An entry's icon: its custom icon, a downloaded website icon, a KeePass standard icon, or a monogram.

### Use
- Square with corners at 0.25 of the side, continuous: `size-entry-icon` (40) in rows, `size-entry-header-icon` (64) atop entry details.
- Custom icons and favicons sit inset by 0.15 of the side on `card-2`. Standard icons are a glyph on `card-2`.
- The default KeePass key icon becomes a monogram: up to two letters from the title in `monogram` (rounded bold, 0.38 of the side), `tile-glyph` on a top-to-bottom gradient of its tint darkened 25% at the bottom.
- The tint is picked from the title among `accent`, `tile-tags` and `tile-trash`, so a list does not read as one block. State colors are never used.
- Hidden from VoiceOver; the row's title speaks for it.

### The consumer provides
The entry (title, icon ID), optional custom icon data and favicon.

## StatusBadge

The uppercase pill beside a name: a database's state or an expired entry.

### Use
- `badge` type (caption2 bold, uppercased), one line, padding `space-badge-y` by `space-badge-x`, capsule.
- Tones: accent (Quick Launch, Read-Only) is the tint on `accent-soft`; warning is `warning` on `fill`; danger (Expired) is `danger` on `danger-soft`.
- Badges never wrap inside; when a name plus badges do not fit, the badges move to their own line.
- Pending uploads are a notice line, not a badge.

### The consumer provides
Short text (one or two words) and a tone.

## PasswordText

A revealed or generated password, colored character by character so it can be read aloud.

### Use
- Letters in `label`, digits in `digit`, symbols in `symbol`. Rows use `mono-body`; the generator's suggestion uses `password`, centered and wrapping.
- Hidden passwords show twelve bullets in `mono-body` `label-secondary`, whatever the real length.
- Not selectable: copying goes through KeeForge's copy button, which clears the clipboard after a while.
- VoiceOver reads the plain password, not the colors.

### The consumer provides
The password string.

## StrengthMeter

The password strength meter: four segments and a rating, used in entry details, the editor, New Database and the generator.

### Use
- Segments are `size-meter-segment-w` by `size-meter-segment-h` capsules, `space-meter-segment` apart; filled in the level's color, empty in `fill`.
- Levels: Very weak (1, `danger`), Weak (2, `warning`), Good (3, `success`), Very good (4, `success`).
- Three captions: "Strength" leading with the meter and rating trailing (entry details); meter then rating (generator); meter then "Password strength: Very good" (New Database, Change Master Key).
- The rating is semibold in the level's color; the word always appears, so color is never alone. When the caption does not fit on one line, it moves under the meter.
- VoiceOver reads "Password strength: Very good".

### The consumer provides
The password (or its estimate), and the caption style.

## FailureCard

The card shown above the unlock form when a password or key file is wrong, so the person can correct it and try again.

### Use
- Only for failures a retry can fix (wrong password, wrong key file). Other failures get a full page with their recovery actions.
- Padding `space-side` (plus 4 vertically); ground `danger-soft` for a wrong password or the warning tint at 14% otherwise; a 1pt border of the tint at 35%; `radius-card` corners.
- An SF Symbol in `title-2` and the tint, then the title in `title-3-bold`, the summary in `body`, and the error code in `error-code` `label-secondary`, `space-badge-gap` apart.
- A trailing ellipsis menu holds Send Feedback only.

### The consumer provides
The failure (title, summary, code, tone) and a feedback action.
