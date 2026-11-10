# KDBXXML fixtures

Decrypted payload XML of databases other implementations wrote, so the reader is checked against their output rather than against this package's writer. Each `<name>.xml` is the payload exactly as `KDBXContainer.read` returns it; `<name>.stream` holds the header's inner stream ID and key (hex) that mask its protected values.

| Fixture | Source database (`../../../../../TestFixtures/`) | Writer | Inner stream |
| --- | --- | --- | --- |
| `keepassxc-recycled` | `compatibility/keepassxc-recycled.kdbx` | KeePassXC, KDBX 4.1, pretty-printed | ChaCha20 |
| `kitchen-sink` | `kitchen-sink.kdbx` | pykeepass over a KeePassXC template, KDBX 4.1 | ChaCha20 |
| `legacy-kdbx31` | `compatibility/legacy-kdbx31.kdbx` | KeePassXC, KDBX 3.1, ISO 8601 dates | Salsa20 |

`TestFixtures/README.md` describes the databases' content. To regenerate after a source database changes, decrypt it with `KDBXContainer.read` and write `payload.xml` and `"\(header.innerStreamID) \(header.innerStreamKey hex)"`.
