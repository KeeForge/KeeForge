#!/usr/bin/env python3
"""Render the App Store product page header and search results creative.

    ci_scripts/make_store_creative.py --captures DIR [--locale en ...] [--output-dir DIR]

Both use the listing screenshots' type and palette (store_art.py): Newsreader
headlines and Instrument Sans text on the icon's indigo, with real UI captures from
`AppStoreScreenshots` / `AppStoreAutoFillScreenshot` inside simple device frames.
`--captures` holds one directory per platform and locale (`iphone-<locale>/`,
`ipad-<locale>/`, `mac-<locale>/`) with plainly named captures (`03-vault-groups.png`, ...).
Copy lives in appstore_creative.json (locale -> key -> text).

Header: 21:9, 3840x1646. Search results: 3:2, 3840x2560. Apple's creative
guidance applies: no prices, URLs, other platforms' logos or award badges, and
no alpha channel.
"""

import argparse
import json
import sys
from pathlib import Path

from PIL import Image, ImageDraw

import store_art as art

REPO_ROOT = Path(__file__).resolve().parents[1]
COPY_PATH = Path(__file__).resolve().with_name("appstore_creative.json")
ICON_PATH = REPO_ROOT / ".github" / "assets" / "KeeForge-iOS-Default-1024x1024@1x.png"

HEADER = (3840, 1646)
SEARCH = (3840, 2560)


def header(locale, copy, captures, out):
    """One file, every device: a centred headline over the Mac, iPad and iPhone, with the .kdbx in front.

    Apple crops the header on narrow screens, so everything stays in the middle 60%.
    """
    w, h = HEADER
    canvas = art.background(HEADER, (0.5, 0.62))
    d = ImageDraw.Draw(canvas)
    title = art.fit("display", locale, copy["header_title"], 190, round(w * 0.58), 110)
    sub = art.fit("text", locale, copy["header_subtitle"], 72, round(w * 0.5), 44)
    d.text((w / 2, round(h * 0.1)), copy["header_title"], font=title, fill=art.PAPER, anchor="mt",
           stroke_width=art.stroke("display", locale), stroke_fill=art.PAPER)
    d.text((w / 2, round(h * 0.1) + round(title.size * 1.12)), copy["header_subtitle"], font=sub, fill=art.GOLD_LIGHT, anchor="mt",
           stroke_width=art.stroke("text", locale), stroke_fill=art.GOLD_LIGHT)

    floor = round(h * 0.94)
    mac = art.laptop(captures / f"mac-{locale}" / "01-entry-detail.png", round(w * 0.34))
    mac_x = (w - mac.width) // 2
    ipad = art.device(captures / f"ipad-{locale}" / "06-entry-detail.png", round(w * 0.15), 14, 44)
    iphone = art.device(captures / f"iphone-{locale}" / "03-vault-groups.png", round(w * 0.076), 11, 62)
    doc = art.key_file(round(h * 0.3))
    art.shadow_paste(canvas, mac, (mac_x, floor - mac.height), 60, 30, 120)
    art.shadow_paste(canvas, ipad, (mac_x - round(ipad.width * 0.45), floor - ipad.height), 50, 28)
    art.shadow_paste(canvas, iphone, (mac_x + mac.width - round(iphone.width * 0.45), floor - iphone.height), 40, 24)
    art.shadow_paste(canvas, doc, (round(w * 0.5 - doc.width * 0.3), floor - doc.height), 40, 24)
    left = mac_x - round(ipad.width * 0.45)
    if left < w * 0.2:
        raise art.ArtError(f"{locale}: the device group reaches outside the header's centre")

    canvas.convert("RGB").save(out)
    return out


def search(locale, copy, captures, out):
    """Every feature included: the checklist of what other KeePass apps charge for, beside an iPhone."""
    w, h = SEARCH
    canvas = art.paper(SEARCH, (0.3, 0.4))
    d = ImageDraw.Draw(canvas)
    left = round(w * 0.065)

    title = art.fit("display", locale, copy["search_title"], 240, round(w * 0.5), 120)
    y = art.draw_lines(d, (left, round(h * 0.09)), copy["search_title"], title, art.INK_TEXT, 1.02, locale, "display")

    checklist = art.checklist_card(copy["checklist"], round(w * 0.5), locale, 80, 56)
    art.shadow_paste(canvas, checklist, (left, y + round(h * 0.05)), 60, 30, 90)

    icon = art.rounded(Image.open(ICON_PATH).convert("RGB").resize((250, 250), Image.LANCZOS), 56)
    icon_y = round(h * 0.84)
    art.shadow_paste(canvas, icon, (left, icon_y), 26, 14, 80)
    d.text((left + 300, icon_y + 125), "KeeForge", font=art.font("text", "en", 112), fill=art.INK_TEXT, anchor="lm")

    phone = art.device(captures / f"iphone-{locale}" / "01-database-list.png", round(w * 0.27), 24, 130)
    art.shadow_paste(canvas, phone, (round(w * 0.645), round(h * 0.06)), 60, 36, 120)
    doc = art.key_file(round(h * 0.28))
    art.shadow_paste(canvas, doc, (round(w * 0.79), round(h * 0.6)), 40, 24)

    canvas.convert("RGB").save(out)
    return out


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--captures", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, default=REPO_ROOT / "build" / "appstore-creative")
    parser.add_argument("--locale", action="append")
    args = parser.parse_args(argv)
    art.ensure_fonts()
    table = json.loads(COPY_PATH.read_text(encoding="utf-8"))
    for locale in args.locale or list(table):
        out = args.output_dir / locale
        out.mkdir(parents=True, exist_ok=True)
        print(header(locale, table[locale], args.captures, out / "header-21x9.png"))
        print(search(locale, table[locale], args.captures, out / "search-3x2.png"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
