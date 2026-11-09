"""Shared drawing kit for KeeForge App Store art: fonts, palette, devices, UI cards.

`make_appstore_screenshots.py` (listing screenshots) and `make_store_creative.py`
(product page header, search results art) both draw with it, so every marketing
image shares one type system and palette: Newsreader headlines and Instrument Sans
labels, as on keeforge.com, in the app icon's indigo, paper and brass.

Newsreader, Instrument Sans, Source Serif 4 and Inter (SIL OFL) are fetched once
from a pinned google/fonts commit into build/fonts/ and checked against SHA-256.
Russian falls back to Source Serif 4 and Inter, which have Cyrillic; Japanese and
Chinese use the macOS Mincho, Song and Gothic faces.
"""

import hashlib
import urllib.parse
import urllib.request
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

REPO_ROOT = Path(__file__).resolve().parents[1]
FONT_DIR = REPO_ROOT / "build" / "fonts"
SYSTEM_FONTS = Path("/System/Library/Fonts")

GOOGLE_FONTS_COMMIT = "5bb28733cec313b63fbd415b574b5ae35c8aa8b8"
FONT_FILES = {
    "Newsreader[opsz,wght].ttf": ("ofl/newsreader", "8a08d13f8a6c0d51be379a60af84f945f65369a67e509ee3c3bdcc421254d7c1"),
    "InstrumentSans[wdth,wght].ttf": ("ofl/instrumentsans", "b24f1812584816958afcf22e22d08e44318c5e51651e25d2438efdde389b33b1"),
    "SourceSerif4[opsz,wght].ttf": ("ofl/sourceserif4", "97b2d4da6e3cb494b5a1e66ae176914d852ccabef49e0c02c0df25f3e39aca0b"),
    "Inter[opsz,wght].ttf": ("ofl/inter", "29160a80ff49ddcab2c97711247e08b1fab27a484a329ce8b813d820dc559031"),
}

# role -> locale -> (file, collection index, variation axes by name, stroke px)
FACES = {
    "display": {
        "default": ("Newsreader[opsz,wght].ttf", 0, {"Weight": 500, "Optical Size": 72}, 0),
        "ru": ("SourceSerif4[opsz,wght].ttf", 0, {"Weight": 560, "Optical Size": 60}, 0),
        "ja": (SYSTEM_FONTS / "ヒラギノ明朝 ProN.ttc", 2, None, 0),
        "zh-Hans": (SYSTEM_FONTS / "Supplemental" / "Songti.ttc", 1, None, 0),
        "zh-Hant": (SYSTEM_FONTS / "Supplemental" / "Songti.ttc", 2, None, 0),
    },
    "text": {
        "default": ("InstrumentSans[wdth,wght].ttf", 0, {"Width": 100, "Weight": 600}, 0),
        "ru": ("Inter[opsz,wght].ttf", 0, {"Optical size": 32, "Weight": 600}, 0),
        "ja": (SYSTEM_FONTS / "ヒラギノ角ゴシック W6.ttc", 0, None, 0),
        "zh-Hans": (SYSTEM_FONTS / "Hiragino Sans GB.ttc", 2, None, 0),
        "zh-Hant": (SYSTEM_FONTS / "STHeiti Medium.ttc", 0, None, 1),
    },
}

INK_CENTER = (52, 56, 122)
INK_EDGE = (20, 21, 48)
PAPER = (246, 243, 234)
PAPER_GLOW = (238, 224, 186)
GOLD = (216, 178, 90)
GOLD_LIGHT = (241, 215, 146)
INK_TEXT = (35, 38, 79)
INK_MUTED = (84, 88, 132)
CARD_SHADOW = {"blur": 50, "offset": 24, "opacity": 46}


class ArtError(Exception):
    pass


def ensure_fonts():
    """Downloads any missing pinned font into build/fonts/ and verifies every file."""
    FONT_DIR.mkdir(parents=True, exist_ok=True)
    for name, (folder, digest) in FONT_FILES.items():
        path = FONT_DIR / name
        if not path.exists():
            url = (f"https://raw.githubusercontent.com/google/fonts/{GOOGLE_FONTS_COMMIT}/"
                   + urllib.parse.quote(f"{folder}/{name}"))
            with urllib.request.urlopen(url, timeout=60) as response:
                data = response.read()
            if hashlib.sha256(data).hexdigest() != digest:
                raise ArtError(f"{name}: download does not match its pinned SHA-256")
            path.write_bytes(data)
        elif hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            raise ArtError(f"{path} does not match its pinned SHA-256; delete it to re-fetch")


def face(role, locale):
    return FACES[role].get(locale, FACES[role]["default"])


