#!/usr/bin/env python3
"""Generate polished App Store screenshots with gradient backgrounds and taglines.

Two listings, two platforms, one compositor:

    ci_scripts/make_appstore_screenshots.py            # iPhone (default)
    ci_scripts/make_appstore_screenshots.py --platform mac

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

Both classes skip by default (see their doc comments), and both gate variables
must be real environment variables on the xcodebuild process -- Xcode strips the
TEST_RUNNER_ prefix and forwards them into the test runner, whereas a trailing
bare KEY=value argument becomes a build-setting override that never arrives and
the class silently skips. Without them this script has nothing to composite.

The Mac audit harness additionally needs Screen Recording permission for
`KeeForgeMacUITests-Runner`, and reports anything it could not capture in its
`00-skipped-captures` attachment (see KeeForgeMacUITests/README.md). A short
export is a harness problem, not a missing screen.
"""

import argparse
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont


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
        "canvas": (2880, 1800),
        "input_dir": REPO_ROOT / "build" / "screenshots-mac",
        "output_dir": REPO_ROOT / "build" / "appstore-mac",
        # A Mac window is already rounded in the capture; a large radius would
        # cut into its titlebar.
        "corner_radius": 20,
        "font_size": 104,
        # Filenames are the MacScreenshotAuditUITests attachment names. That
        # walk captures more screens than a listing wants; the ones left out
        # here are audit-only and simply skipped.
        "screens": [
            ("01-database-list.png", "Local + Cloud Vaults, One Home Screen", (26, 31, 61), (18, 22, 48)),
            ("02-unlock.png", "Unlock Fast, Stay Secure", (41, 98, 255), (30, 70, 220)),
            ("03-vault-root.png", "Three Columns, Everything in Reach", (0, 150, 136), (0, 110, 100)),
            ("04-group-selected.png", "Organize Everything in One Place", (31, 94, 58), (20, 63, 38)),
            ("05-entry-detail.png", "Reveal Passwords, Copy What You Need", (220, 80, 60), (180, 40, 30)),
            ("06-search.png", "Search Your Vault in Seconds", (30, 130, 230), (20, 90, 190)),
            ("08-entry-editor-sheet.png", "Create and Edit Entries on Mac", (130, 80, 220), (90, 40, 180)),
        ],
    },
}


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
    is_landscape = canvas_w > canvas_h
    canvas = make_gradient(canvas_w, canvas_h, color_top, color_bottom).convert("RGBA")

    screenshot = Image.open(screen_path).convert("RGBA")

    # Portrait bleeds the device off the bottom edge; a Mac window is a window
    # and has to sit whole on the canvas, so it gets a margin on every side.
    if is_landscape:
        max_screenshot_w = int(canvas_w * 0.86)
        max_screenshot_h = int(canvas_h * 0.68)
    else:
        max_screenshot_w = int(canvas_w * 0.92)
        max_screenshot_h = int(canvas_h * 0.82)

    scale = min(max_screenshot_w / screenshot.width, max_screenshot_h / screenshot.height)
    new_w = int(screenshot.width * scale)
    new_h = int(screenshot.height * scale)
    screenshot = screenshot.resize((new_w, new_h), Image.LANCZOS)

    screenshot = add_rounded_corners(screenshot, radius=spec["corner_radius"])
    screenshot_with_shadow = add_shadow(screenshot, offset=12, blur_radius=25, opacity=60)

    x = (canvas_w - screenshot_with_shadow.width) // 2
    if is_landscape:
        y = canvas_h - screenshot_with_shadow.height - int(canvas_h * 0.06)
    else:
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
    print(f"Created {output_path.relative_to(REPO_ROOT)} ({canvas.width}x{canvas.height})")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--platform",
        choices=sorted(PLATFORMS),
        default="iphone",
        help="which listing to composite for (default: iphone)",
    )
    args = parser.parse_args()

    spec = PLATFORMS[args.platform]
    input_dir = spec["input_dir"]
    output_dir = spec["output_dir"]
    output_dir.mkdir(parents=True, exist_ok=True)

    missing = []
    for filename, tagline, color_top, color_bottom in spec["screens"]:
        input_path = input_dir / filename
        output_path = output_dir / filename
        if input_path.exists():
            create_screenshot(input_path, tagline, color_top, color_bottom, output_path, spec)
        else:
            missing.append(filename)
            print(f"Skipping {filename} -- not found")

    print(f"\nDone! Screenshots in {output_dir.relative_to(REPO_ROOT)}/")
    if missing:
        # Said out loud rather than left to the eye: a listing short a screen
        # because an export was incomplete looks exactly like one that was
        # meant to be short.
        print(
            f"warning: {len(missing)} of {len(spec['screens'])} screens were missing from "
            f"{input_dir.relative_to(REPO_ROOT)}/ -- re-export the capture run before uploading."
        )


if __name__ == "__main__":
    main()
