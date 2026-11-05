#!/usr/bin/env python3
"""Compare tests.yml's runners, Xcodes and simulator runtimes with what GitHub's macOS images offer.

  images            newest stable `macos-N` and newest `xcode-N` arm64 labels, from the runner-images README
  probe LABEL       on that runner: default and installed Xcodes, and the iOS runtime each test device gets
  report DIR        compare the probes in DIR with tests.yml; exit 1 on drift
"""
import json
import os
import re
import subprocess
import sys
from pathlib import Path

TESTS_YML = Path(".github/workflows/tests.yml")
RC_YML = Path(".github/workflows/ios-rc-tests.yml")
MIN_MAC_XCODE = (26, 4)  # Xcode 26.3's actool crashes on KeeForge.icon for macOS.
PRERELEASE = re.compile(r"beta|release.?candidate|_rc\b", re.I)


def vkey(version):
    return [int(p) for p in re.findall(r"\d+", version)]


def run(*args, env=None):
    return subprocess.run(args, capture_output=True, text=True, env=env)


def test_devices():
    text = TESTS_YML.read_text() + RC_YML.read_text()
    names = re.findall(r"name: '([^']+)', slug:", text) + re.findall(r"name=([^,']+)", text)
    return list(dict.fromkeys(names))


def images(readme_path):
    stable, xcode = [], []
    for row in Path(readme_path).read_text().splitlines():
        cells = row.split("|")
        if len(cells) < 4 or cells[2].strip() != "arm64":
            continue
        labels = re.findall(r"`([^`]+)`", cells[3])
        flagged = re.search(r"deprecated|beta|preview", cells[1], re.I)
        for label in labels:
            if re.fullmatch(r"macos-\d+", label) and not flagged:
                stable.append(label)
            elif re.fullmatch(r"xcode-\d+", label):
                xcode.append(label)
    if not stable or not xcode:
        sys.exit("Could not find macos-N and xcode-N arm64 labels in the runner-images README.")
    print(json.dumps([max(stable, key=vkey), max(xcode, key=vkey)]))


def xcode_version(app):
    out = run("xcodebuild", "-version", env={**os.environ, "DEVELOPER_DIR": f"{app}/Contents/Developer"})
    match = re.match(r"Xcode (\S+)", out.stdout)
    return match.group(1) if match else None


def device_runtimes(app, devices):
    env = {**os.environ, "DEVELOPER_DIR": f"{app}/Contents/Developer"}
    try:
        types = json.loads(run("xcrun", "simctl", "list", "devicetypes", "--json", env=env).stdout)["devicetypes"]
        runtimes = json.loads(run("xcrun", "simctl", "list", "runtimes", "--json", env=env).stdout)["runtimes"]
    except (ValueError, KeyError):
        return {name: {"newest_supporting": None, "created": None} for name in devices}
    ios = sorted(
        (r for r in runtimes if r.get("isAvailable") and r["identifier"].startswith("com.apple.CoreSimulator.SimRuntime.iOS-")),
        key=lambda r: vkey(r["version"]),
        reverse=True,
    )
    result = {}
    for name in devices:
        type_ids = [t["identifier"] for t in types if t["name"] == name]
        supporting = [r for r in ios if type_ids and any(d.get("identifier") == type_ids[0] for d in r.get("supportedDeviceTypes", []))]
        created = None
        for r in supporting:
            made = run("xcrun", "simctl", "create", "ci-drift-probe", type_ids[0], r["identifier"], env=env)
            if made.returncode == 0:
                run("xcrun", "simctl", "delete", made.stdout.strip(), env=env)
                created = r["version"]
                break
        result[name] = {
            "newest_supporting": supporting[0]["version"] if supporting else None,
            "created": created,
        }
    return result


def probe(label):
    default_app = str(Path(run("xcode-select", "-p").stdout.strip()).parents[1])
    installed = {}
    for app in sorted(Path("/Applications").glob("Xcode*.app")):
        real = str(app.resolve())
        if real not in installed:
            installed[real] = {"version": xcode_version(real), "prerelease": bool(PRERELEASE.search(Path(real).name))}
    # The same pick as tests.yml's "Select Xcode" step.
    newest_sorted = run("bash", "-c", "ls -d /Applications/Xcode_*.app | sort -V | tail -1").stdout.strip()
    newest_sorted = str(Path(newest_sorted).resolve()) if newest_sorted else None
    stable = [a for a, x in installed.items() if x["version"] and not x["prerelease"]]
    newest_stable = max(stable, key=lambda a: vkey(installed[a]["version"])) if stable else None

    devices = test_devices()
    runtimes = {}
    for app in dict.fromkeys(a for a in (str(Path(default_app).resolve()), newest_sorted, newest_stable) if a):
        runtimes[app] = device_runtimes(app, devices)
    data = {
        "label": label,
        "image_version": os.environ.get("ImageVersion"),
        "default": str(Path(default_app).resolve()),
        "newest_sorted": newest_sorted,
        "newest_stable": newest_stable,
        "installed": installed,
        "runtimes": runtimes,
    }
    print(json.dumps(data, indent=2))


