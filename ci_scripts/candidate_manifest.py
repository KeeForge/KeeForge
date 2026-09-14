#!/usr/bin/env python3
"""Initialize and validate the non-secret release candidate state record."""

from __future__ import annotations
import argparse, json, re, subprocess, sys
from datetime import datetime, timezone
from pathlib import Path

TARGETS = ("KeeForge", "KeeForgeAutoFill", "KeeForgeMac", "KeeForgeMacAutoFill")
RC_RE = re.compile(r"rc/([0-9]+\.[0-9]+\.[0-9]+(?:[.-][0-9A-Za-z.-]+)?)-b([1-9][0-9]*)$")

def fail(message: str) -> None: raise SystemExit(f"error: {message}")
def git(repo: Path, *args: str) -> str:
    result = subprocess.run(["git", "-C", str(repo), *args], text=True, capture_output=True)
    if result.returncode: fail(result.stderr.strip() or f"git {' '.join(args)} failed")
    return result.stdout.strip()

def target_versions(contents: str) -> tuple[str, int]:
    values: dict[str, dict[str, object]] = {name: {} for name in TARGETS}
    current: str | None = None
    for line in contents.splitlines():
        match = re.match(r"^  (KeeForge|KeeForgeAutoFill|KeeForgeMac|KeeForgeMacAutoFill):$", line)
        if match: current = match.group(1); continue
        if line.startswith("  ") and not line.startswith("    "): current = None
        if current and "CURRENT_PROJECT_VERSION:" in line:
            match = re.fullmatch(r'\s*CURRENT_PROJECT_VERSION:\s*"([0-9]+)"\s*', line)
            if not match: fail(f"{current} has malformed CURRENT_PROJECT_VERSION")
            if "build" in values[current]: fail(f"{current} has duplicate CURRENT_PROJECT_VERSION")
            values[current]["build"] = int(match.group(1))
        if current and "MARKETING_VERSION:" in line:
            match = re.fullmatch(r'\s*MARKETING_VERSION:\s*"([0-9]+\.[0-9]+\.[0-9]+(?:[.-][0-9A-Za-z.-]+)?)"\s*', line)
            if not match: fail(f"{current} has malformed MARKETING_VERSION")
            if "version" in values[current]: fail(f"{current} has duplicate MARKETING_VERSION")
            values[current]["version"] = match.group(1)
    if any(set(values[name]) != {"version", "build"} for name in TARGETS): fail("project.yml must have all four targets with exact version/build values")
    builds = {int(values[name]["build"]) for name in TARGETS}
    if len(builds) != 1: fail("project.yml targets do not share one CURRENT_PROJECT_VERSION")
    versions = {str(values[name]["version"]) for name in TARGETS}
    if len(versions) != 1: fail("project.yml targets do not share one MARKETING_VERSION")
    return versions.pop(), builds.pop()

def identity(repo: Path, tag: str) -> dict[str, object]:
    match = RC_RE.fullmatch(tag)
    if not match: fail("--rc-tag must be rc/{version}-b{repoBuild}")
    version, build = match.group(1), int(match.group(2))
    commit = git(repo, "rev-parse", f"{tag}^{{commit}}")
    tree = git(repo, "rev-parse", f"{tag}^{{tree}}")
    tagged_version, tagged_build = target_versions(git(repo, "show", f"{commit}:project.yml"))
    if (version, build) != (tagged_version, tagged_build): fail("RC tag identity disagrees with project.yml at its commit")
    return {"version": version, "repoBuild": build, "rcTag": tag, "commitSHA": commit, "sourceTree": tree, "directCFBundleVersion": build}

def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")

def init(args: argparse.Namespace) -> None:
    repo = Path(args.repo).resolve(); value = identity(repo, args.rc_tag)
    out = Path(args.manifest_dir) / f"{value['version']}-b{value['repoBuild']}.json"
    if out.exists(): fail(f"refusing to overwrite existing candidate manifest: {out}")
    value.update({"schemaVersion": 1, "createdAt": datetime.now(timezone.utc).isoformat(), "scope": "candidate", "artifacts": {}, "gates": {}, "iosTestFlightBuild": None, "macTestFlightBuild": None})
    write_json(out, value); print(out)

