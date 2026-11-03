#!/usr/bin/env python3
"""Generate polished App Store screenshots from raw UI-test captures.

Two listings, two platforms, one entry point:

    ci_scripts/make_appstore_screenshots.py --capture  # iPhone: capture + composite every locale
    ci_scripts/make_appstore_screenshots.py            # iPhone: composite existing captures
    ci_scripts/make_appstore_screenshots.py --platform mac [--input-dir DIR] [--output-dir DIR]

iPhone -- one listing per shipped locale. Captions live in appstore_captions.json
(locale -> listing image -> caption, explicit line breaks). Raw captures are read
from build/screenshots/<locale>/ and listings written to build/appstore/<locale>/,
6.9" (1320x2868) only. Every caption must fit the canvas in its locale's font with
no missing glyphs, or the run fails before writing anything.

`--capture` runs `KeeForgeUITests/AppStoreScreenshots` once per locale on a 6.9"
simulator (created if missing) with `-testLanguage`/`-testRegion`, so the app
chrome matches the captions, and exports each run's attachments into
build/screenshots/<locale>/. It drives local Xcode; on a shared machine run it
under the repo's Xcode lock. `--locale` narrows either step. By hand, one locale:

    TEST_RUNNER_APPSTORE_SCREENSHOTS=1 xcodebuild test -project KeeForge.xcodeproj \\
        -scheme KeeForge -destination 'platform=iOS Simulator,name=iPhone 18 Pro Max' \\
        -testLanguage de -testRegion DE -only-testing:KeeForgeUITests/AppStoreScreenshots
    xcrun xcresulttool export attachments --path <xcresult> --output-path build/screenshots/de

Mac -- English only. Capture `KeeForgeMacUITests/MacScreenshotAuditUITests` into
`build/screenshots-mac`; the light design in mac_screenshot_design.py writes seven
numbered story images plus layout-report.json:

    TEST_RUNNER_SCREENSHOT_AUDIT=1 xcodebuild test -project KeeForge.xcodeproj \\
        -scheme KeeForgeMac -destination 'platform=macOS,arch=arm64' \\
        -only-testing:KeeForgeMacUITests/MacScreenshotAuditUITests
    xcrun xcresulttool export attachments --path <xcresult> --output-path build/screenshots-mac

The export can be used as-is. xcresulttool writes UUID-named files plus a
manifest.json index; when that index is present, each expected screen is found
through its `suggestedHumanReadableName` (`01-database-list_0_<UUID>.png`).
Plainly named files (`01-database-list.png`) also work. `--input-dir` overrides
the platform's default input directory (for iPhone, the parent of the locale
directories).

Both classes skip by default (see their doc comments), and both gate variables
must be real environment variables on the xcodebuild process -- Xcode strips the
TEST_RUNNER_ prefix and forwards them into the test runner, whereas a trailing
bare KEY=value argument becomes a build-setting override that never arrives and
the class silently skips. `--capture` sets it and fails on a short export.

The Mac audit harness additionally needs Screen Recording permission for
`KeeForgeMacUITests-Runner`, and reports anything it could not capture in its
`00-skipped-captures` attachment (see KeeForgeMacUITests/AGENTS.md). A short
export is a harness problem, not a missing screen, so the Mac listing refuses to
write anything when that evidence is present or any screen is missing or
ambiguous. Compositing existing iPhone captures still warns and composites what
it has.

`--self-test` checks input resolution, every locale's captions, and Mac layout
against disposable fixtures.
"""

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
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
        # App Store 6.9" display size (iPhone 16/17/18 Pro Max)
        "canvas": (1320, 2868),
        "input_dir": REPO_ROOT / "build" / "screenshots",
        "output_dir": REPO_ROOT / "build" / "appstore",
        "corner_radius": 44,
        "font_size": 88,
        "min_font_size": 64,
        "text_margin": 80,
        "strict": False,
        # (AppStoreScreenshots attachment, listing file, gradient top, gradient bottom),
        # in listing order. The caption for each listing file is in CAPTIONS_PATH.
        "screens": [
            ("03-vault-groups.png", "01-free.png", (26, 31, 61), (18, 22, 48)),
            ("06-entry-detail.png", "02-autofill.png", (41, 98, 255), (30, 70, 220)),
            ("01-database-list.png", "03-keepassxc.png", (0, 150, 136), (0, 110, 100)),
            ("02-unlock-screen.png", "04-unlock.png", (220, 80, 60), (180, 40, 30)),
            ("05-entry-list.png", "05-entries.png", (130, 80, 220), (90, 40, 180)),
            ("08-search.png", "06-search.png", (30, 130, 230), (20, 90, 190)),
            ("07-entry-edit.png", "07-edit.png", (60, 60, 60), (30, 30, 30)),
            ("04-database-settings.png", "08-settings.png", (31, 94, 58), (20, 63, 38)),
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


CAPTIONS_PATH = Path(__file__).resolve().with_name("appstore_captions.json")
SYSTEM_FONTS = Path("/System/Library/Fonts")
# Caption fonts by script: (file, collection index, weight axis or None, stroke px).
# macOS ships no bold Traditional Chinese face on disk, so Heiti TC Medium gets a
# stroke to match the other locales' weight.
SF_ROUNDED_BOLD = (SYSTEM_FONTS / "SFNSRounded.ttf", 0, 700, 0)
FONTS = {
    "ja": (SYSTEM_FONTS / "ヒラギノ角ゴシック W7.ttc", 0, None, 0),
    "zh-Hans": (SYSTEM_FONTS / "Hiragino Sans GB.ttc", 2, None, 0),
    "zh-Hant": (SYSTEM_FONTS / "STHeiti Medium.ttc", 0, None, 2),
}
# Shipped app locales -> xcodebuild -testRegion, in App Store review order.
LOCALES = {
    "en": "US",
    "de": "DE",
    "fr": "FR",
    "es": "ES",
    "zh-Hans": "CN",
    "zh-Hant": "TW",
    "ja": "JP",
    "it": "IT",
    "ru": "RU",
}
CAPTURE_DEVICE = "iPhone 18 Pro Max"
CAPTURE_TEST = "KeeForgeUITests/AppStoreScreenshots"

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


class CaptionError(Exception):
    pass


def load_caption_font(locale, size):
    path, index, weight, _ = FONTS.get(locale, SF_ROUNDED_BOLD)
    font = ImageFont.truetype(str(path), size, index=index)
    if weight is not None:
        font.set_variation_by_axes([400, weight])  # SF axes: GRAD, Weight
    return font


def caption_options(locale, font):
    """multiline_text keyword arguments shared by layout and drawing."""
    stroke = FONTS.get(locale, SF_ROUNDED_BOLD)[3]
    return {"font": font, "align": "center", "spacing": round(font.size * 0.18), "stroke_width": stroke}


def missing_glyphs(font, text):
    """Characters the font draws as its .notdef box (tofu)."""
    def mask(ch):
        image = font.getmask(ch)
        return image.size, bytes(image)

    notdef = mask("\U000F0000")  # Supplementary Private Use, in no caption font
    return sorted({ch for ch in text if not ch.isspace() and mask(ch) == notdef})


def load_captions(locales, spec):
    """Returns {locale: {listing stem: caption}}, insisting every listing image has one."""
    table = json.loads(CAPTIONS_PATH.read_text(encoding="utf-8"))
    expected = {Path(screen[1]).stem for screen in spec["screens"]}
    problems = []
    for locale in LOCALES:
        keys = set(table.get(locale, {}))
        if keys != expected:
            problems.append(f"{locale}: missing {sorted(expected - keys)}, unexpected {sorted(keys - expected)}")
    unknown = sorted(set(table) - set(LOCALES))
    if unknown:
        problems.append(f"captions for unshipped locales {unknown}")
    if problems:
        raise CaptionError(f"{CAPTIONS_PATH.name}: " + "; ".join(problems))
    return {locale: table[locale] for locale in locales}


def plan_font(locale, captions, spec):
    """Largest font size at which every caption of a locale fits, so one listing shares one size."""
    max_width = spec["canvas"][0] - 2 * spec["text_margin"] - 2 * FONTS.get(locale, SF_ROUNDED_BOLD)[3]
    for caption in captions.values():
        lines = caption.split("\n")
        if len(lines) > 3 or any(not line.strip() for line in lines):
            raise CaptionError(f"{locale}: {caption!r} must be 1-3 non-empty lines")
        missing = missing_glyphs(load_caption_font(locale, spec["font_size"]), caption)
        if missing:
            raise CaptionError(f"{locale}: font has no glyph for {''.join(missing)!r} in {caption!r}")
    for size in range(spec["font_size"], spec["min_font_size"] - 1, -2):
        font = load_caption_font(locale, size)
        if all(font.getlength(line) <= max_width for caption in captions.values() for line in caption.split("\n")):
            return font
    widest = max((line for caption in captions.values() for line in caption.split("\n")), key=font.getlength)
    raise CaptionError(f"{locale}: {widest!r} is wider than {max_width}px even at {spec['min_font_size']}px")


def place(image_size, options, caption, spec):
    """Returns (screenshot size, screenshot origin, caption origin); the caption must clear the top margin."""
    canvas_w, canvas_h = spec["canvas"]
    scale = min(canvas_w * 0.92 / image_size[0], canvas_h * 0.82 / image_size[1])
    shot_size = (int(image_size[0] * scale), int(image_size[1] * scale))
    shadow_pad = 25 * 2
    shot_origin = ((canvas_w - shot_size[0] - shadow_pad) // 2, canvas_h - shot_size[1] - shadow_pad + 80)

    left, top, right, bottom = ImageDraw.Draw(Image.new("L", (1, 1))).multiline_textbbox(
        (0, 0), caption, **options
    )
    text_origin = ((canvas_w - (right - left)) // 2 - left, shot_origin[1] - (bottom - top) - 80 - top)
    if text_origin[1] + top < spec["text_margin"]:
        raise CaptionError(f"{caption!r} is too tall for the space above the screenshot")
    return shot_size, shot_origin, text_origin


def create_screenshot(screen_path, caption, options, color_top, color_bottom, output_path, spec):
    """Create a single polished App Store screenshot."""
    canvas = make_gradient(*spec["canvas"], color_top, color_bottom).convert("RGBA")
    screenshot = Image.open(screen_path).convert("RGBA")
    shot_size, shot_origin, text_origin = place(screenshot.size, options, caption, spec)

    screenshot = screenshot.resize(shot_size, Image.LANCZOS)
    screenshot = add_rounded_corners(screenshot, radius=spec["corner_radius"])
    screenshot_with_shadow = add_shadow(screenshot, offset=12, blur_radius=25, opacity=60)
    canvas.paste(screenshot_with_shadow, shot_origin, screenshot_with_shadow)

    draw = ImageDraw.Draw(canvas)
    shadow, white = (0, 0, 0, 60), (255, 255, 255)
    draw.multiline_text((text_origin[0] + 3, text_origin[1] + 3), caption, fill=shadow, stroke_fill=shadow, **options)
    draw.multiline_text(text_origin, caption, fill=white, stroke_fill=white, **options)

    canvas.convert("RGB").save(output_path, quality=95)
    print(f"Created {display_path(output_path)} ({canvas.width}x{canvas.height})")


def display_path(path):
    return path.relative_to(REPO_ROOT) if path.is_relative_to(REPO_ROOT) else path


def composite(platform, input_dir, output_dir, locales=None):
    """Composites one listing (every requested locale for iPhone); returns a process exit code."""
    spec = PLATFORMS[platform]
    if platform == "iphone":
        return composite_iphone(spec, input_dir, output_dir, locales or list(LOCALES))

    filenames = [screen[0] for screen in spec["screens"]]
    try:
        resolved, problems = resolve_inputs(input_dir, filenames, spec["strict"])
    except InputError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    if problems:
        for problem in problems:
            print(f"error: {problem}", file=sys.stderr)
        print(f"error: refusing to write a partial {platform} listing from {display_path(input_dir)}", file=sys.stderr)
        return 1
    return composite_mac(spec, resolved, input_dir, output_dir)


def composite_iphone(spec, input_root, output_root, locales):
    """Plans every locale's captions against its captures, then writes build/appstore/<locale>/."""
    filenames = [screen[0] for screen in spec["screens"]]
    plans = {}
    warnings = []
    try:
        captions = load_captions(locales, spec)
        for locale in locales:
            resolved, problems = resolve_inputs(input_root / locale, filenames, strict=False)
            warnings += [f"{locale}: {problem}" for problem in problems]
            options = caption_options(locale, plan_font(locale, captions[locale], spec))
            for source, output, *_ in spec["screens"]:
                if source in resolved:
                    with Image.open(resolved[source]) as image:
                        place(image.size, options, captions[locale][Path(output).stem], spec)
            plans[locale] = (resolved, options)
    except (InputError, CaptionError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    for locale, (resolved, options) in plans.items():
        output_dir = output_root / locale
        output_dir.mkdir(parents=True, exist_ok=True)
        for source, output, color_top, color_bottom in spec["screens"]:
            if source in resolved:
                caption = captions[locale][Path(output).stem]
                create_screenshot(resolved[source], caption, options, color_top, color_bottom, output_dir / output, spec)
        print(f"{locale}: {options['font'].size}px captions, {len(resolved)} of {len(filenames)} screens")

    print(f"\nDone! Screenshots in {display_path(output_root)}/<locale>/")
    if warnings:
        # Said out loud rather than left to the eye: a listing short a screen
        # because an export was incomplete looks exactly like one that was
        # meant to be short.
        for warning in warnings:
            print(f"warning: {warning}")
        print(f"warning: {len(warnings)} screens were not usable -- re-capture before uploading.")
    return 0


def run(argv, **kwargs):
    print("+ " + " ".join(str(arg) for arg in argv), flush=True)
    return subprocess.run([str(arg) for arg in argv], check=True, **kwargs)


def capture_simulator(device):
    """Returns the UDID of an available simulator named `device`, creating it on the newest iOS runtime that supports it."""
    def simctl_json(*args):
        return json.loads(subprocess.run(
            ["xcrun", "simctl", "list", "--json", *args], check=True, capture_output=True, text=True
        ).stdout)

    runtimes = sorted(
        (runtime for runtime in simctl_json("runtimes")["runtimes"]
         if runtime.get("isAvailable") and runtime.get("platform") == "iOS"
         and any(kind["name"] == device for kind in runtime.get("supportedDeviceTypes", []))),
        key=lambda runtime: [int(part) for part in runtime["version"].split(".")],
    )
    if not runtimes:
        raise SystemExit(f"error: no installed iOS simulator runtime supports {device}")
    devices = simctl_json("devices", "available")["devices"]
    for runtime in reversed(runtimes):
        for candidate in devices.get(runtime["identifier"], []):
            if candidate["name"] == device:
                return candidate["udid"]
    runtime = runtimes[-1]
    kind = next(kind for kind in runtime["supportedDeviceTypes"] if kind["name"] == device)
    return subprocess.run(
        ["xcrun", "simctl", "create", device, kind["identifier"], runtime["identifier"]],
        check=True, capture_output=True, text=True,
    ).stdout.strip()


def capture(locales, device, input_root):
    """Runs AppStoreScreenshots once per locale and exports each run into input_root/<locale>/."""
    udid = capture_simulator(device)
    subprocess.run(["xcrun", "simctl", "boot", udid], capture_output=True)
    run(["xcrun", "simctl", "bootstatus", udid])
    run(["xcrun", "simctl", "status_bar", udid, "override", "--time", "9:41", "--dataNetwork", "wifi",
         "--wifiMode", "active", "--wifiBars", "3", "--cellularMode", "active", "--cellularBars", "4",
         "--batteryState", "charged", "--batteryLevel", "100"])

    derived_data = REPO_ROOT / "build" / "screenshots-derived-data"
    common = ["xcodebuild", "-project", REPO_ROOT / "KeeForge.xcodeproj", "-scheme", "KeeForge",
              "-destination", f"platform=iOS Simulator,id={udid}", "-derivedDataPath", derived_data]
    run(common + ["build-for-testing"])
    environment = dict(os.environ, TEST_RUNNER_APPSTORE_SCREENSHOTS="1")
    filenames = [screen[0] for screen in PLATFORMS["iphone"]["screens"]]
    for locale in locales:
        bundle = input_root / f"{locale}.xcresult"
        export = input_root / locale
        shutil.rmtree(bundle, ignore_errors=True)
        shutil.rmtree(export, ignore_errors=True)
        run(common + ["test-without-building", f"-only-testing:{CAPTURE_TEST}",
                      "-testLanguage", locale, "-testRegion", LOCALES[locale], "-resultBundlePath", bundle],
            env=environment)
        run(["xcrun", "xcresulttool", "export", "attachments", "--path", bundle, "--output-path", export])
        _, problems = resolve_inputs(export, filenames, strict=True)
        if problems:
            raise SystemExit(f"error: {locale} capture is incomplete: " + "; ".join(problems))
    run(["xcrun", "simctl", "status_bar", udid, "clear"])


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

        # Every locale's captions fit a device-shaped capture in its own font; a
        # short iPhone set still composites, with a warning, under <locale>/.
        spec = PLATFORMS["iphone"]
        captions = load_captions(list(LOCALES), spec)
        for locale, table in captions.items():
            options = caption_options(locale, plan_font(locale, table, spec))
            for caption in table.values():
                place((1320, 2868), options, caption, spec)
        latin = load_caption_font("en", 88)
        assert missing_glyphs(latin, "Ab·Жё") == [] and missing_glyphs(latin, "保管庫") == ["保", "庫", "管"]
        for caption in ["One\nTwo\nThree\nFour", " ".join(["Unbreakable"] * 6)]:
            try:
                plan_font("en", {"01-free": caption}, spec)
            except CaptionError:
                pass
            else:
                raise AssertionError(f"{caption!r} must fail caption layout")

        iphone_names = [screen[0] for screen in spec["screens"]]
        iphone = root / "iphone"
        (iphone / "de").mkdir(parents=True)
        Image.new("RGB", (1320, 2868)).save(iphone / "de" / iphone_names[0])
        output = root / "out-iphone"
        assert composite("iphone", iphone, output, ["de"]) == 0
        assert [path.relative_to(output).as_posix() for path in output.rglob("*.png")] == [f"de/{spec['screens'][0][1]}"]

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
    parser.add_argument(
        "--locale",
        action="append",
        choices=list(LOCALES),
        help="iPhone only: limit capture and compositing to this locale (repeatable; default: every shipped locale)",
    )
    parser.add_argument(
        "--capture",
        action="store_true",
        help="iPhone only: run AppStoreScreenshots per locale on a local simulator before compositing",
    )
    parser.add_argument("--device", default=CAPTURE_DEVICE, help=f"simulator for --capture (default: {CAPTURE_DEVICE})")
    parser.add_argument("--self-test", action="store_true", help="check input resolution, captions and Mac layout on disposable fixtures and exit")
    args = parser.parse_args()

    if args.self_test:
        self_test()
        return 0
    if args.platform != "iphone" and (args.locale or args.capture):
        parser.error("--locale and --capture apply to the iPhone listing only")

    spec = PLATFORMS[args.platform]
    input_dir = (args.input_dir or spec["input_dir"]).resolve()
    if args.capture:
        capture(args.locale or list(LOCALES), args.device, input_dir)
    return composite(args.platform, input_dir, (args.output_dir or spec["output_dir"]).resolve(), args.locale)


if __name__ == "__main__":
    sys.exit(main())
