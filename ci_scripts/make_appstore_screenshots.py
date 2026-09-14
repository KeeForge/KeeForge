#!/usr/bin/env python3
"""Generate polished App Store screenshots from raw UI-test captures.

Two listings, two platforms, one entry point:

    ci_scripts/make_appstore_screenshots.py            # iPhone (default)
    ci_scripts/make_appstore_screenshots.py --platform mac [--input-dir DIR] [--output-dir DIR]

The iPhone listing puts a tagline over a coloured gradient. The Mac listing uses the
light design in mac_screenshot_design.py and writes seven numbered story images plus
layout-report.json.

Prerequisite (not automated by this script): capture the raw screenshots with
the opt-in UI test class for that platform and export its attachments into the
platform's input directory.

iPhone -- `KeeForgeUITests/AppStoreScreenshots` into `build/screenshots`:

    TEST_RUNNER_APPSTORE_SCREENSHOTS=1 xcodebuild test -project KeeForge.xcodeproj \\
        -scheme KeeForge -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \\
        -only-testing:KeeForgeUITests/AppStoreScreenshots
    xcrun xcresulttool export attachments --path <xcresult> --output-path build/screenshots

Mac -- `KeeForgeMacUITests/MacScreenshotAuditUITests` into `build/screenshots-mac`:

    TEST_RUNNER_SCREENSHOT_AUDIT=1 xcodebuild test -project KeeForge.xcodeproj \\
        -scheme KeeForgeMac -destination 'platform=macOS,arch=arm64' \\
        -only-testing:KeeForgeMacUITests/MacScreenshotAuditUITests
    xcrun xcresulttool export attachments --path <xcresult> --output-path build/screenshots-mac

The export can be used as-is. xcresulttool writes UUID-named files plus a
manifest.json index; when that index is present, each expected screen is found
through its `suggestedHumanReadableName` (`01-database-list_0_<UUID>.png`).
Plainly named files (`01-database-list.png`) also work. `--input-dir` overrides
the platform's default input directory.

Both classes skip by default (see their doc comments), and both gate variables
must be real environment variables on the xcodebuild process -- Xcode strips the
TEST_RUNNER_ prefix and forwards them into the test runner, whereas a trailing
bare KEY=value argument becomes a build-setting override that never arrives and
the class silently skips. Without them this script has nothing to composite.

The Mac audit harness additionally needs Screen Recording permission for
`KeeForgeMacUITests-Runner`, and reports anything it could not capture in its
`00-skipped-captures` attachment (see KeeForgeMacUITests/AGENTS.md). A short
export is a harness problem, not a missing screen, so the Mac listing refuses to
write anything when that evidence is present or any screen is missing or
ambiguous. The iPhone listing still warns and composites what it has.

`--self-test` checks input resolution and Mac layout against disposable fixtures.
"""

import argparse
import hashlib
import json
import re
import sys
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

import mac_screenshot_design


REPO_ROOT = Path(__file__).resolve().parents[1]

