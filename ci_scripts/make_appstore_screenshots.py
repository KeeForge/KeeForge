#!/usr/bin/env python3
"""Generate polished App Store screenshots with gradient backgrounds and taglines.

Prerequisite (not automated by this script): capture the raw screenshots by
running the opt-in `KeeForgeUITests/AppStoreScreenshots` UI test class and
exporting its attachments into `build/screenshots`:

    TEST_RUNNER_APPSTORE_SCREENSHOTS=1 xcodebuild test -project KeeForge.xcodeproj \\
        -scheme KeeForge -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \\
        -only-testing:KeeForgeUITests/AppStoreScreenshots
    xcrun xcresulttool export attachments --path <xcresult> --output-path build/screenshots

The class skips by default (see its doc comment); TEST_RUNNER_APPSTORE_SCREENSHOTS
must be a real environment variable on the xcodebuild process (Xcode strips the
TEST_RUNNER_ prefix and forwards it into the test runner) -- passing it as a
trailing bare KEY=value argument does not work and the test silently skips.
Without it, this script has nothing to composite.
"""

from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont


REPO_ROOT = Path(__file__).resolve().parents[1]
SCREENSHOTS_DIR = REPO_ROOT / "build" / "screenshots"
OUTPUT_DIR = REPO_ROOT / "build" / "appstore"

# App Store 6.9" display size (iPhone 15/16 Pro Max)
CANVAS_W, CANVAS_H = 1320, 2868

# Taglines for each screenshot
SCREENS = [
    ("01-database-list.png", "Local + Cloud Vaults,\nOne Home Screen", (26, 31, 61), (18, 22, 48)),
    ("02-unlock-screen.png", "Unlock Fast,\nStay Secure", (41, 98, 255), (30, 70, 220)),
    ("03-vault-groups.png", "Organize Everything\nin One Place", (0, 150, 136), (0, 110, 100)),
    ("04-database-settings.png", "Tune Each Vault\nYour Way", (31, 94, 58), (20, 63, 38)),
    ("05-entry-list.png", "All Your Accounts,\nAlways Accessible", (130, 80, 220), (90, 40, 180)),
    ("06-entry-detail.png", "Reveal Passwords,\nCopy What You Need", (220, 80, 60), (180, 40, 30)),
    ("07-entry-edit.png", "Create and Edit\nEntries on iPhone", (60, 60, 60), (30, 30, 30)),
    ("08-search.png", "Search Your Vault\nin Seconds", (30, 130, 230), (20, 90, 190)),
]


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


def create_screenshot(screen_path, tagline, color_top, color_bottom, output_path):
    """Create a single polished App Store screenshot."""
    canvas = make_gradient(CANVAS_W, CANVAS_H, color_top, color_bottom).convert("RGBA")

    screenshot = Image.open(screen_path).convert("RGBA")

    max_screenshot_w = int(CANVAS_W * 0.92)
    max_screenshot_h = int(CANVAS_H * 0.82)

    scale = min(max_screenshot_w / screenshot.width, max_screenshot_h / screenshot.height)
    new_w = int(screenshot.width * scale)
    new_h = int(screenshot.height * scale)
    screenshot = screenshot.resize((new_w, new_h), Image.LANCZOS)

    screenshot = add_rounded_corners(screenshot, radius=44)
    screenshot_with_shadow = add_shadow(screenshot, offset=12, blur_radius=25, opacity=60)

    x = (CANVAS_W - screenshot_with_shadow.width) // 2
    y = CANVAS_H - screenshot_with_shadow.height + 80
    canvas.paste(screenshot_with_shadow, (x, y), screenshot_with_shadow)

    font = load_font(88)
    draw = ImageDraw.Draw(canvas)

    text_bbox = draw.multiline_textbbox((0, 0), tagline, font=font, align="center")
    text_w = text_bbox[2] - text_bbox[0]
    text_h = text_bbox[3] - text_bbox[1]
    text_x = (CANVAS_W - text_w) // 2
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
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    for filename, tagline, color_top, color_bottom in SCREENS:
        input_path = SCREENSHOTS_DIR / filename
        output_path = OUTPUT_DIR / filename
        if input_path.exists():
            create_screenshot(input_path, tagline, color_top, color_bottom, output_path)
        else:
            print(f"Skipping {filename} -- not found")

    print(f"\nDone! Screenshots in {OUTPUT_DIR.relative_to(REPO_ROOT)}/")


if __name__ == "__main__":
    main()