def evidence(gate: object, expected: dict[str, object]) -> bool:
    if not isinstance(gate, dict): return False
    if any(key in gate and gate[key] != expected[key] for key in ("commitSHA", "sourceTree")):
        return False
    if gate.get("status") == "adjudicated":
        return (
            gate.get("failureKind") == "xctest"
            and isinstance(gate.get("failedTests"), list) and bool(gate["failedTests"])
            and isinstance(gate.get("reproductions"), list) and bool(gate["reproductions"])
            and isinstance(gate.get("evidence"), dict) and bool(gate["evidence"])
        )
    return (
        gate.get("status") in ("accepted", "passed")
        and gate.get("verdict") == "passed"
        and not gate.get("failureKind")
        and bool(gate.get("log") or gate.get("url") or gate.get("resultBundle"))
    )

def soak_evidence(record: object, platform: str) -> bool:
    if not isinstance(record, dict) or record.get("verdict") not in ("accepted", "acceptedWithExceptions"):
        return False
    if not isinstance(record.get("evidence"), dict) or not record["evidence"]:
        return False
    if platform in ("iOS", "macOS"):
        metrics = ("distributionTimestamp", "uniqueInstalls", "newCrashSignatures", "openP0P1Reports")
    else:
        metrics = ("cleanAppleSiliconInstall", "cleanIntelInstall", "sparkleUpdateCycle")
    if any(record.get(metric) is None or record.get(metric) == "pending" for metric in metrics):
        return False
    return record["verdict"] == "accepted" or bool(record.get("ownerAcceptedExceptions"))

def validate(args: argparse.Namespace) -> None:
    path = Path(args.manifest)
    try: data = json.loads(path.read_text(encoding="utf-8"))
    except Exception as error: fail(f"cannot read manifest: {error}")
    if not isinstance(data, dict): fail("manifest root must be an object")
    if data.get("schemaVersion") != 1 or isinstance(data.get("schemaVersion"), bool): fail("unsupported or malformed schemaVersion")
    required = ("schemaVersion", "version", "repoBuild", "rcTag", "commitSHA", "sourceTree", "directCFBundleVersion")
    missing = [key for key in required if key not in data]
    if missing: fail("manifest missing identity fields: " + ", ".join(missing))
    expected = identity(Path(args.repo).resolve(), str(data["rcTag"]))
    drift = [key for key, value in expected.items() if key in data and data[key] != value]
    if drift: fail("manifest identity disagrees with RC tag: " + ", ".join(drift))
    if data.get("directCFBundleVersion") != data.get("repoBuild"): fail("directCFBundleVersion must equal repoBuild")
    gates = data.get("gates") if isinstance(data.get("gates"), dict) else {}
    required_gates = ("xcodeCloud", "githubIOS18", "githubMac", "kdbxIOS", "kdbxMac", "localMacSmoke", "masArtifact", "directArtifact")
    missing_evidence = [name for name in required_gates if not evidence(gates.get(name), expected)]
    if not data.get("iosTestFlightBuild"): missing_evidence.append("iosTestFlightBuild")
    if not data.get("macTestFlightBuild"): missing_evidence.append("macTestFlightBuild")
    artifacts = data.get("artifacts") if isinstance(data.get("artifacts"), dict) else {}
    direct = artifacts.get("direct")
    if not isinstance(direct, dict):
        missing_evidence.append("artifacts.direct")
    elif any(direct.get(key) != expected[key] for key in ("version", "repoBuild", "rcTag", "commitSHA", "sourceTree")):
        missing_evidence.append("artifacts.direct identity")
    if args.mode == "ship":
        production_go = data.get("productionGo")
        if not isinstance(production_go, dict) or production_go.get("approved") is not True or not production_go.get("evidence"):
            missing_evidence.append("productionGo")
        platforms = data.get("platforms") if isinstance(data.get("platforms"), dict) else {}
        for platform in ("iOS", "macOS"):
            review = platforms.get(platform, {}).get("appStoreReviewState") if isinstance(platforms.get(platform), dict) else None
            if review not in ("approved", "pendingDeveloperRelease", "readyForSale"):
                missing_evidence.append(f"platforms.{platform}.appStoreReviewState")
        soak = data.get("soak") if isinstance(data.get("soak"), dict) else {}
        missing_evidence += [f"soak.{platform}" for platform in ("iOS", "macOS", "direct") if not soak_evidence(soak.get(platform), platform)]
    if missing_evidence:
        print("missing release evidence: " + ", ".join(missing_evidence), file=sys.stderr)
        raise SystemExit(1)
    print(f"manifest {path} identity and {args.mode} evidence: pass")