# App Store accepts 1280x800, 1440x900, 2560x1600 and 2880x1800 for the Mac
# listing; 2880x1800 is the largest and downscales cleanly to the rest.
PLATFORMS = {
    "iphone": {
        # App Store 6.9" display size (iPhone 15/16 Pro Max)
        "canvas": (1320, 2868),
        "input_dir": REPO_ROOT / "build" / "screenshots",
        "output_dir": REPO_ROOT / "build" / "appstore",
        "corner_radius": 44,
        "font_size": 88,
        "strict": False,
        "screens": [
            ("01-database-list.png", "Local + Cloud Vaults,\nOne Home Screen", (26, 31, 61), (18, 22, 48)),
            ("02-unlock-screen.png", "Unlock Fast,\nStay Secure", (41, 98, 255), (30, 70, 220)),
            ("03-vault-groups.png", "Organize Everything\nin One Place", (0, 150, 136), (0, 110, 100)),
            ("04-database-settings.png", "Tune Each Vault\nYour Way", (31, 94, 58), (20, 63, 38)),
            ("05-entry-list.png", "All Your Accounts,\nAlways Accessible", (130, 80, 220), (90, 40, 180)),
            ("06-entry-detail.png", "Reveal Passwords,\nCopy What You Need", (220, 80, 60), (180, 40, 30)),
            ("07-entry-edit.png", "Create and Edit\nEntries on iPhone", (60, 60, 60), (30, 30, 30)),
            ("08-search.png", "Search Your Vault\nin Seconds", (30, 130, 230), (20, 90, 190)),
        ],
    },
    "mac": {
        "canvas": mac_screenshot_design.CANVAS,
        "input_dir": REPO_ROOT / "build" / "screenshots-mac",
        "output_dir": REPO_ROOT / "build" / "appstore-mac",
        # A partial Mac set is never a listing: missing screens and skipped
        # captures fail the run instead of warning.
        "strict": True,
        # (MacScreenshotAuditUITests attachment, listing file, headline, subhead), in
        # listing order. Audit captures not named here are audit-only.
        "screens": [
            ("05-entry-detail.png", "01-native-mac.png",
             "Your passwords. At home on Mac.", "A native KeePass manager. Your vaults stay yours."),
            ("04-group-selected.png", "02-organize.png",
             "A place for every account.", "Keep your passwords organized in groups."),
            ("06-search.png", "03-search.png",
             "Find it. Get on with your day.", "Search every entry in your vault from one place."),
            ("08-entry-editor-sheet.png", "04-create.png",
             "Good passwords start here.", "Create and edit entries with built-in password generation."),
            ("02-unlock.png", "05-unlock.png",
             "Your vault. Your key.", "Unlock with your master password and an optional key file."),
            ("01-database-list.png", "06-your-files.png",
             "Your files. Your vaults.", "Open KeePass databases you already keep, locally or over WebDAV."),
            ("07a-settings-security.png", "07-privacy.png",
             "Privacy, down to the details.", "Automatic locking. Clipboard clearing. You choose the limits."),
        ],
    },
}


SKIPPED_CAPTURES_STEM = "00-skipped-captures"
IMAGE_SUFFIXES = {".png", ".jpg", ".jpeg", ".heic", ".tiff"}
EXPORT_SUFFIX = re.compile(r"_\d+_[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$")


class InputError(Exception):
    pass


def attachment_stem(name):
    """Strips the extension and xcresulttool's `_<index>_<UUID>` export suffix."""
    return EXPORT_SUFFIX.sub("", Path(name).stem)


def indexed_inputs(input_dir):
    """Maps attachment stem -> {path: suffix}, through manifest.json when present."""
    index = {}
    manifest_path = input_dir / "manifest.json"
    if manifest_path.exists():
        try:
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as error:
            raise InputError(f"unreadable {manifest_path}: {error}") from error
        if not isinstance(manifest, list):
            raise InputError(f"{manifest_path} is not an xcresulttool attachment manifest")
        for record in manifest:
            for attachment in record.get("attachments", []) if isinstance(record, dict) else []:
                suggested = attachment.get("suggestedHumanReadableName", "")
                exported = attachment.get("exportedFileName", "")
                if not suggested or not exported:
                    continue
                path = input_dir / exported
                if not path.is_file():
                    raise InputError(f"manifest lists {exported} ({suggested}) but the file is missing")
                index.setdefault(attachment_stem(suggested), {})[path] = Path(suggested).suffix
    if input_dir.is_dir():
        for path in input_dir.iterdir():
            if path.is_file() and path.name != "manifest.json" and all(path not in paths for paths in index.values()):
                index.setdefault(attachment_stem(path.name), {})[path] = path.suffix
    return index


def resolve_inputs(input_dir, filenames, strict):
    """Returns ({filename: path}, [problems]) for the screens a listing needs."""
    index = indexed_inputs(input_dir)
    problems = []
    if strict and SKIPPED_CAPTURES_STEM in index:
        problems.append(
            f"{SKIPPED_CAPTURES_STEM} is present: the capture run skipped screens "
            "(see KeeForgeMacUITests/AGENTS.md); fix the harness and re-export"
        )
    resolved = {}
    for filename in filenames:
        candidates = index.get(Path(filename).stem, {})
        images = sorted(path for path, suffix in candidates.items() if suffix.lower() in IMAGE_SUFFIXES)
        if len(images) == 1:
            resolved[filename] = images[0]
        elif images:
            names = ", ".join(path.name for path in images)
            problems.append(f"{filename} is ambiguous ({len(images)} captures: {names}); export a single run")
        else:
            problems.append(f"{filename} is missing")
    return resolved, problems