def font(role, locale, size):
    file, index, axes, _ = face(role, locale)
    path = file if isinstance(file, Path) else FONT_DIR / file
    loaded = ImageFont.truetype(str(path), size, index=index)
    if axes:
        names = [axis["name"].decode() if isinstance(axis["name"], bytes) else axis["name"]
                 for axis in loaded.get_variation_axes()]
        loaded.set_variation_by_axes([axes[name] for name in names])
    return loaded


def stroke(role, locale):
    return face(role, locale)[3]


def missing_glyphs(f, text):
    """Characters the font draws as its .notdef box (tofu)."""
    def mask(ch):
        image = f.getmask(ch)
        return image.size, bytes(image)

    notdef = mask("\U000F0000")
    return sorted({ch for ch in text if not ch.isspace() and mask(ch) == notdef})


def fit(role, locale, texts, size, max_width, min_size):
    """Largest size <= size at which every line of every text fits max_width, with every glyph present."""
    texts = [texts] if isinstance(texts, str) else list(texts)
    missing = missing_glyphs(font(role, locale, size), "".join(texts))
    if missing:
        raise ArtError(f"{locale}: {role} font has no glyph for {''.join(missing)!r}")
    for s in range(size, min_size - 1, -2):
        f = font(role, locale, s)
        if all(f.getlength(line) + 2 * stroke(role, locale) <= max_width for text in texts for line in text.split("\n")):
            return f
    widest = max((line for text in texts for line in text.split("\n")), key=font(role, locale, min_size).getlength)
    raise ArtError(f"{locale}: {widest!r} is wider than {max_width}px even at {min_size}px")


def draw_lines(draw, origin, text, f, fill, leading, locale="en", role="text"):
    """Left-aligned lines at `leading` x font size; returns the y below the last line."""
    x, y = origin
    width = stroke(role, locale)
    for line in text.split("\n"):
        draw.text((x, y), line, font=f, fill=fill, stroke_width=width, stroke_fill=fill)
        y += round(f.size * leading)
    return y


