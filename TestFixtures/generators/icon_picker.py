"""`icon-picker.kdbx` -- the custom-icon fixture the entry icon picker UI tests need.

No other bundled fixture carries a `Meta/CustomIcons` image, so the picker's
custom-icon grid had no fixture-backed content to assert against. This authors a
small KDBX4 / AES-256 database (same recipe as `tag-browser.kdbx`) with exactly
one custom icon whose UUID the UI tests hardcode:

* `Icons/Custom Badge` displays that custom icon (`<CustomIconUUID>` set) and
  carries a public URL, so "Download Website Icon" is offered enabled;
* `Icons/Plain Entry` uses a standard icon and has no URL, so the download
  action renders disabled.

pykeepass exposes no custom-icon API, so the icon and the entry's
`<CustomIconUUID>` are written straight into the XML tree; both are plain
base64 text elements the format defines.
"""

import base64
import struct
import uuid
import zlib
from pathlib import Path

from lxml import etree

from ._common import Generator, fixture_path, new_database, pykeepass

PASSWORD = "testpassword123"

# Hardcoded in KeeForgeUITests (accessibility identifier
# `entry-icon-picker.custom.<uppercase uuidString>`); change both together.
CUSTOM_ICON_UUID = uuid.UUID("4D9C2B1E-7A35-4E68-9B0D-52F16C8A3E77")


def make_png() -> bytes:
    """A deterministic 8x8 solid-color RGB PNG, small but decodable by UIImage."""

    def chunk(tag: bytes, data: bytes) -> bytes:
        return (
            struct.pack(">I", len(data))
            + tag
            + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
        )

    width = height = 8
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    raw = b"".join(b"\x00" + b"\xe2\x4a\x33" * width for _ in range(height))
    idat = zlib.compress(raw, 9)
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", ihdr)
        + chunk(b"IDAT", idat)
        + chunk(b"IEND", b"")
    )


PNG_DATA = make_png()
UUID_B64 = base64.b64encode(CUSTOM_ICON_UUID.bytes).decode()


def build(path: Path) -> None:
    kp = new_database(path, PASSWORD)

    group = kp.add_group(kp.root_group, "Icons")
    custom_entry = kp.add_entry(
        group,
        "Custom Badge",
        "icon-custom-user",
        "IconCustomSecret1",
        url="https://icons-fixture.example.com",
    )
    kp.add_entry(group, "Plain Entry", "icon-plain-user", "IconPlainSecret2")

    meta = kp.tree.find("Meta")
    icons = etree.SubElement(meta, "CustomIcons")
    icon = etree.SubElement(icons, "Icon")
    etree.SubElement(icon, "UUID").text = UUID_B64
    etree.SubElement(icon, "Data").text = base64.b64encode(PNG_DATA).decode()

    etree.SubElement(custom_entry._element, "CustomIconUUID").text = UUID_B64

    kp.save()


def verify(path: Path, keepassxc_cli: str | None) -> None:
    kp = pykeepass.PyKeePass(str(path), password=PASSWORD)
    if kp.version[0] != 4:
        raise AssertionError(f"{path.name}: expected KDBX 4.x, got {kp.version}")

    icons = kp.tree.findall("Meta/CustomIcons/Icon")
    if len(icons) != 1:
        raise AssertionError(f"{path.name}: expected 1 custom icon, found {len(icons)}")
    if icons[0].findtext("UUID") != UUID_B64:
        raise AssertionError(f"{path.name}: custom icon UUID drifted")
    if base64.b64decode(icons[0].findtext("Data")) != PNG_DATA:
        raise AssertionError(f"{path.name}: custom icon image bytes drifted")

    custom_entry = kp.find_entries(title="Custom Badge", first=True)
    if custom_entry is None:
        raise AssertionError(f"{path.name}: 'Custom Badge' entry missing")
    if custom_entry._element.findtext("CustomIconUUID") != UUID_B64:
        raise AssertionError(f"{path.name}: 'Custom Badge' does not reference the custom icon")
    if custom_entry.url != "https://icons-fixture.example.com":
        raise AssertionError(f"{path.name}: 'Custom Badge' URL drifted: {custom_entry.url!r}")

    plain_entry = kp.find_entries(title="Plain Entry", first=True)
    if plain_entry is None:
        raise AssertionError(f"{path.name}: 'Plain Entry' entry missing")
    if plain_entry._element.findtext("CustomIconUUID") is not None:
        raise AssertionError(f"{path.name}: 'Plain Entry' must not use a custom icon")
    if plain_entry.url:
        raise AssertionError(f"{path.name}: 'Plain Entry' must have no URL, got {plain_entry.url!r}")

    print(
        f"{path.name}: KDBX {kp.version[0]}.{kp.version[1]}, "
        f"cipher={kp.encryption_algorithm}, custom icon {CUSTOM_ICON_UUID} "
        f"({len(PNG_DATA)}-byte PNG) on 'Custom Badge'"
    )


GENERATORS = [
    Generator(
        name="icon-picker",
        output_path=fixture_path("icon-picker.kdbx"),
        build=build,
        verify=verify,
    )
]
