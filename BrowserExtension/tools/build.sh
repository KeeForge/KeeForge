#!/bin/bash
set -euo pipefail
extension_dir="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$extension_dir" <<'PY'
import json, pathlib, re, sys, zipfile
root = pathlib.Path(sys.argv[1])
versions = set(re.findall(r'MARKETING_VERSION:\s*"([0-9.]+)"', (root.parent / 'project.yml').read_text()))
if len(versions) != 1:
    raise SystemExit('Expected exactly one marketing version in project.yml')
manifest = json.loads((root / 'manifest.json').read_text())
manifest['version'] = versions.pop()
files = {'manifest.json': (json.dumps(manifest, indent=2) + '\n').encode()}
for path in sorted([*(root / 'src').rglob('*'), *(root / '_locales').rglob('*'), *(root / 'icons').rglob('*'), root / 'popup.html', root / 'pair.html', root / 'popup.css']):
    if path.is_file():
        files[path.relative_to(root).as_posix()] = path.read_bytes()
out = root / 'build'
out.mkdir(exist_ok=True)
for browser in ('chrome', 'firefox'):
    unpacked = out / browser
    # Only known shipped inputs are written; remove stale files from earlier builds.
    import shutil
    if unpacked.exists():
        shutil.rmtree(unpacked)
    unpacked.mkdir()
    with zipfile.ZipFile(out / (browser + '.zip'), 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name, data in sorted(files.items()):
            target = unpacked / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
            info = zipfile.ZipInfo(name, (1980, 1, 1, 0, 0, 0))
            info.create_system = 3
            info.external_attr = 0o100644 << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(info, data, compresslevel=9)
    print(out / (browser + '.zip'))
PY