def make_gradient(width, height, color_top, color_bottom):
    """Create a vertical gradient image."""
    img = Image.new("RGB", (width, height))
    draw = ImageDraw.Draw(img)
    for y in range(height):
        ratio = y / height
        r = int(color_top[0] + (color_bottom[0] - color_top[0]) * ratio)
        g = int(color_top[1] + (color_bottom[1] - color_top[1]) * ratio)
        b = int(color_top[2] + (color_bottom[2] - color_top[2]) * ratio)
        draw.line([(0, y), (width, y)], fill=(r, g, b))
    return img


def add_rounded_corners(img, radius):
    """Add rounded corners to an image."""
    mask = Image.new("L", img.size, 0)
    draw = ImageDraw.Draw(mask)
    draw.rounded_rectangle([(0, 0), img.size], radius=radius, fill=255)
    result = Image.new("RGBA", img.size, (0, 0, 0, 0))
    result.paste(img, mask=mask)
    return result


def add_shadow(img, offset=15, blur_radius=30, opacity=80):
    """Add a drop shadow behind an image."""
    shadow = Image.new("RGBA", (img.width + blur_radius * 2, img.height + blur_radius * 2), (0, 0, 0, 0))
    shadow_layer = Image.new("RGBA", img.size, (0, 0, 0, opacity))
    shadow.paste(shadow_layer, (blur_radius + offset, blur_radius + offset))
    shadow = shadow.filter(ImageFilter.GaussianBlur(blur_radius))
    shadow.paste(img, (blur_radius, blur_radius), img)
    return shadow


def load_font(size):
    """Load the best available font."""
    font_paths = [
        Path("/System/Library/Fonts/Supplemental/Arial Rounded Bold.ttf"),
        Path("/System/Library/Fonts/Supplemental/Arial Bold.ttf"),
        Path("/Library/Fonts/Arial Bold.ttf"),
    ]
    for path in font_paths:
        if path.exists():
            return ImageFont.truetype(str(path), size)
    return ImageFont.load_default()


def create_screenshot(screen_path, tagline, color_top, color_bottom, output_path, spec):
    """Create a single polished App Store screenshot."""
    canvas_w, canvas_h = spec["canvas"]
    canvas = make_gradient(canvas_w, canvas_h, color_top, color_bottom).convert("RGBA")

    screenshot = Image.open(screen_path).convert("RGBA")

    max_screenshot_w = int(canvas_w * 0.92)
    max_screenshot_h = int(canvas_h * 0.82)

    scale = min(max_screenshot_w / screenshot.width, max_screenshot_h / screenshot.height)
    new_w = int(screenshot.width * scale)
    new_h = int(screenshot.height * scale)
    screenshot = screenshot.resize((new_w, new_h), Image.LANCZOS)

    screenshot = add_rounded_corners(screenshot, radius=spec["corner_radius"])
    screenshot_with_shadow = add_shadow(screenshot, offset=12, blur_radius=25, opacity=60)

    x = (canvas_w - screenshot_with_shadow.width) // 2
    y = canvas_h - screenshot_with_shadow.height + 80
    canvas.paste(screenshot_with_shadow, (x, y), screenshot_with_shadow)

    font = load_font(spec["font_size"])
    draw = ImageDraw.Draw(canvas)

    text_bbox = draw.multiline_textbbox((0, 0), tagline, font=font, align="center")
    text_w = text_bbox[2] - text_bbox[0]
    text_h = text_bbox[3] - text_bbox[1]
    text_x = (canvas_w - text_w) // 2
    text_y = y - text_h - 80

    shadow_offset = 3
    draw.multiline_text(
        (text_x + shadow_offset, text_y + shadow_offset),
        tagline,
        font=font,
        fill=(0, 0, 0, 60),
        align="center",
    )
    draw.multiline_text((text_x, text_y), tagline, font=font, fill=(255, 255, 255), align="center")

    canvas = canvas.convert("RGB")
    canvas.save(output_path, quality=95)
    print(f"Created {display_path(output_path)} ({canvas.width}x{canvas.height})")


def display_path(path):
    return path.relative_to(REPO_ROOT) if path.is_relative_to(REPO_ROOT) else path