def kicker(draw, origin, text, f, on_dark, locale="en"):
    """A short label in a pill: brass on indigo, ink on paper. Returns the pill's bottom y."""
    x, y = origin
    pad = round(f.size * 0.68)
    height = round(f.size * 1.9)
    width = round(f.getlength(text)) + 2 * pad
    fill, ink = (GOLD_LIGHT, INK_TEXT) if on_dark else (INK_TEXT, PAPER)
    draw.rounded_rectangle([(x, y), (x + width, y + height)], radius=height // 2, fill=fill)
    draw.text((x + width / 2, y + height / 2), text, font=f, fill=ink, anchor="mm",
              stroke_width=stroke("text", locale), stroke_fill=ink)
    return y + height


def _radial(size, focus, center, edge, reach):
    w, h = size
    small = Image.new("RGB", (max(1, w // 8), max(1, h // 8)))
    px = small.load()
    fx, fy = focus[0] * small.width, focus[1] * small.height
    radius = max(small.width, small.height) * reach
    for y in range(small.height):
        for x in range(small.width):
            t = min(1.0, ((x - fx) ** 2 + (y - fy) ** 2) ** 0.5 / radius)
            t = t * t * (3 - 2 * t)
            px[x, y] = tuple(round(c + (e - c) * t) for c, e in zip(center, edge))
    return small.resize(size, Image.BICUBIC).convert("RGBA")


def background(size, focus):
    """Radial indigo field, lighter around `focus` (fractions of width and height)."""
    return _radial(size, focus, INK_CENTER, INK_EDGE, 0.75)


def paper(size, focus):
    """Warm paper field with a faint brass glow around `focus`."""
    return _radial(size, focus, PAPER_GLOW, PAPER, 0.7)


def rounded(image, radius):
    mask = Image.new("L", image.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([(0, 0), (image.width - 1, image.height - 1)], radius=radius, fill=255)
    out = image.convert("RGBA")
    if image.mode == "RGBA":
        mask = Image.composite(image.getchannel("A"), Image.new("L", image.size, 0), mask)
    out.putalpha(mask)
    return out


def shadow_paste(canvas, image, origin, blur, offset, opacity=110):
    pad = blur * 2
    shadow = Image.new("RGBA", (image.width + pad * 2, image.height + pad * 2), (0, 0, 0, 0))
    alpha = image.getchannel("A").point(lambda a: a * opacity // 255)
    shadow.paste((0, 0, 0, 255), (pad, pad), alpha)
    shadow = shadow.filter(ImageFilter.GaussianBlur(blur))
    canvas.alpha_composite(shadow, (origin[0] - pad, origin[1] - pad + offset))
    canvas.alpha_composite(image, origin)


def device(capture, width, bezel, radius):
    """A capture inside a dark rounded bezel, `width` px wide overall."""
    shot = capture if isinstance(capture, Image.Image) else Image.open(capture)
    shot = shot.convert("RGB")
    inner_w = width - 2 * bezel
    inner_h = round(shot.height * inner_w / shot.width)
    shot = rounded(shot.resize((inner_w, inner_h), Image.LANCZOS), max(radius - bezel, 0))
    body = Image.new("RGBA", (width, inner_h + 2 * bezel), (0, 0, 0, 0))
    ImageDraw.Draw(body).rounded_rectangle([(0, 0), (body.width - 1, body.height - 1)], radius=radius, fill=(12, 13, 26, 255))
    body.alpha_composite(shot, (bezel, bezel))
    return body


def window(capture, width):
    """A Mac window capture at most `width` wide, keeping its own rounded-corner alpha; never upscaled."""
    shot = Image.open(capture).convert("RGBA")
    width = min(width, shot.width)
    return shot.resize((width, round(shot.height * width / shot.width)), Image.LANCZOS)


def key_file(height):
    """The .kdbx document with the brass key: the brand's 'your file' motif."""
    w, h = round(height * 0.75), height
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    fold = round(w * 0.26)
    d.rounded_rectangle([(0, 0), (w - 1, h - 1)], radius=round(w * 0.07), fill=PAPER + (255,))
    d.polygon([(w - fold, 0), (w, 0), (w, fold)], fill=(0, 0, 0, 0))
    d.polygon([(w - fold, 0), (w - fold, fold), (w, fold)], fill=(214, 205, 179, 255))
    cx, top = w / 2, h * 0.17
    ring_r, ring_t = w * 0.19, w * 0.07
    d.ellipse([(cx - ring_r, top), (cx + ring_r, top + 2 * ring_r)], outline=GOLD, width=round(ring_t))
    shaft_w = w * 0.075
    shaft_top, shaft_bot = top + 2 * ring_r - ring_t * 0.5, h * 0.74
    d.rounded_rectangle([(cx - shaft_w / 2, shaft_top), (cx + shaft_w / 2, shaft_bot)], radius=round(shaft_w * 0.25), fill=GOLD)
    for i, bit_w in enumerate((0.13, 0.09)):
        y = shaft_bot - (0.12 - i * 0.075) * h
        d.rectangle([(cx + shaft_w / 2 - 2, y), (cx + shaft_w / 2 + w * bit_w, y + w * 0.06)], fill=GOLD)
    d.text((cx, h * 0.89), ".kdbx", font=font("text", "en", round(w * 0.12)), fill=INK_TEXT, anchor="mm")
    return img


# --- UI cards cut from real captures -------------------------------------------------
#
# Grouped lists draw white rows on a flat backdrop. A card is located from a hint
# point inside it, so a localized capture whose rows shift a little still yields
# the right row; the backdrop colour is read from the capture itself.

def _close(a, b, tolerance=3):
    return all(abs(x - y) <= tolerance for x, y in zip(a, b))


def _is_white(p):
    return min(p[:3]) >= 250


def find_card(image, hint, mode):
    """Crop box of the UI block around `hint` (fractions of the capture).

    mode "row": one row between separators; "section": the whole white group;
    "header": the group plus the section header label above it, on its backdrop.
    """
    img = image.convert("RGB")
    px = img.load()
    w, h = img.size
    hx, hy = round(hint[0] * w), round(hint[1] * h)
    if not _is_white(px[hx, hy]):
        raise ArtError(f"card hint {hint} is not on a white row")

    def walk(x, y, dx, dy):
        while 0 <= x + dx < w and 0 <= y + dy < h and not _close(px[x + dx, y + dy], backdrop):
            x, y = x + dx, y + dy
        return x, y

    # The backdrop is the first light, flat, non-white run left of the hint; list backdrops
    # sit near 242, and the floor keeps long CJK strokes in grey labels from passing for one.
    backdrop = None
    for x in range(hx, 24, -1):
        p = px[x, hy]
        if not _is_white(p) and min(p[:3]) >= 225 and all(px[x - k, hy] == p for k in range(1, 24)):
            backdrop = p
            break
    if backdrop is None:
        raise ArtError(f"card hint {hint} has no list backdrop to its left")
    # Grey text can match the backdrop, so take the widest extent over a few lines.
    lines = [y for y in (hy - 12, hy - 6, hy, hy + 6, hy + 12) if _is_white(px[hx, y])]
    left = min(walk(hx, y, -1, 0)[0] for y in lines)
    right = max(walk(hx, y, 1, 0)[0] for y in lines)
    probe = right - round((right - left) * 0.04) - 40
    top = walk(probe, hy, 0, -1)[1]
    bottom = walk(probe, hy, 0, 1)[1]
    if right - left < w * 0.2 or bottom - top < 30:
        raise ArtError(f"card hint {hint} found no white group ({left},{top},{right},{bottom})")

    if mode == "section":
        return left, top, right + 1, bottom + 1
    if mode == "row":
        span = range(left + round((right - left) * 0.3), right - round((right - left) * 0.1))
        separators = [y for y in range(top + 2, bottom - 1)
                      if all(200 <= px[x, y][0] <= 240 for x in span[::7])
                      and max(px[x, y][0] for x in span[::7]) - min(px[x, y][0] for x in span[::7]) <= 6]
        above = max((y for y in separators if y < hy), default=top - 1)
        below = min((y for y in separators if y > hy), default=bottom + 1)
        return left, above + 1, right + 1, below
    if mode == "header":
        y = top - 1
        while y > 0 and _close(px[probe, y], backdrop) and all(_close(px[x, y], backdrop) for x in range(left, right, 9)):
            y -= 1
        label_bottom = y
        while y > 0 and not all(_close(px[x, y], backdrop) for x in range(left, right, 9)):
            y -= 1
        if top - label_bottom > h * 0.05 or label_bottom - y < 10:
            raise ArtError(f"card hint {hint} has no section header above it")
        pad = round((right - left) * 0.035)
        mid = (top + bottom) // 2
        # Keep the margin on the backdrop: a split-view pane ends close to its rows.
        while pad > 0 and not (left - pad >= 0 and right + pad < w
                               and _close(px[left - pad, mid], backdrop) and _close(px[right + pad, mid], backdrop)):
            pad -= 2
        pad = max(pad, 0)
        return left - pad, y - pad, right + 1 + pad, bottom + 1 + pad
    raise ValueError(mode)


def card(capture, hint, mode, width, radius):
    """A real UI block cut from a capture and scaled to `width`, as a floating card.

    mode "box" takes `hint` as a fixed (left, top, right, bottom) region in fractions,
    for fixed-size windows that are not grouped lists (the Mac AutoFill picker, Settings).
    """
    with Image.open(capture) as image:
        if mode == "box":
            w, h = image.size
            box = (round(hint[0] * w), round(hint[1] * h), round(hint[2] * w), round(hint[3] * h))
        else:
            box = find_card(image, hint, mode)
        crop = image.convert("RGB").crop(box)
    if crop.width < width * 0.75:
        raise ArtError(f"{Path(capture).name}: card is {crop.width}px wide, too small to show at {width}px")
    crop = crop.resize((width, round(crop.height * width / crop.width)), Image.LANCZOS)
    return rounded(crop, radius)


def checklist_card(items, width, locale, size, radius):
    """An ink card listing included features, each behind a brass check mark."""
    f = fit("text", locale, items, size, round(width * 0.78), round(size * 0.6))
    pad, step = round(f.size * 1.1), round(f.size * 1.75)
    card = Image.new("RGBA", (width, 2 * pad + step * (len(items) - 1) + f.size), (0, 0, 0, 0))
    d = ImageDraw.Draw(card)
    d.rounded_rectangle([(0, 0), (width - 1, card.height - 1)], radius=radius, fill=INK_TEXT + (255,))
    mark = round(f.size * 0.62)
    for i, item in enumerate(items):
        cy = pad + i * step + f.size / 2
        x0 = pad
        d.line([(x0, cy), (x0 + mark * 0.38, cy + mark * 0.38), (x0 + mark, cy - mark * 0.5)],
               fill=GOLD, width=max(3, round(f.size * 0.13)), joint="curve")
        d.text((x0 + mark + round(f.size * 0.7), cy), item, font=f, fill=PAPER, anchor="lm",
               stroke_width=stroke("text", locale), stroke_fill=PAPER)
    return card


def laptop(capture, width):
    """A Mac window capture on a simple laptop: dark display bezel above an aluminium base."""
    bezel = round(width * 0.022)
    screen_w = width - 2 * bezel
    shot = Image.open(capture).convert("RGB")
    screen_h = round(shot.height * screen_w / shot.width)
    shot = shot.resize((screen_w, screen_h), Image.LANCZOS)
    lid_h = screen_h + 2 * bezel
    base_h = round(width * 0.03)
    overhang = round(width * 0.06)
    img = Image.new("RGBA", (width + 2 * overhang, lid_h + base_h), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([(overhang, 0), (overhang + width - 1, lid_h + bezel)], radius=round(bezel * 1.6), fill=(14, 15, 26, 255))
    img.paste(shot, (overhang + bezel, bezel))
    d.rounded_rectangle([(0, lid_h), (img.width - 1, img.height - 1)], radius=round(base_h * 0.5), fill=(196, 198, 206, 255))
    notch = round(width * 0.14)
    d.rounded_rectangle([(img.width // 2 - notch // 2, lid_h), (img.width // 2 + notch // 2, lid_h + round(base_h * 0.35))],
                        radius=round(base_h * 0.2), fill=(160, 162, 172, 255))
    return img
