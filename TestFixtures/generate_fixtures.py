#!/usr/bin/env python3
"""Author and verify the pykeepass-authored KDBX test fixtures.

    python3 TestFixtures/generate_fixtures.py --list
    python3 TestFixtures/generate_fixtures.py --all --check
    python3 TestFixtures/generate_fixtures.py kitchen-sink          # regenerate one
    python3 TestFixtures/generate_fixtures.py --all --check \\
        --keepassxc-cli /Applications/KeePassXC.app/Contents/MacOS/keepassxc-cli

`--check` verifies the fixtures on disk and never writes; without it each
selected fixture is rebuilt and then verified. `--output-dir DIR` builds and
verifies in DIR instead of the committed locations, for trying a regeneration
without touching the repo.

Regenerating always changes the file bytes (pykeepass randomizes the master
seed, IV, and KDF salt on every save) -- only the decoded content is
deterministic, and that is all the tests assert.

Requires pykeepass: pip3 install --user pykeepass

Each fixture's own module under `TestFixtures/generators/` documents why that
fixture exists and what it covers.
"""

from generators import main

if __name__ == "__main__":
    raise SystemExit(main())
