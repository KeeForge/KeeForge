#!/usr/bin/env python3
"""Generate the App Store listing screenshots from raw UI-test captures.

    ci_scripts/make_appstore_screenshots.py [--platform iphone|ipad|mac] [--locale en ...]
                                            [--input-dir DIR] [--output-dir DIR]
    ci_scripts/make_appstore_screenshots.py --capture [--locale de]   # iPhone, local simulator
    ci_scripts/make_appstore_screenshots.py --self-test

Every platform tells the same six-frame story with one headline per frame
(appstore_captions.json: locale -> frame -> headline, explicit line breaks; a
"<frame>@<platform>" key overrides one platform). The Mac's larger canvas also
carries a short subline per frame ("<frame>:sub@mac"); phones and iPads do not.
A frame with "checklist" also draws a card listing included features
("<frame>:list", one per line, with "@<platform>" overrides): the features other
KeePass apps sell separately. Store art never names a price. Each frame is the app's real UI
in a device or window on an indigo or paper field, plus up to two cards cut from
real captures (the 2FA code, the KDBX format row) floating over it. The drawing
kit, fonts and palette are shared with the header and search art in store_art.py.

Captures are read per locale from the platform's input directory and come from:

    iphone  KeeForgeUITests/AppStoreScreenshots + AppStoreAutoFillScreenshot  build/screenshots/<locale>/
    ipad    the same classes on a 13" iPad simulator                          build/screenshots-ipad/<locale>/
    mac     KeeForgeMacUITests/MacAppStoreScreenshots                         build/screenshots-mac/<locale>/

The classes skip unless APPSTORE_SCREENSHOTS=1 reaches the test runner: set
TEST_RUNNER_APPSTORE_SCREENSHOTS=1 on the xcodebuild process (or pass
`--test-env APPSTORE_SCREENSHOTS=1` to studio-test). Export a run with
`xcrun xcresulttool export attachments --path <xcresult> --output-path <dir>`;
the export is used as is, each capture found through manifest.json's
`suggestedHumanReadableName`. Plainly named files (`06-entry-detail.png`) work too.

A listing is never partial: a missing or ambiguous capture, a card that cannot be
found in its capture, or a headline that does not fit fails the run before any
file is written. Output goes to the platform's output directory, one folder per
locale, with layout-report.json naming the capture behind every frame.
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

from PIL import Image, ImageDraw

import store_art as art

REPO_ROOT = Path(__file__).resolve().parents[1]
CAPTIONS_PATH = Path(__file__).resolve().with_name("appstore_captions.json")
FRAMES = ["01-pitch", "02-autofill", "03-keepassxc", "04-security", "05-everyday", "06-included"]

# Shipped app locales -> xcodebuild -testRegion, in App Store review order.
LOCALES = {"en": "US", "de": "DE", "fr": "FR", "es": "ES", "zh-Hans": "CN", "zh-Hant": "TW", "ja": "JP", "it": "IT", "ru": "RU"}
CAPTURE_DEVICE = "iPhone 18 Pro Max"
CAPTURE_TESTS = ["KeeForgeUITests/AppStoreScreenshots", "KeeForgeUITests/AppStoreAutoFillScreenshot"]

INDIGO, PAPER = "indigo", "paper"

# Cards: (capture, hint point inside the block as fractions of the capture, store_art.find_card mode).
# Portrait listings stack cards at the bottom over the device; the Mac floats them
# over the window's lower-left corner. Frames alternate indigo and paper.
PLATFORMS = {
    "iphone": {
        # App Store 6.9" display size; Apple scales it to every smaller iPhone.
        "canvas": (1320, 2868),
        "input_dir": REPO_ROOT / "build" / "screenshots",
        "output_dir": REPO_ROOT / "build" / "appstore",
        "layout": "portrait",
        "margin": 110, "top": 250, "headline": (176, 112), "leading": 1.02,
        "device": {"width": 0.74, "bezel": 26, "radius": 150, "gap": 130, "max_top": 0.42},
        "cards": {"width": 0.84, "radius": 48, "gap": 36, "bottom": 150},
        "art": {"height": 0.24, "x": 0.03, "y": 0.72},
        "frames": {
            "01-pitch": {"field": INDIGO, "focus": (0.7, 0.62), "screen": "03-vault-groups", "art": "kdbx"},
            "02-autofill": {"field": PAPER, "focus": (0.75, 0.62), "screen": "09-autofill-picker", "cards": [
                ("06-entry-detail", (0.5, 0.80), "header"),
                ("06b-entry-passkey", (0.5, 0.61), "header")]},
            "03-keepassxc": {"field": INDIGO, "focus": (0.35, 0.6), "screen": "01-database-list", "cards": [
                ("04-database-settings", (0.5, 0.255), "section"),
                ("04-database-settings", (0.5, 0.58), "row")]},
            "04-security": {"field": PAPER, "focus": (0.3, 0.6), "screen": "02-unlock-screen", "cards": [
                ("04-database-settings", (0.5, 0.51), "row")]},
            "05-everyday": {"field": INDIGO, "focus": (0.65, 0.55), "screen": "05-entry-list", "cards": [
                ("08-search", (0.5, 0.18), "section")]},
            "06-included": {"field": PAPER, "focus": (0.3, 0.6), "screen": "01-database-list", "checklist": 64},
        },
    },
    "ipad": {
        # App Store 13" iPad display size, portrait.
        "canvas": (2064, 2752),
        "input_dir": REPO_ROOT / "build" / "screenshots-ipad",
        "output_dir": REPO_ROOT / "build" / "appstore-ipad",
        "layout": "portrait",
        "margin": 170, "top": 230, "headline": (196, 124), "leading": 1.02,
        "device": {"width": 0.76, "bezel": 24, "radius": 64, "gap": 130, "max_top": 0.36},
        "cards": {"width": 0.7, "radius": 44, "gap": 36, "bottom": 140},
        "art": {"height": 0.23, "x": 0.03, "y": 0.72},
        "frames": {
            "01-pitch": {"field": INDIGO, "focus": (0.7, 0.62), "screen": "06-entry-detail", "art": "kdbx"},
            "02-autofill": {"field": PAPER, "focus": (0.75, 0.62), "screen": "09-autofill-picker", "cards": [
                ("06-entry-detail", (0.68, 0.52), "header"),
                ("06b-entry-passkey", (0.68, 0.65), "header")]},
            "03-keepassxc": {"field": INDIGO, "focus": (0.35, 0.6), "screen": "01-database-list", "cards": [
                ("04-database-settings", (0.5, 0.36), "section"),
                ("04-database-settings", (0.5, 0.59), "row")]},
            "04-security": {"field": PAPER, "focus": (0.3, 0.6), "screen": "02-unlock-screen", "cards": [
                ("04-database-settings", (0.5, 0.54), "row")]},
            "05-everyday": {"field": INDIGO, "focus": (0.65, 0.55), "screen": "07-entry-edit"},
            "06-included": {"field": PAPER, "focus": (0.3, 0.6), "screen": "01-database-list", "checklist": 70},
        },
    },
    "mac": {
        # The largest Mac size App Store Connect takes; it downscales to the rest.
        "canvas": (2880, 1800),
        "input_dir": REPO_ROOT / "build" / "screenshots-mac",
        "output_dir": REPO_ROOT / "build" / "appstore-mac",
        "layout": "landscape",
        "margin": 180, "column": 0.28, "text_top": 0.2, "headline": (150, 96), "leading": 1.04,
        "sub": (62, 44), "sub_leading": 1.32, "sub_gap": 0.42,
        "window": {"width": 0.57, "right": 130, "max_height": 0.8, "gap": 100},
        "cards": {"width": 0.3, "radius": 30, "gap": 28, "bottom": 150, "x": -0.07},
        "art": {"height": 0.36, "x": -0.05, "y": 0.55},
        "frames": {
            "01-pitch": {"field": INDIGO, "focus": (0.7, 0.5), "screen": "01-entry-detail", "art": "kdbx"},
            "02-autofill": {"field": PAPER, "focus": (0.75, 0.5), "screen": "04-search", "cards": [
                ("07-autofill-picker", (0.0, 0.0, 0.52, 0.27), "box")]},
            "03-keepassxc": {"field": INDIGO, "focus": (0.6, 0.5), "screen": "03-database-details"},
            "04-security": {"field": PAPER, "focus": (0.6, 0.5), "screen": "02-unlock", "cards": [
                ("06-settings-security", (0.0, 0.0, 1.0, 0.37), "box")]},
            "05-everyday": {"field": INDIGO, "focus": (0.65, 0.5), "screen": "05-entry-edit"},
            "06-included": {"field": PAPER, "focus": (0.6, 0.5), "screen": "01-entry-detail", "checklist": 54},
        },
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


def resolve_inputs(input_dir, stems):
    """Returns ({stem: path}, [problems]) for the captures a listing needs."""
    index = indexed_inputs(input_dir)
    problems = []
    if SKIPPED_CAPTURES_STEM in index:
        problems.append(f"{SKIPPED_CAPTURES_STEM} is present: the capture run skipped screens; fix the harness and re-export")
    resolved = {}
    for stem in stems:
        images = sorted(path for path, suffix in index.get(stem, {}).items() if suffix.lower() in IMAGE_SUFFIXES)
        if len(images) == 1:
            resolved[stem] = images[0]
        elif images:
            problems.append(f"{stem} is ambiguous ({len(images)} captures: {', '.join(p.name for p in images)}); export a single run")
        else:
            problems.append(f"{stem} is missing")
    return resolved, problems


def needed_captures(spec):
    stems = []
    for frame in spec["frames"].values():
        for stem in [frame["screen"]] + [c[0] for c in frame.get("cards", [])]:
            if stem not in stems:
                stems.append(stem)
    return stems


def load_headlines(locale, platform):
    """{frame: (headline, subline or None)} for one locale; sublines exactly where the platform takes them."""
    table = json.loads(CAPTIONS_PATH.read_text(encoding="utf-8"))
    unknown = sorted(set(table) - set(LOCALES))
    if unknown:
        raise art.ArtError(f"{CAPTIONS_PATH.name}: captions for unshipped locales {unknown}")
    entries = table.get(locale)
    if entries is None:
        raise art.ArtError(f"{CAPTIONS_PATH.name}: no captions for {locale}")
    keys = {key.split("@")[0].split(":")[0] for key in entries}
    if keys != set(FRAMES):
        raise art.ArtError(f"{locale}: missing {sorted(set(FRAMES) - keys)}, unexpected {sorted(keys - set(FRAMES))}")
    takes_sub = "sub" in PLATFORMS[platform]
    copy = {}
    for frame in FRAMES:
        headline = entries.get(f"{frame}@{platform}", entries[frame])
        sub = entries.get(f"{frame}:sub@{platform}")
        items = entries.get(f"{frame}:list@{platform}", entries.get(f"{frame}:list"))
        if items is not None and not 2 <= len(items.split("\n")) <= 6:
            raise art.ArtError(f"{locale}: {frame} checklist must have 2-6 lines")
        if takes_sub != (sub is not None):
            raise art.ArtError(f"{locale}: {frame} {'needs' if takes_sub else 'has'} a {platform} subline")
        for text, most in ((headline, 3), (sub, 2)):
            lines = (text or "x").split("\n")
            if len(lines) > most or any(not line.strip() for line in lines):
                raise art.ArtError(f"{locale}: {text!r} must be 1-{most} non-empty lines")
        copy[frame] = (headline, sub, items.split("\n") if items else None)
    return copy


def plan_fonts(spec, locale, copy):
    """(headline font, subline font or None): one size each for every frame of a listing, the largest that fits."""
    w = spec["canvas"][0]
    width = round(w * spec["column"]) if spec["layout"] == "landscape" else w - 2 * spec["margin"]
    headline = art.fit("display", locale, [c[0] for c in copy.values()], spec["headline"][0], width, spec["headline"][1])
    subs = [c[1] for c in copy.values() if c[1]]
    sub = art.fit("text", locale, subs, spec["sub"][0], width, spec["sub"][1]) if subs else None
    return headline, sub


def lines_height(text, f, leading):
    return round(text.count("\n") * f.size * leading + f.size * 0.9)


def text_height(spec, copy, fonts):
    (headline, sub, _), (hf, sf) = copy, fonts
    height = lines_height(headline, hf, spec["leading"])
    if sub:
        height += round(hf.size * spec["sub_gap"]) + lines_height(sub, sf, spec["sub_leading"])
    return height


def layout(spec, frame, copy, fonts, captures, locale):
    """Every element's image and position for one frame; raises ArtError if it does not fit."""
    w, h = spec["canvas"]
    placed = []
    headline = copy[0]
    text_h = text_height(spec, copy, fonts)
    cards_spec = spec["cards"]

    if spec["layout"] == "portrait":
        text_origin = (spec["margin"], spec["top"])
        d = spec["device"]
        dev = art.device(captures[frame["screen"]], round(w * d["width"]), d["bezel"], d["radius"])
        # The device starts at the same height in every frame, below room for three headline lines.
        dev_origin = ((w - dev.width) // 2, spec["top"] + lines_height("\n\n", fonts[0], spec["leading"]) + d["gap"])
        if dev_origin[1] > h * d["max_top"]:
            raise art.ArtError(f"{headline!r} pushes the device below {d['max_top']:.0%} of the frame")
        placed.append(("device", dev, dev_origin))
        card_w, card_x = round(w * cards_spec["width"]), None
        floor = dev_origin[1] + (h - dev_origin[1]) * 0.3
    else:
        win_spec = spec["window"]
        win_w = round(w * win_spec["width"])
        with Image.open(captures[frame["screen"]]) as shot:
            ratio = shot.height / shot.width
        win_w = min(win_w, round(h * win_spec["max_height"] / ratio))
        win = art.window(captures[frame["screen"]], win_w)
        dev_origin = (w - win_spec["right"] - win.width, (h - win.height) // 2)
        placed.append(("window", win, dev_origin))
        text_origin = (spec["margin"], round(h * spec["text_top"]))
        if spec["margin"] + round(w * spec["column"]) + win_spec["gap"] > dev_origin[0]:
            raise art.ArtError("the headline column runs into the window")
        card_w, card_x = round(w * cards_spec["width"]), dev_origin[0] + round(w * cards_spec["x"])
        floor = h * 0.4

    y = h - cards_spec["bottom"]
    cards = []
    images = [art.card(captures[stem], hint, mode, card_w, cards_spec["radius"]) for stem, hint, mode in frame.get("cards", [])]
    if frame.get("checklist"):
        if not copy[2]:
            raise art.ArtError(f"{headline.splitlines()[0]!r} needs a checklist")
        images.insert(0, art.checklist_card(copy[2], card_w, locale, frame["checklist"], cards_spec["radius"]))
    for c in reversed(images):
        y -= c.height
        cards.append(("card", c, ((w - c.width) // 2 if card_x is None else card_x, y)))
        y -= cards_spec["gap"]
    if cards and cards[-1][2][1] < floor:
        raise art.ArtError(f"cards reach {cards[-1][2][1]}px, covering most of the {frame['screen']} screen")
    placed += reversed(cards)

    if frame.get("art") == "kdbx":
        a = spec["art"]
        doc = art.key_file(round(h * a["height"]))
        x = round(w * a["x"]) if a["x"] >= 0 else dev_origin[0] + round(w * a["x"])
        placed.append(("art", doc, (x, round(h * a["y"]))))

    text_box = (text_origin[0], text_origin[1], text_origin[0] + round(w * spec.get("column", 1)), text_origin[1] + text_h)
    for kind, image, (x, y) in placed:
        if kind != "device" and kind != "window" and x < text_box[2] and y < text_box[3] and x + image.width > text_box[0] and y + image.height > text_box[1]:
            raise art.ArtError(f"the {kind} overlaps the text of {headline.splitlines()[0]!r}")
    return text_origin, placed


def render(spec, frame, copy, fonts, locale, captures, output):
    w, h = spec["canvas"]
    field = art.background if frame["field"] == INDIGO else art.paper
    canvas = field((w, h), frame["focus"])
    text_origin, placed = layout(spec, frame, copy, fonts, captures, locale)
    for kind, image, origin in placed:
        if kind == "card":
            art.shadow_paste(canvas, image, origin, art.CARD_SHADOW["blur"], art.CARD_SHADOW["offset"], art.CARD_SHADOW["opacity"])
        else:
            art.shadow_paste(canvas, image, origin, 60, 36, 120)
    indigo = frame["field"] == INDIGO
    draw = ImageDraw.Draw(canvas)
    (headline, sub, _), (hf, sf) = copy, fonts
    art.draw_lines(draw, text_origin, headline, hf, art.PAPER if indigo else art.INK_TEXT, spec["leading"], locale, "display")
    if sub:
        y = text_origin[1] + lines_height(headline, hf, spec["leading"]) + round(hf.size * spec["sub_gap"])
        art.draw_lines(draw, (text_origin[0] + 4, y), sub, sf, art.GOLD_LIGHT if indigo else art.INK_MUTED, spec["sub_leading"], locale, "text")
    canvas.convert("RGB").save(output)


def display_path(path):
    return path.relative_to(REPO_ROOT) if path.is_relative_to(REPO_ROOT) else path


def composite(platform, input_root, output_root, locales):
    """Plans every requested locale before writing any, then renders; returns a process exit code."""
    spec = PLATFORMS[platform]
    stems = needed_captures(spec)
    plans = {}
    try:
        art.ensure_fonts()
        for locale in locales:
            resolved, problems = resolve_inputs(input_root / locale, stems)
            if problems:
                raise art.ArtError(f"{platform} {locale}: " + "; ".join(problems))
            copy = load_headlines(locale, platform)
            fonts = plan_fonts(spec, locale, copy)
            for name, frame in spec["frames"].items():
                layout(spec, frame, copy[name], fonts, resolved, locale)
            plans[locale] = (resolved, copy, fonts)
    except (InputError, art.ArtError) as error:
        print(f"error: {error}", file=sys.stderr)
        print(f"error: refusing to write a partial {platform} listing", file=sys.stderr)
        return 1

    for locale, (resolved, copy, fonts) in plans.items():
        out = output_root / locale
        out.mkdir(parents=True, exist_ok=True)
        report = {"platform": platform, "locale": locale, "canvas": list(spec["canvas"]), "headline_px": fonts[0].size,
                  "subline_px": fonts[1].size if fonts[1] else None, "frames": []}
        for name, frame in spec["frames"].items():
            render(spec, frame, copy[name], fonts, locale, resolved, out / f"{name}.png")
            sources = [frame["screen"]] + [c[0] for c in frame.get("cards", [])]
            report["frames"].append({
                "output": f"{name}.png",
                "headline": copy[name][0],
                "subline": copy[name][1],
                "sources": {stem: hashlib.sha256(resolved[stem].read_bytes()).hexdigest() for stem in dict.fromkeys(sources)},
            })
            print(f"Created {display_path(out / f'{name}.png')}")
        (out / "layout-report.json").write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        stale = sorted(p.name for p in out.glob("*.png") if p.stem not in spec["frames"])
        for name in stale:
            print(f"warning: {display_path(out / name)} is not part of this listing; do not upload it")
    print(f"\nDone! {platform}: {len(plans)} locale(s) in {display_path(output_root)}/<locale>/")
    return 0


def run(argv, **kwargs):
    print("+ " + " ".join(str(arg) for arg in argv), flush=True)
    return subprocess.run([str(arg) for arg in argv], check=True, **kwargs)


def capture_simulator(device):
    """Returns the UDID of an available simulator named `device`, creating it on the newest iOS runtime that supports it."""
    def simctl_json(*args):
        return json.loads(subprocess.run(["xcrun", "simctl", "list", "--json", *args], check=True, capture_output=True, text=True).stdout)

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
    return subprocess.run(["xcrun", "simctl", "create", device, kind["identifier"], runtime["identifier"]],
                          check=True, capture_output=True, text=True).stdout.strip()


def capture(locales, device, input_root):
    """Runs the iPhone capture classes once per locale on a local simulator and exports each run."""
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
    for locale in locales:
        bundle = input_root / f"{locale}.xcresult"
        export = input_root / locale
        shutil.rmtree(bundle, ignore_errors=True)
        shutil.rmtree(export, ignore_errors=True)
        run(common + ["test-without-building", *[f"-only-testing:{test}" for test in CAPTURE_TESTS],
                      "-testLanguage", locale, "-testRegion", LOCALES[locale], "-resultBundlePath", bundle], env=environment)
        run(["xcrun", "xcresulttool", "export", "attachments", "--path", bundle, "--output-path", export])
        _, problems = resolve_inputs(export, needed_captures(PLATFORMS["iphone"]))
        if problems:
            raise SystemExit(f"error: {locale} capture is incomplete: " + "; ".join(problems))
    run(["xcrun", "simctl", "status_bar", udid, "clear"])


def synthetic_capture(size, blocks):
    """A grouped-list capture with a white block (and a header label for "header" cards) at each hint."""
    w, h = size
    image = Image.new("RGB", size, (242, 242, 247))
    d = ImageDraw.Draw(image)
    for hint, mode in blocks:
        if mode == "box":
            continue
        x, y = hint
        top, bottom = round((y - 0.02) * h), round((y + 0.02) * h)
        d.rounded_rectangle([(round(w * 0.06), top), (round(w * 0.94), bottom)], radius=20, fill=(255, 255, 255))
        d.rectangle([(round(w * 0.1), top + 8), (round(w * 0.3), top + 20)], fill=(30, 30, 30))
        if mode == "header":
            d.rectangle([(round(w * 0.08), top - 40), (round(w * 0.3), top - 16)], fill=(130, 130, 135))
    return image


def self_test():
    """Lays out and renders every platform from synthetic captures, and checks the failure modes."""
    art.ensure_fonts()
    with tempfile.TemporaryDirectory() as temp:
        root = Path(temp)
        for platform, spec in PLATFORMS.items():
            size = (2880, 1800) if platform == "mac" else spec["canvas"]
            blocks = {}
            for frame in spec["frames"].values():
                blocks.setdefault(frame["screen"], [])
                for stem, hint, mode in frame.get("cards", []):
                    blocks.setdefault(stem, []).append((hint, mode))
            captures = root / platform / "en"
            captures.mkdir(parents=True)
            for stem, hints in blocks.items():
                synthetic_capture(size, hints).save(captures / f"{stem}.png")
            out = root / f"out-{platform}"
            assert composite(platform, root / platform, out, ["en"]) == 0, platform
            for name in spec["frames"]:
                with Image.open(out / "en" / f"{name}.png") as image:
                    assert image.size == spec["canvas"] and image.mode == "RGB", (platform, name, image.size, image.mode)

            # A missing capture or a skipped-captures report writes nothing.
            first = next(captures.iterdir())
            partial = root / f"{platform}-partial" / "en"
            shutil.copytree(captures, partial)
            (partial / first.name).unlink()
            assert composite(platform, partial.parent, root / f"out-{platform}-partial", ["en"]) == 1
            assert not (root / f"out-{platform}-partial").exists()
            (captures / f"{SKIPPED_CAPTURES_STEM}.txt").write_text("skipped")
            assert composite(platform, root / platform, root / f"out-{platform}-skipped", ["en"]) == 1

        # Cards are found from a hint, row by row; a hint off any white row fails.
        listing = synthetic_capture((1320, 2868), [((0.5, 0.5), "header")])
        left, top, right, bottom = art.find_card(listing, (0.5, 0.5), "section")
        assert abs(left - 79) <= 1 and abs(right - 1242) <= 1 and bottom - top > 100, (left, top, right, bottom)
        assert art.find_card(listing, (0.5, 0.5), "header")[1] < top
        for hint in [(0.5, 0.1), (0.02, 0.5)]:
            try:
                art.find_card(listing, hint, "row")
            except art.ArtError:
                pass
            else:
                raise AssertionError(f"{hint} must fail")

        # Every captioned locale fits every platform in its own fonts.
        table = json.loads(CAPTIONS_PATH.read_text(encoding="utf-8"))
        for locale in table:
            for platform, spec in PLATFORMS.items():
                plan_fonts(spec, locale, load_headlines(locale, platform))
        latin = art.font("display", "en", 100)
        assert art.missing_glyphs(latin, "Ab·") == [] and art.missing_glyphs(latin, "Ж保") == ["Ж", "保"]
        assert art.missing_glyphs(art.font("display", "ru", 100), "Пароли") == []
        try:
            art.fit("display", "en", ["One Two Three Four Five Six Seven"], 176, 1100, 112)
        except art.ArtError:
            pass
        else:
            raise AssertionError("an overlong headline must fail")
    print("self-test passed")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--platform", choices=sorted(PLATFORMS), default="iphone")
    parser.add_argument("--input-dir", type=Path, help="parent of the per-locale capture folders (default: the platform's)")
    parser.add_argument("--output-dir", type=Path, help="where to write <locale>/ listings (default: the platform's)")
    parser.add_argument("--locale", action="append", choices=list(LOCALES), help="repeatable; default: every shipped locale")
    parser.add_argument("--capture", action="store_true", help="iPhone only: capture each locale on a local simulator first")
    parser.add_argument("--device", default=CAPTURE_DEVICE, help=f"simulator for --capture (default: {CAPTURE_DEVICE})")
    parser.add_argument("--self-test", action="store_true", help="check layout and failure modes on synthetic captures and exit")
    args = parser.parse_args()

    if args.self_test:
        self_test()
        return 0
    if args.capture and args.platform != "iphone":
        parser.error("--capture applies to the iPhone listing only; capture iPad and Mac with studio-test")
    spec = PLATFORMS[args.platform]
    input_root = (args.input_dir or spec["input_dir"]).resolve()
    locales = args.locale or list(LOCALES)
    if args.capture:
        capture(locales, args.device, input_root)
    return composite(args.platform, input_root, (args.output_dir or spec["output_dir"]).resolve(), locales)


if __name__ == "__main__":
    sys.exit(main())