def composite(platform, input_dir, output_dir):
    """Composites one listing; returns a process exit code."""
    spec = PLATFORMS[platform]
    filenames = [screen[0] for screen in spec["screens"]]
    try:
        resolved, problems = resolve_inputs(input_dir, filenames, spec["strict"])
    except InputError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    if spec["strict"] and problems:
        for problem in problems:
            print(f"error: {problem}", file=sys.stderr)
        print(f"error: refusing to write a partial {platform} listing from {display_path(input_dir)}", file=sys.stderr)
        return 1

    if platform == "mac":
        return composite_mac(spec, resolved, input_dir, output_dir)

    output_dir.mkdir(parents=True, exist_ok=True)
    for filename, tagline, color_top, color_bottom in spec["screens"]:
        if filename in resolved:
            create_screenshot(resolved[filename], tagline, color_top, color_bottom, output_dir / filename, spec)
        else:
            print(f"Skipping {filename} -- not usable")

    print(f"\nDone! Screenshots in {display_path(output_dir)}/")
    if problems:
        # Said out loud rather than left to the eye: a listing short a screen
        # because an export was incomplete looks exactly like one that was
        # meant to be short.
        for problem in problems:
            print(f"warning: {problem}")
        print(
            f"warning: {len(problems)} of {len(filenames)} screens were not usable from "
            f"{display_path(input_dir)}/ -- re-export the capture run before uploading."
        )
    return 0


def composite_mac(spec, resolved, input_dir, output_dir):
    """Plans every Mac screen before writing any, then renders them and layout-report.json."""
    try:
        for source, output, headline, subhead in spec["screens"]:
            with Image.open(resolved[source]) as image:
                mac_screenshot_design.plan(image.size, headline, subhead)
    except mac_screenshot_design.LayoutError as error:
        print(f"error: {source}: {error}", file=sys.stderr)
        return 1

    output_dir.mkdir(parents=True, exist_ok=True)
    report = {"canvas": list(spec["canvas"]), "font": mac_screenshot_design.font_family(), "screens": []}
    for source, output, headline, subhead in spec["screens"]:
        layout = mac_screenshot_design.render(resolved[source], output_dir / output, headline, subhead)
        report["screens"].append({
            "output": output,
            "source": source,
            "source_file": resolved[source].name,
            "source_sha256": hashlib.sha256(resolved[source].read_bytes()).hexdigest(),
            **layout,
        })
        print(f"Created {display_path(output_dir / output)} from {resolved[source].name}")
    (output_dir / "layout-report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")

    expected = {screen[1] for screen in spec["screens"]}
    stale = sorted(path.name for path in output_dir.glob("*.png") if path.name not in expected)
    for name in stale:
        print(f"warning: {display_path(output_dir / name)} is not part of this listing; do not upload it")
    print(f"\nDone! {len(expected)} screenshots in {display_path(output_dir)}/")
    return 0