def self_test(_: argparse.Namespace) -> None:
    import tempfile
    with tempfile.TemporaryDirectory(prefix="keeforge-candidate-manifest.") as root:
        repo = Path(root) / "repo"; repo.mkdir()
        subprocess.run(["git", "-C", str(repo), "init", "-q"], check=True)
        subprocess.run(["git", "-C", str(repo), "config", "user.email", "fixture@example.invalid"], check=True); subprocess.run(["git", "-C", str(repo), "config", "user.name", "fixture"], check=True)
        targets = "\n".join(
            f'  {name}:\n    settings:\n      base:\n        MARKETING_VERSION: "1.2.3"\n        CURRENT_PROJECT_VERSION: "9"'
            for name in TARGETS
        )
        (repo / "project.yml").write_text("targets:\n" + targets + "\n")
        subprocess.run(["git", "-C", str(repo), "add", "project.yml"], check=True); subprocess.run(["git", "-C", str(repo), "commit", "-qm", "fixture"], check=True); subprocess.run(["git", "-C", str(repo), "tag", "rc/1.2.3-b9"], check=True)
        manifests = repo / "scratch/release-manifests"
        init_args = argparse.Namespace(manifest_dir=str(manifests), repo=str(repo), rc_tag="rc/1.2.3-b9")
        init(init_args)
        validate_args = argparse.Namespace(manifest=str(manifests / "1.2.3-b9.json"), mode="distribute", repo=str(repo))
        try: validate(validate_args)
        except SystemExit:
            pass
        else: fail("self-test accepted pending/missing gates")
        data = json.loads(Path(validate_args.manifest).read_text())
        exact = identity(repo, "rc/1.2.3-b9")
        data.update({
            "iosTestFlightBuild": "101",
            "macTestFlightBuild": "102",
            "artifacts": {"direct": exact},
            "gates": {name: {"status": "accepted", "verdict": "passed", "log": "fixture.log"}
                      for name in ("xcodeCloud", "githubIOS18", "githubMac", "kdbxIOS", "kdbxMac", "localMacSmoke", "masArtifact", "directArtifact")},
        })
        Path(validate_args.manifest).write_text(json.dumps(data))
        validate(validate_args)
        data["gates"]["xcodeCloud"]["commitSHA"] = "0" * 40
        Path(validate_args.manifest).write_text(json.dumps(data))
        try: validate(validate_args)
        except SystemExit:
            pass
        else: fail("self-test accepted gate evidence for another candidate")
        data["gates"]["xcodeCloud"].pop("commitSHA")
        data["gates"]["xcodeCloud"] = {
            "status": "adjudicated", "failureKind": "infrastructure", "failedTests": ["Fixture/test"],
            "reproductions": ["fixture command"], "evidence": {"log": "fixture.log"},
        }
        Path(validate_args.manifest).write_text(json.dumps(data))
        try: validate(validate_args)
        except SystemExit:
            pass
        else: fail("self-test accepted non-XCTest adjudication")
        data["gates"]["xcodeCloud"] = {"status": "accepted", "verdict": "passed", "log": "fixture.log"}
        Path(validate_args.manifest).write_text(json.dumps(data))
        validate_args.mode = "ship"
        try: validate(validate_args)
        except SystemExit:
            pass
        else: fail("self-test accepted ship without production evidence")
        validate_args.mode = "distribute"
        data["schemaVersion"] = "1"
        Path(validate_args.manifest).write_text(json.dumps(data))
        try: validate(validate_args)
        except SystemExit:
            pass
        else: fail("self-test accepted malformed schemaVersion")
        broken = (repo / "project.yml").read_text().replace('MARKETING_VERSION: "1.2.3"', 'MARKETING_VERSION: "1.2.4"', 1)
        try: target_versions(broken)
        except SystemExit:
            pass
        else: fail("self-test accepted mismatched target marketing versions")
    print("self-test: immutable identity, schema, target mismatch, and pending-evidence refusal passed")

if len(sys.argv) == 2 and sys.argv[1] == "--self-test":
    self_test(argparse.Namespace())
    raise SystemExit(0)

parser = argparse.ArgumentParser()
sub = parser.add_subparsers(required=True)
for name, function in (("init", init), ("validate", validate)):
    item = sub.add_parser(name); item.add_argument("--repo", default=".")
    if name == "init": item.add_argument("--rc-tag", required=True); item.add_argument("--manifest-dir", default="scratch/release-manifests")
    else: item.add_argument("--manifest", required=True); item.add_argument("--mode", choices=("distribute", "ship"), required=True)
    item.set_defaults(function=function)
item = sub.add_parser("self-test"); item.set_defaults(function=self_test)
args = parser.parse_args(); args.function(args)
