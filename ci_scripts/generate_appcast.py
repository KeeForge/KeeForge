#!/usr/bin/env python3
"""Build a staged Sparkle appcast without publishing it.

The input item is the non-secret JSON emitted by build_mac_direct.sh. Existing
items are retained and the new item is inserted first. This intentionally uses
the standard library so fixture runs never need the Sparkle toolchain or a
network connection.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ATOM_NS = "http://www.w3.org/2005/Atom"
VERSION_RE = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$")
HEX_SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
ET.register_namespace("sparkle", SPARKLE_NS)
ET.register_namespace("atom", ATOM_NS)


def qname(namespace: str, name: str) -> str:
    return f"{{{namespace}}}{name}" if namespace else name


def text(parent: ET.Element, name: str, value: str, namespace: str = SPARKLE_NS) -> None:
    ET.SubElement(parent, qname(namespace, name)).text = value


def parse_attrs(raw: str) -> dict[str, str]:
    attrs = dict(re.findall(r'([\w:.-]+)="([^"\\]*(?:\\.[^"\\]*)*)"', raw))
    if not attrs.get("sparkle:edSignature"):
        raise ValueError("sparkle signature must include sparkle:edSignature and length")
    if "length" not in attrs and "sparkle:length" in attrs:
        attrs["length"] = attrs["sparkle:length"]
    if not attrs.get("length") or not re.fullmatch(r"[0-9]+", attrs["length"]):
        raise ValueError("sparkle signature must include sparkle:edSignature and length")
    return attrs


def load_root(path: Path) -> ET.Element:
    if not path.exists():
        rss = ET.Element("rss", {"version": "2.0"})
        channel = ET.SubElement(rss, "channel")
        ET.SubElement(channel, "title").text = "KeeForge for Mac"
        ET.SubElement(channel, "link").text = "https://keeforge.com"
        return rss
    return ET.parse(path).getroot()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifact-json", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--input", type=Path, help="Existing appcast; omitted means a new feed")
    args = parser.parse_args()

    artifact = json.loads(args.artifact_json.read_text(encoding="utf-8"))
    required = (
        "version",
        "repoBuild",
        "zipFilename",
        "sha256",
        "sizeBytes",
        "minimumSystemVersion",
        "sparkleSignature",
    )
    missing = [key for key in required if key not in artifact]
    if missing:
        raise ValueError(f"artifact JSON is missing: {', '.join(missing)}")
    version_value = artifact["version"]
    build_value = artifact["repoBuild"]
    size_value = artifact["sizeBytes"]
    sha_value = artifact["sha256"]
    if not isinstance(version_value, str) or not VERSION_RE.fullmatch(version_value):
        raise ValueError("version must be semver-like (MAJOR.MINOR.PATCH with an optional suffix)")
    if isinstance(build_value, bool) or not isinstance(build_value, int) or build_value <= 0:
        raise ValueError("repoBuild must be a positive integer")
    if isinstance(size_value, bool) or not isinstance(size_value, int) or size_value <= 0:
        raise ValueError("sizeBytes must be a positive integer")
    if not isinstance(sha_value, str) or not HEX_SHA256_RE.fullmatch(sha_value):
        raise ValueError("sha256 must be a 64-character lowercase SHA-256")
    version = version_value
    build = str(build_value)
    attrs = parse_attrs(str(artifact["sparkleSignature"]))
    if int(attrs["length"]) != size_value:
        raise ValueError("Sparkle signature length must equal sizeBytes")
    filename = str(artifact["zipFilename"])
    expected_filename = f"KeeForge-{version}-b{build}.zip"
    if filename != expected_filename:
        raise ValueError(f"zipFilename must be {expected_filename}")
    root = load_root(args.input) if args.input else load_root(Path("/nonexistent"))
    channel = root.find("channel")
    if channel is None:
        raise ValueError("appcast has no channel element")

    for item in channel.findall("item"):
        old_version = item.findtext(qname(SPARKLE_NS, "shortVersionString")) or item.findtext("title")
        old_build = item.findtext(qname(SPARKLE_NS, "version"))
        if old_version == version:
            raise ValueError(f"appcast already contains marketing version {version}")
        if old_build == build:
            raise ValueError(f"appcast already contains repo build {build}")

    item = ET.Element("item")
    text(item, "title", version, namespace="")
    text(item, "version", build)
    text(item, "shortVersionString", version)
    minimum = str(artifact["minimumSystemVersion"])
    if minimum:
        text(item, "minimumSystemVersion", minimum)
    text(item, "releaseNotesLink", "https://keeforge.com/changelog")
    enclosure = ET.SubElement(
        item,
        "enclosure",
        {
            "url": f"https://github.com/KeeForge/KeeForge/releases/download/v{version}/{filename}",
            "type": "application/octet-stream",
            qname(SPARKLE_NS, "edSignature"): attrs["sparkle:edSignature"],
            "length": attrs["length"],
        },
    )
    del enclosure  # the element is intentionally retained in item
    # Keep feed metadata (title/link/description) ahead of the item list.
    item_indexes = [index for index, child in enumerate(list(channel)) if child.tag == "item"]
    channel.insert(item_indexes[0] if item_indexes else len(channel), item)

    args.output.parent.mkdir(parents=True, exist_ok=True)
    ET.ElementTree(root).write(args.output, encoding="utf-8", xml_declaration=True)
    print(json.dumps({"appcastPath": str(args.output), "itemVersion": version, "itemBuild": int(build)}))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, ET.ParseError, json.JSONDecodeError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