def self_test():
    """Checks input resolution on disposable fixtures in a temporary directory."""
    uuid = "ED740AA1-6D40-45DA-99F6-2BFB04A8A221"
    mac_names = [screen[0] for screen in PLATFORMS["mac"]["screens"]]
    captures = [f"{Path(name).stem}_0_{uuid}.png" for name in mac_names] + [f"09-final-state_0_{uuid}.png"]

    with tempfile.TemporaryDirectory() as temp:
        root = Path(temp)

        def export(name, suggested_names):
            directory = root / name
            directory.mkdir()
            attachments = []
            for index, suggested in enumerate(suggested_names):
                exported = f"{index:08X}-0000-4000-8000-000000000000{Path(suggested).suffix}"
                if Path(suggested).suffix == ".png":
                    Image.new("RGB", (160, 100), (200, 200, 200)).save(directory / exported)
                else:
                    (directory / exported).write_text("skipped")
                attachments.append({"suggestedHumanReadableName": suggested, "exportedFileName": exported})
            (directory / "manifest.json").write_text(json.dumps([{"attachments": attachments}]))
            return directory

        listing_names = [screen[1] for screen in PLATFORMS["mac"]["screens"]]
        assert len(set(mac_names)) == len(mac_names) and len(set(listing_names)) == len(listing_names)
        output = root / "out-complete"
        assert composite("mac", export("complete", captures), output) == 0
        assert sorted(path.name for path in output.iterdir()) == sorted(listing_names + ["layout-report.json"])
        for name in listing_names:
            with Image.open(output / name) as image:
                assert image.size == PLATFORMS["mac"]["canvas"] and image.mode == "RGB", (name, image.size, image.mode)
        report = json.loads((output / "layout-report.json").read_text())
        assert [screen["output"] for screen in report["screens"]] == listing_names

        output = root / "out-partial"
        assert composite("mac", export("partial", captures[1:]), output) == 1
        assert not output.exists(), "a partial Mac set must not write anything"
        _, problems = resolve_inputs(root / "partial", mac_names, strict=True)
        assert problems == [f"{mac_names[0]} is missing"], problems

        # A headline too long for one line wraps inside the margins; a wide or tall
        # capture scales to fit; a headline that cannot fit fails before drawing.
        design = mac_screenshot_design
        long_headline = "Your passwords, your groups, your servers. All at home on your Mac."
        for size in [(2160, 1400), (1080, 1216), (3200, 1000), (1100, 2000)]:
            layout = design.plan(size, long_headline, "A native KeePass manager. Your vaults stay yours.")
            assert len(layout["headline"]["lines"]) == 2, layout["headline"]["lines"]
            left, top, right, bottom = layout["window"]
            assert right - left <= design.LAYOUT["window_max_width"] and bottom <= design.CANVAS[1]
            assert abs((right - left) / (bottom - top) - size[0] / size[1]) < 0.01, "window must scale uniformly"
        for size, headline in [((2160, 1400), " ".join(["Unbreakable"] * 12)), ((400, 3000), "Short")]:
            try:
                design.plan(size, headline, "Subhead")
            except design.LayoutError:
                pass
            else:
                raise AssertionError(f"{size} {headline!r} must fail layout")

        corners = root / "corners.png"
        window = Image.new("RGBA", (400, 260), (0, 0, 0, 0))
        ImageDraw.Draw(window).rounded_rectangle([0, 0, 399, 259], radius=40, fill=(250, 250, 250, 255))
        window.save(corners)
        design.render(corners, root / "corners-out.png", "Your passwords. At home on Mac.", "Subhead")
        with Image.open(root / "corners-out.png") as rendered:
            layout = design.plan(window.size, "Your passwords. At home on Mac.", "Subhead")
            left, top = layout["window"][:2]
            assert rendered.getpixel((left + 1, top + 1)) != (250, 250, 250), "capture corner alpha must survive"

        skipped = export("skipped", captures + [f"{SKIPPED_CAPTURES_STEM}_0_{uuid}.txt"])
        assert composite("mac", skipped, root / "out-skipped") == 1
        assert not (root / "out-skipped").exists()

        _, problems = resolve_inputs(export("duplicate", captures + [f"02-unlock_1_{uuid}.png"]), mac_names, strict=True)
        assert len(problems) == 1 and problems[0].startswith("02-unlock.png is ambiguous"), problems

        broken = export("broken", captures)
        next(broken.glob("00000000-*.png")).unlink()
        try:
            resolve_inputs(broken, mac_names, strict=True)
        except InputError:
            pass
        else:
            raise AssertionError("a manifest naming a missing file must fail")

        plain = root / "plain"
        plain.mkdir()
        for name in mac_names:
            Image.new("RGB", (160, 100)).save(plain / name)
        resolved, problems = resolve_inputs(plain, mac_names, strict=True)
        assert problems == [] and resolved[mac_names[0]] == plain / mac_names[0], problems

        # The iPhone listing keeps compositing a short set, with a warning.
        iphone_names = [screen[0] for screen in PLATFORMS["iphone"]["screens"]]
        iphone = root / "iphone"
        iphone.mkdir()
        Image.new("RGB", (100, 200)).save(iphone / iphone_names[0])
        output = root / "out-iphone"
        assert composite("iphone", iphone, output) == 0
        assert [path.name for path in output.iterdir()] == [iphone_names[0]]

    print("self-test passed")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument(
        "--platform",
        choices=sorted(PLATFORMS),
        default="iphone",
        help="which listing to composite for (default: iphone)",
    )
    parser.add_argument(
        "--input-dir",
        type=Path,
        help="raw screenshots or an xcresulttool attachment export (default: the platform's input directory)",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        help="where to write the listing (default: the platform's output directory)",
    )
    parser.add_argument("--self-test", action="store_true", help="check input resolution and Mac layout on disposable fixtures and exit")
    args = parser.parse_args()

    if args.self_test:
        self_test()
        return 0

    spec = PLATFORMS[args.platform]
    input_dir = (args.input_dir or spec["input_dir"]).resolve()
    return composite(args.platform, input_dir, (args.output_dir or spec["output_dir"]).resolve())


if __name__ == "__main__":
    sys.exit(main())