def report(probe_dir):
    tests = json.loads(run("yq", "-o=json", ".", str(TESTS_YML)).stdout)
    jobs = tests["jobs"]
    jobs["ios-rc-tests"] = json.loads(run("yq", "-o=json", ".", str(RC_YML)).stdout)["jobs"]["ios-rc-tests"]
    rc_devices = [d["name"] for d in jobs["ios-rc-tests"]["strategy"]["matrix"]["device"]]
    rc_devices += [i["device"]["name"] for i in jobs["ios-rc-tests"]["strategy"]["matrix"].get("include", [])]
    unit_device = re.search(r"name=([^,]+)", jobs["unit-tests"]["env"]["DESTINATION"]).group(1)

    probes = [json.loads(p.read_text()) for p in sorted(Path(probe_dir).glob("*/probe.json"))]
    mac = next(p for p in probes if p["label"].startswith("macos-"))
    xc = next(p for p in probes if p["label"].startswith("xcode-"))
    drift, lines = [], []

    def ver(p, app):
        return p["installed"].get(app, {}).get("version") if app else None

    for job in ("unit-tests", "macos-unit-tests"):
        if jobs[job]["runs-on"] != mac["label"]:
            drift.append(f"`{job}` runs on `{jobs[job]['runs-on']}`; the newest stable macOS image is `{mac['label']}`.")
    if jobs["ios-rc-tests"]["runs-on"] != xc["label"]:
        drift.append(f"`ios-rc-tests` runs on `{jobs['ios-rc-tests']['runs-on']}`; the newest Xcode image is `{xc['label']}`.")

    # unit-tests and macos-unit-tests take the highest Xcode_*.app by `sort -V`.
    picked = mac["newest_sorted"]
    if picked and mac["installed"][picked]["prerelease"]:
        drift.append(f"On `{mac['label']}` the Select Xcode step picks pre-release `{Path(picked).name}`; newest stable is {ver(mac, mac['newest_stable'])}.")
    if picked and vkey(ver(mac, picked) or "0") < list(MIN_MAC_XCODE):
        drift.append(f"On `{mac['label']}` the picked Xcode {ver(mac, picked)} is older than 26.4, which Mac builds need.")
    unit = mac["runtimes"].get(picked, {}).get(unit_device, {})
    if not unit.get("created"):
        drift.append(f"On `{mac['label']}` with Xcode {ver(mac, picked)}, no iOS runtime can create `{unit_device}` (unit-tests destination).")

    # ios-rc-tests uses the image default Xcode.
    if xc["newest_stable"] and xc["newest_stable"] != xc["default"]:
        drift.append(f"On `{xc['label']}` the default Xcode is {ver(xc, xc['default'])}, but stable {ver(xc, xc['newest_stable'])} is installed; `ios-rc-tests` should select it.")
    for name in rc_devices:
        got = xc["runtimes"].get(xc["default"], {}).get(name, {})
        if not got.get("created"):
            drift.append(f"On `{xc['label']}` with Xcode {ver(xc, xc['default'])}, no iOS runtime can create `{name}`.")

    lines.append("## CI drift report\n")
    lines.append("| Image | Image version | Default Xcode | Installed Xcodes |\n| --- | --- | --- | --- |")
    for p in (mac, xc):
        installed = ", ".join(
            f"{x['version']}{' (pre-release)' if x['prerelease'] else ''}"
            for x in sorted(p["installed"].values(), key=lambda x: vkey(x["version"] or "0"), reverse=True)
        )
        lines.append(f"| `{p['label']}` | {p['image_version']} | {ver(p, p['default'])} | {installed} |")
    lines.append("\n| Image | Xcode | Device | iOS runtime created | Newest runtime supporting it |\n| --- | --- | --- | --- | --- |")
    for p in (mac, xc):
        for app, devices in p["runtimes"].items():
            for name, r in devices.items():
                lines.append(f"| `{p['label']}` | {ver(p, app)} | {name} | {r['created'] or 'none'} | {r['newest_supporting'] or 'none'} |")
    lines.append("\n### Drift\n")
    lines += [f"- {d}" for d in drift] or ["None. `tests.yml` matches the newest stable images, Xcodes and runtimes."]

    text = "\n".join(lines) + "\n"
    print(text)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as f:
            f.write(text)
    for d in drift:
        print(f"::error::{d}")
    sys.exit(1 if drift else 0)


if __name__ == "__main__":
    command, arg = sys.argv[1], sys.argv[2]
    {"images": images, "probe": probe, "report": report}[command](arg)
