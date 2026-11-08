#!/usr/bin/env python3
"""Cut the iPhone App Store app preview from a recorded store-capture run.

    ci_scripts/make_app_preview.py --video RUN.mov --captures EXPORT_DIR --locale en --output OUT.mp4

Record `KeeForgeUITests/AppStoreScreenshots` with
`studio-test run ios --device "iPhone 18 Pro Max" --status-bar clean --record-video
--test-env APPSTORE_SCREENSHOTS=1 --bundles always KeeForgeUITests/AppStoreScreenshots`,
then export that run's attachments with `xcrun xcresulttool export attachments`.

Each scene ends on one of the run's screenshots. The attachment timestamp, against
the movie's creation time, places it to within a second or so; the scene is then
pinned to the video frame that best matches the screenshot itself, so the cuts do
not depend on how fast the walkthrough ran. The recording plays as a rounded screen
on the screenshots' indigo field, under a display-face headline per scene
(appstore_preview.json).

Output follows App Store Connect's iPhone preview spec: 886x1920, 30 fps H.264
around 11 Mbps, a silent stereo AAC track, 15-30 seconds.
"""

import argparse
import datetime
import json
import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageStat

import store_art as art
from make_appstore_screenshots import LOCALES, attachment_stem

COPY_PATH = Path(__file__).resolve().with_name("appstore_preview.json")
SIZE = (886, 1920)
FPS = 30
# (capture the scene ends on, seconds before it, seconds after it)
SCENES = [
    ("01-database-list", 2.4, 0.6),
    ("02-unlock-screen", 3.0, 0.4),
    ("03-vault-groups", 2.4, 0.8),
    ("06-entry-detail", 3.2, 1.6),
    ("06b-entry-passkey", 1.2, 1.4),
    ("08-search", 4.0, 0.3),
]
MATCH = (66, 144)
# The recording sits as a rounded screen on the indigo field, with the headline above it.
SCREEN = (700, 1520)
SCREEN_ORIGIN = ((SIZE[0] - SCREEN[0]) // 2, SIZE[1] - SCREEN[1] - 60)
SCREEN_RADIUS = 64


def run(args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)


def video_start(video):
    """The movie's creation time as a Unix timestamp (simctl writes it at recording start)."""
    out = run(["ffprobe", "-v", "error", "-show_entries", "format_tags=creation_time", "-of", "json", video],
              capture_output=True, text=True).stdout
    stamp = json.loads(out)["format"]["tags"]["creation_time"]
    return datetime.datetime.fromisoformat(stamp.replace("Z", "+00:00")).timestamp()


def capture_times(captures):
    """{capture stem: (timestamp, path)} from an xcresulttool attachment export."""
    manifest = json.loads((captures / "manifest.json").read_text(encoding="utf-8"))
    found = {}
    for record in manifest:
        for attachment in record.get("attachments", []):
            stem = attachment_stem(attachment["suggestedHumanReadableName"])
            found[stem] = (attachment["timestamp"], captures / attachment["exportedFileName"])
    return found


def gray(image):
    return image.convert("L").resize(MATCH, Image.BILINEAR)


def thumbnails(cfr):
    """Every tenth of a second of the video, as small grey frames for matching."""
    raw = run(["ffmpeg", "-v", "error", "-i", cfr,
               "-vf", f"fps=10,scale={MATCH[0]}:{MATCH[1]},format=gray", "-f", "rawvideo", "-"],
              capture_output=True).stdout
    size = MATCH[0] * MATCH[1]
    return [Image.frombytes("L", MATCH, raw[i * size:(i + 1) * size]) for i in range(len(raw) // size)]


def pin(frames, after, estimate, screenshot):
    """When `screenshot` was taken: the end of the matching stretch between `after` and `estimate`.

    The movie's creation time runs several seconds ahead of the attachment clock, so
    `estimate` is only an upper bound. Each screenshot is taken just before the walkthrough
    moves on, so the end of the unbroken run of frames matching it is the moment it shows."""
    target = gray(Image.open(screenshot))
    first = int(after * 10) + 1
    scores = [ImageStat.Stat(ImageChops.difference(frame, target)).mean[0]
              for frame in frames[first:min(len(frames), int(estimate * 10) + 20)]]
    if not scores or min(scores) > 12:
        raise art.ArtError(f"{screenshot.name}: no frame between {after:.1f} s and {estimate:.1f} s matches it")
    end = scores.index(min(scores))
    while end + 1 < len(scores) and scores[end + 1] <= min(scores) + 1.5:
        end += 1
    return (first + end) / 10


def caption_overlay(text, locale):
    """The indigo field with the headline above a rounded hole the recording shows through."""
    overlay = art.background(SIZE, (0.5, 0.1)).convert("RGBA")
    x, y = SCREEN_ORIGIN
    hole = Image.new("L", SIZE, 255)
    ImageDraw.Draw(hole).rounded_rectangle([(x, y), (x + SCREEN[0] - 1, y + SCREEN[1] - 1)],
                                           radius=SCREEN_RADIUS, fill=0)
    overlay.putalpha(hole)
    d = ImageDraw.Draw(overlay)
    f = art.fit("display", locale, text, 72, SIZE[0] - 2 * x, 48)
    lines = text.split("\n")
    leading = round(f.size * 1.08)
    top = (y - leading * len(lines)) // 2 + round(f.size * 0.1)
    for i, line in enumerate(lines):
        d.text((SIZE[0] / 2, top + i * leading), line, font=f, fill=art.PAPER, anchor="ma",
               stroke_width=art.stroke("display", locale), stroke_fill=art.PAPER)
    return overlay


def make_preview(video, captures, locale, output):
    art.ensure_fonts()
    table = json.loads(COPY_PATH.read_text(encoding="utf-8"))
    copy = table.get(locale)
    if copy is None or set(copy) != {stem for stem, *_ in SCENES}:
        raise art.ArtError(f"{COPY_PATH.name}: {locale} needs exactly one caption per scene")
    times = capture_times(captures)
    missing = [stem for stem, *_ in SCENES if stem not in times]
    if missing:
        raise art.ArtError(f"{captures} has no capture for {missing}")

    with tempfile.TemporaryDirectory() as temp:
        temp = Path(temp)
        # Simulator recordings are variable-rate and hold no frames while the screen is
        # still, so trimming needs a constant-rate copy first.
        cfr = temp / "cfr.mp4"
        run(["ffmpeg", "-v", "error", "-i", video, "-vf", f"fps={FPS}", "-c:v", "libx264", "-crf", "10",
             "-preset", "veryfast", "-an", cfr])
        origin = video_start(video)
        frames = thumbnails(cfr)
        parts = []
        at = 0.0
        for index, (stem, before, after) in enumerate(SCENES):
            stamp, screenshot = times[stem]
            at = pin(frames, at, stamp - origin, screenshot)
            overlay = temp / f"caption-{index}.png"
            caption_overlay(copy[stem], locale).save(overlay)
            part = temp / f"part-{index}.mp4"
            run(["ffmpeg", "-v", "error", "-ss", f"{max(0.0, at - before):.3f}", "-t", f"{before + after:.3f}", "-i", cfr,
                 "-i", overlay, "-filter_complex",
                 f"[0:v]scale={SCREEN[0]}:{SCREEN[1]},setsar=1,"
                 f"pad={SIZE[0]}:{SIZE[1]}:{SCREEN_ORIGIN[0]}:{SCREEN_ORIGIN[1]}[v];[v][1:v]overlay=0:0,fps={FPS}",
                 "-c:v", "libx264", "-crf", "12", "-preset", "veryfast", "-an", part])
            parts.append(part)
            print(f"{stem}: scene ends at {at:.1f} s")
        listing = temp / "parts.txt"
        listing.write_text("".join(f"file '{p}'\n" for p in parts))
        output.parent.mkdir(parents=True, exist_ok=True)
        run(["ffmpeg", "-v", "error", "-y", "-f", "concat", "-safe", "0", "-i", listing,
             "-f", "lavfi", "-i", "anullsrc=channel_layout=stereo:sample_rate=44100",
             "-c:v", "libx264", "-profile:v", "high", "-pix_fmt", "yuv420p", "-r", str(FPS),
             "-b:v", "11M", "-maxrate", "12M", "-bufsize", "24M",
             "-c:a", "aac", "-b:a", "256k", "-shortest", "-movflags", "+faststart", output])
    duration = float(run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", output],
                         capture_output=True, text=True).stdout)
    if not 15 <= duration <= 30:
        raise art.ArtError(f"{output.name} runs {duration:.1f} s; App Store previews must run 15-30 s")
    print(f"Created {output} ({duration:.1f} s)")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--video", type=Path, required=True, help="simctl recording of the AppStoreScreenshots run")
    parser.add_argument("--captures", type=Path, required=True, help="that run's xcresulttool attachment export")
    parser.add_argument("--locale", choices=list(LOCALES), default="en")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        make_preview(args.video, args.captures, args.locale, args.output)
    except art.ArtError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
