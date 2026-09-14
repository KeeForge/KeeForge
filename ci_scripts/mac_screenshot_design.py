"""Mac App Store screenshot design: headline and subhead above a real window capture.

Layout is planned for every screen before any file is written, so a headline that cannot
fit fails the listing instead of clipping. The capture is only uniformly resized; its own
alpha (rounded corners, sheet transparency) is kept and also shapes the shadow.
"""

from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

CANVAS = (2880, 1800)

PALETTE = {
    "background_top": (255, 255, 255),
    "background_bottom": (234, 242, 252),
    "headline": (16, 24, 40),
    "subhead": (86, 96, 112),
    "shadow": (22, 44, 84),
}

SF_PRO = Path("/System/Library/Fonts/SFNS.ttf")
HELVETICA_NEUE = Path("/System/Library/Fonts/HelveticaNeue.ttc")

# SF Pro is variable: (width, optical size, grade, weight). Helvetica Neue is the
# fallback on a Mac without SFNS.ttf; the .ttc face indices are Medium and Regular.
TYPE = {
    "headline": {"size": 128, "min_size": 96, "sf_axes": (100, 96, 400, 620), "helvetica_index": 10},
    "subhead": {"size": 58, "min_size": 46, "sf_axes": (100, 28, 400, 400), "helvetica_index": 0},
}

LAYOUT = {
    "text_top": 104,
    "side_margin": 200,
    "line_gap": -4,
    "headline_to_subhead": 25,
    "text_to_window": 78,
    "bottom_margin": 84,
    "window_max_width": 2200,
    # Captures are 2x Retina; upscaling past 1:1 only softens them.
    "window_max_scale": 1.0,
    "shadow": ((90, 30, 46), (22, 10, 64)),  # (blur, y offset, alpha) per layer
}


class LayoutError(Exception):
    pass


def font_family():
    return "SF Pro" if SF_PRO.exists() else "Helvetica Neue"


def load_font(role, size):
    spec = TYPE[role]
    if SF_PRO.exists():
        font = ImageFont.truetype(str(SF_PRO), size)
        font.set_variation_by_axes(list(spec["sf_axes"]))
        return font
    if HELVETICA_NEUE.exists():
        return ImageFont.truetype(str(HELVETICA_NEUE), size, index=spec["helvetica_index"])
    raise LayoutError(f"neither {SF_PRO} nor {HELVETICA_NEUE} is installed")


def balanced_split(text, font):
    """Two lines with the narrowest widest line, preferring a break after a sentence."""
    words = text.split(" ")
    splits = [(" ".join(words[:i]), " ".join(words[i:])) for i in range(1, len(words))]
    if not splits:
        return None
    sentence_splits = [s for s in splits if s[0].endswith((".", ",", ":"))]
    width = lambda s: max(font.getlength(s[0]), font.getlength(s[1]))
    best = min(splits, key=width)
    if sentence_splits:
        best_sentence = min(sentence_splits, key=width)
        if width(best_sentence) <= width(best) * 1.15:
            best = best_sentence
    return list(best)


def fit_text(role, text, max_width):
    """Largest size that fits on one line; otherwise the largest balanced two-line wrap."""
    spec = TYPE[role]
    sizes = range(spec["size"], spec["min_size"] - 1, -2)
    one_line_floor = spec["size"] * 0.85
    for size in sizes:
        if size < one_line_floor:
            break
        font = load_font(role, size)
        if font.getlength(text) <= max_width:
            return font, [text]
    for size in sizes:
        font = load_font(role, size)
        lines = balanced_split(text, font)
        if lines and all(font.getlength(line) <= max_width for line in lines):
            return font, lines
    raise LayoutError(f"{role} {text!r} does not fit {max_width}px even at {spec['min_size']}px on two lines")


def text_block(role, text, top):
    font, lines = fit_text(role, text, CANVAS[0] - 2 * LAYOUT["side_margin"])
    ascent, descent = font.getmetrics()
    placed, y = [], top
    for line in lines:
        width = font.getlength(line)
        x = (CANVAS[0] - width) / 2
        left, line_top, right, bottom = font.getbbox(line, anchor="ls")
        baseline = y + ascent
        placed.append({"text": line, "x": x, "baseline": baseline,
                       "bounds": [round(x + left), round(baseline + line_top), round(x + right), round(baseline + bottom)]})
        y += ascent + descent + LAYOUT["line_gap"]
    bounds = [min(p["bounds"][0] for p in placed), min(p["bounds"][1] for p in placed),
              max(p["bounds"][2] for p in placed), max(p["bounds"][3] for p in placed)]
    # Flow follows font metrics, not ink, so every screen in the series shares baselines.
    return {"role": role, "font": font, "size": font.size, "lines": placed, "bounds": bounds,
            "bottom": round(y - LAYOUT["line_gap"])}


