# RemoteFileTransports known answers

Expected values come from the specifications and from LIST lines real servers print, not from this package's output.

## Fixture files

| File | Source | Exercises |
| --- | --- | --- |
| `rfc4918-9.1.3-named-properties.xml` | RFC 4918 9.1.3, "Example - Retrieving Named Properties" (response to `PROPFIND /file`) | One response with a 200 and a 403 propstat; only the 200 block counts |
| `rfc4918-9.1.5-allprop.xml` | RFC 4918 9.1.5, "Example - Using So-called 'allprop'" (`PROPFIND /container/`, Depth 1) | Relative hrefs, the collection's own entry, `getetag`, `getcontentlength`, `getlastmodified` split across lines |
| `rfc4918-8.3.1-url-handling.xml` | RFC 4918 8.3.1, "Example - Correct URL Handling" (`PROPFIND /sample/`, Depth 1) | Absolute hrefs and the member `a%20test`, decoded once |

The XML was typed in from the RFC text: the hrefs, statuses, property names, and values are the RFC's, but the files are not byte copies. The 8.3.1 response carries only `resourcetype`, because that section is about hrefs, not properties. Check against https://www.rfc-editor.org/rfc/rfc4918 before editing.

## Inline vectors (`KnownAnswerTests.swift`)

| Source | Vectors |
| --- | --- |
| RFC 3659 2.3, "Times" | `time-val = 14DIGIT [ "." 1*DIGIT ]`; a "." with no digit after it is invalid |
| RFC 3659 3.4, "MDTM Examples" | `213 19980615100045.014`, `213 19980705132316`, `213 19990929003355`, `213 19991005213102`, `550 D is not retrievable` |
| RFC 3659 7.2 and 7.7.1, 7.7.2, 7.7.3, 7.7.5 | MLST fact lines (`Type=file;Size=1024990;Perm=r; /tmp/cap60.pl198.tar.gz`, `Type=dir;Modify=19981107085215;Perm=el; /tmp`, `Type=file;Modify=19990929003355.237; file1`), the MLSD `pdir` line, and the `250-` ... `250` framing |
| RFC 959 4.2, "FTP Replies" | The multi-line example `123-First line` / `Second line` / `  234 A line beginning with numbers` / `123 The last line` |
| RFC 959 4.2.2 and 5.2 | `227 Entering Passive Mode (h1,h2,h3,h4,p1,p2).` and the bare `A1,A2,A3,A4,a1,a2` form, with values filled in |
| RFC 2428 2 and 3, "The EPSV Command" | `Entering Extended Passive Mode (|||6446|)` and a non-`|` delimiter from the allowed 33-126 range |
| Apache Commons Net `UnixFTPEntryParserTest` and `NTFTPEntryParserTest` (Apache-2.0) | Unix `ls -l` lines (one or two owner columns, symlinks with and without a target, a group with a space, device types) and IIS/DOS lines (12- and 24-hour times, `<DIR>`, names with spaces), as collected there from real servers |

Unix lines typed `f`, `c`, or `b` are files to Commons Net; this client skips them, since it only opens regular files and folders.

Times in the expected values are seconds since 1970 in UTC, computed independently with Python's `calendar.timegm`.
