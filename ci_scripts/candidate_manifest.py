#!/usr/bin/env python3
"""Initialize and validate the non-secret release candidate state record."""

from __future__ import annotations
import argparse, base64, binascii, hashlib, json, re, subprocess, sys
from datetime import datetime, timezone
from pathlib import Path

TARGETS = ("KeeForge", "KeeForgeAutoFill", "KeeForgeMac", "KeeForgeMacAutoFill")
RC_RE = re.compile(r"rc/([0-9]+\.[0-9]+\.[0-9]+(?:[.-][0-9A-Za-z.-]+)?)-b([1-9][0-9]*)$")
SHA256_RE = re.compile(r"[0-9a-f]{64}$")
BUILD_RE = re.compile(r"[1-9][0-9]*$")

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
    if any(gate.get(key) != expected[key] for key in ("commitSHA", "sourceTree")):
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

def exact_identity(record: object, expected: dict[str, object]) -> bool:
    return isinstance(record, dict) and all(record.get(key) == expected[key] for key in ("version", "repoBuild", "rcTag", "commitSHA", "sourceTree"))

def nonempty_string(value: object) -> bool:
    return isinstance(value, str) and bool(value)

def testflight_build(value: object) -> bool:
    return isinstance(value, str) and bool(BUILD_RE.fullmatch(value))

def direct_artifact_evidence(record: object, expected: dict[str, object]) -> list[str]:
    if not exact_identity(record, expected): return ["artifacts.direct identity"]
    assert isinstance(record, dict)
    failures: list[str] = []
    if record.get("schemaVersion") != 1 or isinstance(record.get("schemaVersion"), bool): failures.append("artifacts.direct schemaVersion")
    filename = record.get("zipFilename")
    expected_filename = f"KeeForge-{expected['version']}-b{expected['repoBuild']}.zip"
    if filename != expected_filename or not isinstance(filename, str) or Path(filename).name != filename:
        failures.append("artifacts.direct zipFilename")
    zip_path = record.get("zipPath")
    sha256 = record.get("sha256")
    size = record.get("sizeBytes")
    if not isinstance(sha256, str) or not SHA256_RE.fullmatch(sha256): failures.append("artifacts.direct sha256")
    if not isinstance(size, int) or isinstance(size, bool) or size <= 0: failures.append("artifacts.direct sizeBytes")
    if not isinstance(zip_path, str) or not zip_path:
        failures.append("artifacts.direct zipPath")
    else:
        zip_file = Path(zip_path)
        if not zip_file.is_file() or zip_file.is_symlink() or zip_file.name != filename:
            failures.append("artifacts.direct ZIP")
        elif isinstance(sha256, str) and SHA256_RE.fullmatch(sha256) and isinstance(size, int) and not isinstance(size, bool) and size > 0:
            if zip_file.stat().st_size != size or hashlib.sha256(zip_file.read_bytes()).hexdigest() != sha256:
                failures.append("artifacts.direct ZIP hash/size")
    if record.get("notarizationStatus") != "Accepted" or not nonempty_string(record.get("notarizationSubmissionID")):
        failures.append("artifacts.direct notarization")
    attributes = record.get("sparkleSignatureAttributes")
    signature = attributes.get("sparkle:edSignature") if isinstance(attributes, dict) else None
    length = attributes.get("length") if isinstance(attributes, dict) else None
    try:
        signature_bytes = base64.b64decode(signature, validate=True) if isinstance(signature, str) else b""
    except (ValueError, binascii.Error):
        signature_bytes = b""
    if len(signature_bytes) != 64:
        failures.append("artifacts.direct Sparkle Ed25519 signature")
    if not isinstance(size, int) or isinstance(size, bool) or length != str(size):
        failures.append("artifacts.direct Sparkle length")
    raw_signature = record.get("sparkleSignature")
    if not isinstance(raw_signature, str) or not isinstance(signature, str) or f'sparkle:edSignature="{signature}"' not in raw_signature or f'length="{length}"' not in raw_signature:
        failures.append("artifacts.direct Sparkle attributes")
    for key in ("appPath", "archivePath", "symbolsPath", "feedURL"):
        if not nonempty_string(record.get(key)): failures.append(f"artifacts.direct {key}")
    return failures

