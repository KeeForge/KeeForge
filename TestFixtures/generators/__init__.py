"""Registry and driver for the pykeepass-authored KDBX fixtures.

Each module here registers one or more `Generator`s (name, output path,
`build(path)`, `verify(path, keepassxc_cli)`); `TestFixtures/generate_fixtures.py`
is the command-line front end. Shared plumbing -- header parsing, the Construct
`RawCopy` cache drop, the keepassxc-cli wrapper -- lives in `_common`.
"""

import sys
from pathlib import Path

from . import (
    argon2_high_iterations,
    foreign_ciphers,
    kitchen_sink,
    unknown_inner_header,
)
from ._common import Generator, banner, build_parser

MODULES = (
    kitchen_sink,
    argon2_high_iterations,
    foreign_ciphers,
    unknown_inner_header,
)

REGISTRY: dict[str, Generator] = {
    generator.name: generator for module in MODULES for generator in module.GENERATORS
}


def main(argv: list[str] | None = None) -> int:
    parser = build_parser(sorted(REGISTRY))
    args = parser.parse_args(argv)

    if args.list:
        for name in sorted(REGISTRY):
            print(f"{name}\t{REGISTRY[name].output_path}")
        return 0

    if args.all:
        selected = [REGISTRY[name] for name in sorted(REGISTRY)]
    elif args.names:
        unknown = [name for name in args.names if name not in REGISTRY]
        if unknown:
            parser.error(f"unknown fixture(s): {', '.join(unknown)}")
        selected = [REGISTRY[name] for name in args.names]
    else:
        parser.print_usage(sys.stderr)
        print("error: pass one or more fixture names, --all, or --list", file=sys.stderr)
        return 2

    output_dir = Path(args.output_dir).resolve() if args.output_dir else None
    if output_dir is not None and not args.check:
        output_dir.mkdir(parents=True, exist_ok=True)

    banner()

    failures = []
    for generator in selected:
        path = output_dir / generator.output_path.name if output_dir else generator.output_path
        try:
            if not args.check:
                generator.build(path)
            generator.verify(path, args.keepassxc_cli)
        except AssertionError as error:
            print(f"{generator.name}: FAILED: {error}", file=sys.stderr)
            failures.append(generator.name)

    if failures:
        print(f"{len(failures)} fixture(s) failed: {', '.join(failures)}", file=sys.stderr)
        return 1
    return 0