def plan(window_size, headline, subhead):
    """Computes every position for one screen and validates it; draws nothing."""
    head = text_block("headline", headline, LAYOUT["text_top"])
    sub = text_block("subhead", subhead, head["bottom"] + LAYOUT["headline_to_subhead"])
    window_top_limit = sub["bottom"] + LAYOUT["text_to_window"]
    available_h = CANVAS[1] - LAYOUT["bottom_margin"] - window_top_limit
    width, height = window_size
    scale = min(LAYOUT["window_max_width"] / width, available_h / height, LAYOUT["window_max_scale"])
    window_w, window_h = round(width * scale), round(height * scale)
    x = (CANVAS[0] - window_w) // 2
    y = window_top_limit + (available_h - window_h) // 2
    window = [x, y, x + window_w, y + window_h]

    problems = []
    for block in (head, sub):
        left, top, right, bottom = block["bounds"]
        if left < LAYOUT["side_margin"] or right > CANVAS[0] - LAYOUT["side_margin"] or top < 0:
            problems.append(f"{block['role']} {block['bounds']} leaves the text area")
    if head["bounds"][3] > sub["bounds"][1]:
        problems.append("headline overlaps subhead")
    if sub["bounds"][3] + LAYOUT["text_to_window"] // 2 > window[1]:
        problems.append("text overlaps window")
    if window[0] < 0 or window[2] > CANVAS[0] or window[3] > CANVAS[1] - LAYOUT["bottom_margin"]:
        problems.append(f"window {window} leaves the canvas margins")
    if scale < 0.5:
        problems.append(f"window scale {scale:.3f} would make the UI illegible")
    if problems:
        raise LayoutError("; ".join(problems))
    return {"headline": head, "subhead": sub, "window": window, "scale": scale}


def background():
    top, bottom = PALETTE["background_top"], PALETTE["background_bottom"]
    height = CANVAS[1]
    column = Image.new("RGB", (1, height))
    for y in range(height):
        t = y / (height - 1)
        column.putpixel((0, y), tuple(round(a + (b - a) * t) for a, b in zip(top, bottom)))
    return column.resize(CANVAS).convert("RGBA")


def shadow(canvas, alpha_mask, origin, blur, offset, opacity):
    pad = blur * 3
    mask = Image.new("L", (alpha_mask.width + 2 * pad, alpha_mask.height + 2 * pad), 0)
    mask.paste(alpha_mask.point(lambda v: v * opacity // 255), (pad, pad))
    tint = Image.new("RGBA", mask.size, PALETTE["shadow"] + (255,))
    tint.putalpha(mask.filter(ImageFilter.GaussianBlur(blur)))
    canvas.alpha_composite(tint, (origin[0] - pad, origin[1] - pad + offset))


def render(screen_path, output_path, headline, subhead):
    """Renders one 2880x1800 RGB PNG; returns the measured layout for the report."""
    window = Image.open(screen_path).convert("RGBA")
    layout = plan(window.size, headline, subhead)
    left, top, right, bottom = layout["window"]
    window = window.resize((right - left, bottom - top), Image.LANCZOS)

    canvas = background()
    draw = ImageDraw.Draw(canvas)
    for role in ("headline", "subhead"):
        block = layout[role]
        for line in block["lines"]:
            draw.text((line["x"], line["baseline"]), line["text"], font=block["font"], fill=PALETTE[role], anchor="ls")
    alpha = window.getchannel("A")
    for blur, offset, opacity in LAYOUT["shadow"]:
        shadow(canvas, alpha, (left, top), blur, offset, opacity)
    canvas.alpha_composite(window, (left, top))
    canvas.convert("RGB").save(output_path)

    return {
        "window": layout["window"],
        "window_scale": round(layout["scale"], 4),
        **{role: {"size": layout[role]["size"], "lines": [line["text"] for line in layout[role]["lines"]],
                  "bounds": layout[role]["bounds"]} for role in ("headline", "subhead")},
    }