def app_store_artifact_evidence(
    artifacts: object,
    platforms: object,
    expected: dict[str, object],
    ios_build: object,
    mac_build: object,
) -> list[str]:
    if not isinstance(artifacts, dict) or not isinstance(platforms, dict):
        return ["artifacts/platforms"]
    ios = artifacts.get("ios")
    mas = artifacts.get("mas")
    ios_platform = platforms.get("iOS")
    mac_platform = platforms.get("macOS")
    failures: list[str] = []
    for name, record, platform, build in (("ios", ios, ios_platform, ios_build), ("mas", mas, mac_platform, mac_build)):
        if not exact_identity(record, expected):
            failures.append(f"artifacts.{name} identity")
            continue
        if not isinstance(platform, dict) or not testflight_build(build) or platform.get("build") != build:
            failures.append(f"platforms.{ 'iOS' if name == 'ios' else 'macOS' }.build")
        if record.get("testFlightBuild") != build:
            failures.append(f"artifacts.{name}.testFlightBuild")
        build_id = platform.get("buildID") if isinstance(platform, dict) else None
        if not nonempty_string(build_id) or record.get("buildID") != build_id:
            failures.append(f"artifacts.{name}.buildID")
    if isinstance(ios_platform, dict) and isinstance(mac_platform, dict):
        ios_id = ios_platform.get("buildID")
        mac_id = mac_platform.get("buildID")
        if nonempty_string(ios_id) and ios_id == mac_id:
            failures.append("platform buildID reuse")
    return failures

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
    ios_build = data.get("iosTestFlightBuild")
    mac_build = data.get("macTestFlightBuild")
    if not testflight_build(ios_build): missing_evidence.append("iosTestFlightBuild")
    if not testflight_build(mac_build): missing_evidence.append("macTestFlightBuild")
    artifacts = data.get("artifacts") if isinstance(data.get("artifacts"), dict) else {}
    direct = artifacts.get("direct")
    missing_evidence += app_store_artifact_evidence(artifacts, data.get("platforms"), expected, ios_build, mac_build)
    missing_evidence += direct_artifact_evidence(direct, expected)
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
        import copy
        data = json.loads(Path(validate_args.manifest).read_text())
        exact = identity(repo, "rc/1.2.3-b9")
        zip_path = repo / "direct" / "KeeForge-1.2.3-b9.zip"
        zip_path.parent.mkdir()
        zip_path.write_bytes(b"candidate manifest fixture zip\n")
        zip_size = zip_path.stat().st_size
        zip_sha = hashlib.sha256(zip_path.read_bytes()).hexdigest()
        signature = base64.b64encode(b"x" * 64).decode()
        direct = {
            **exact,
            "schemaVersion": 1,
            "zipPath": str(zip_path), "zipFilename": zip_path.name, "sha256": zip_sha, "sizeBytes": zip_size,
            "notarizationStatus": "Accepted", "notarizationSubmissionID": "fixture-submission",
            "sparkleSignature": f'sparkle:edSignature="{signature}" length="{zip_size}"',
            "sparkleSignatureAttributes": {"sparkle:edSignature": signature, "length": str(zip_size)},
            "appPath": "/fixture/KeeForge.app", "archivePath": "/fixture/KeeForge.xcarchive",
            "symbolsPath": "/fixture/KeeForge.xcarchive/dSYMs", "feedURL": "https://fixture.invalid/appcast.xml",
        }
        data.update({
            "iosTestFlightBuild": "101",
            "macTestFlightBuild": "101",
            "platforms": {
                "iOS": {"build": "101", "buildID": "ios-build-id"},
                "macOS": {"build": "101", "buildID": "mac-build-id"},
            },
            "artifacts": {
                "ios": {**exact, "testFlightBuild": "101", "buildID": "ios-build-id"},
                "mas": {**exact, "testFlightBuild": "101", "buildID": "mac-build-id"},
                "direct": direct,
            },
            "gates": {name: {**exact, "status": "accepted", "verdict": "passed", "log": "fixture.log"}
                      for name in ("xcodeCloud", "githubIOS18", "githubMac", "kdbxIOS", "kdbxMac", "localMacSmoke", "masArtifact", "directArtifact")},
        })
        def write(value: object) -> None:
            Path(validate_args.manifest).write_text(json.dumps(value))
        def expect_refusal(name: str, value: object) -> None:
            write(value)
            try: validate(validate_args)
            except SystemExit: print(f"self-test fixture rejected: {name}")
            else: fail(f"self-test accepted {name}")
        write(data)
        validate(validate_args)
        missing_gate_identity = copy.deepcopy(data)
        missing_gate_identity["gates"]["xcodeCloud"].pop("sourceTree")
        expect_refusal("passed gate without source tree", missing_gate_identity)
        wrong_gate_sha = copy.deepcopy(data)
        wrong_gate_sha["gates"]["xcodeCloud"]["commitSHA"] = "0" * 40
        expect_refusal("gate evidence for another candidate", wrong_gate_sha)
        adjudication_without_identity = copy.deepcopy(data)
        adjudication_without_identity["gates"]["xcodeCloud"] = {
            "status": "adjudicated", "failureKind": "xctest", "failedTests": ["Fixture/test"],
            "reproductions": ["fixture command"], "evidence": {"log": "fixture.log"},
            "commitSHA": exact["commitSHA"],
        }
        expect_refusal("adjudicated gate without source tree", adjudication_without_identity)
        non_xctest_adjudication = copy.deepcopy(data)
        non_xctest_adjudication["gates"]["xcodeCloud"] = {
            **exact, "status": "adjudicated", "failureKind": "infrastructure",
            "failedTests": ["Fixture/test"], "reproductions": ["fixture command"],
            "evidence": {"log": "fixture.log"},
        }
        expect_refusal("non-XCTest adjudication", non_xctest_adjudication)
        missing_artifact_identity = copy.deepcopy(data)
        missing_artifact_identity["artifacts"]["mas"].pop("sourceTree")
        expect_refusal("MAS artifact without source tree", missing_artifact_identity)
        swapped_build_ids = copy.deepcopy(data)
        swapped_build_ids["artifacts"]["ios"]["buildID"] = "mac-build-id"
        expect_refusal("swapped artifact buildID with equal TestFlight build", swapped_build_ids)
        reused_platform_build_id = copy.deepcopy(data)
        reused_platform_build_id["platforms"]["macOS"]["buildID"] = "ios-build-id"
        reused_platform_build_id["artifacts"]["mas"]["buildID"] = "ios-build-id"
        expect_refusal("cross-platform platform buildID reuse", reused_platform_build_id)
        skeleton_direct = copy.deepcopy(data)
        skeleton_direct["artifacts"]["direct"] = exact
        expect_refusal("skeleton direct artifact", skeleton_direct)
        boolean_direct_schema = copy.deepcopy(data)
        boolean_direct_schema["artifacts"]["direct"]["schemaVersion"] = True
        expect_refusal("boolean direct artifact schemaVersion", boolean_direct_schema)
        wrong_zip_hash = copy.deepcopy(data)
        wrong_zip_hash["artifacts"]["direct"]["sha256"] = "0" * 64
        expect_refusal("wrong direct ZIP hash", wrong_zip_hash)
        wrong_zip_size = copy.deepcopy(data)
        wrong_zip_size["artifacts"]["direct"]["sizeBytes"] = zip_size + 1
        wrong_zip_size["artifacts"]["direct"]["sparkleSignatureAttributes"]["length"] = str(zip_size + 1)
        wrong_zip_size["artifacts"]["direct"]["sparkleSignature"] = f'sparkle:edSignature="{signature}" length="{zip_size + 1}"'
        expect_refusal("wrong direct ZIP size", wrong_zip_size)
        wrong_zip_length = copy.deepcopy(data)
        wrong_zip_length["artifacts"]["direct"]["sparkleSignatureAttributes"]["length"] = str(zip_size + 1)
        wrong_zip_length["artifacts"]["direct"]["sparkleSignature"] = f'sparkle:edSignature="{signature}" length="{zip_size + 1}"'
        expect_refusal("wrong direct Sparkle length", wrong_zip_length)
        invalid_signature = copy.deepcopy(data)
        invalid_signature["artifacts"]["direct"]["sparkleSignatureAttributes"]["sparkle:edSignature"] = "not-base64"
        invalid_signature["artifacts"]["direct"]["sparkleSignature"] = f'sparkle:edSignature="not-base64" length="{zip_size}"'
        expect_refusal("invalid direct Sparkle signature", invalid_signature)
        missing_signature = copy.deepcopy(data)
        missing_signature["artifacts"]["direct"]["sparkleSignatureAttributes"] = {}
        expect_refusal("missing direct Sparkle attributes", missing_signature)
        write(data)
        validate_args.mode = "ship"
        try: validate(validate_args)
        except SystemExit:
            pass
        else: fail("self-test accepted ship without production evidence")
        validate_args.mode = "distribute"
        malformed_schema = copy.deepcopy(data)
        malformed_schema["schemaVersion"] = "1"
        expect_refusal("malformed schemaVersion", malformed_schema)
        broken = (repo / "project.yml").read_text().replace('MARKETING_VERSION: "1.2.3"', 'MARKETING_VERSION: "1.2.4"', 1)
        try: target_versions(broken)
        except SystemExit:
            pass
        else: fail("self-test accepted mismatched target marketing versions")
    print("self-test: immutable identity, artifact bindings, direct ZIP metadata, schema, target mismatch, and pending-evidence refusal passed")

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
