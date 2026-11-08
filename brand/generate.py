"""Generate the placeholder Spark brand art for every platform.

    uv run --with pillow python brand/generate.py <apple-repo> <android-repo> [<server-repo>]

Writes the files into each repo's fork/overlay/ tree, mirroring the paths of
the upstream Silo assets they replace. fork/apply-brand.sh copies the overlay
over the checkout at build time. Replace this placeholder by editing the
drawing functions (or dropping real art into the overlays) and re-running.
"""

import math
import os
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageFont

NAME = "Spark"
FONT = os.environ.get(
    "FUSE_FONT",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "Poppins-Bold.ttf"),
)
TOP = (36, 16, 70)  # deep violet
BOTTOM = (255, 94, 31)  # ember orange
GLOW = (255, 196, 92)
SS = 4  # supersampling factor for antialiased shapes


def gradient(w, h, top=TOP, bottom=BOTTOM, diagonal=True):
    img = Image.new("RGB", (w, h))
    px = img.load()
    for y in range(h):
        for x in range(w):
            t = ((x / max(w - 1, 1)) * 0.35 + (y / max(h - 1, 1)) * 0.65) if diagonal else y / max(h - 1, 1)
            t = t * t * (3 - 2 * t)
            px[x, y] = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
    return img


def fast_gradient(w, h):
    # Gradients for the very large tvOS images are drawn small and scaled up.
    small = gradient(max(w // 8, 2), max(h // 8, 2))
    return small.resize((w, h), Image.BICUBIC)


def spark_points(cx, cy, r, inner=0.18, points=4, rot=-math.pi / 2):
    pts = []
    for i in range(points * 2):
        a = rot + i * math.pi / points
        rr = r if i % 2 == 0 else r * inner
        pts.append((cx + rr * math.cos(a), cy + rr * math.sin(a)))
    return pts


def draw_spark(size, scale=0.62, color=(255, 255, 255), glow=True):
    """A transparent square with the four-point spark centred in it."""
    s = size * SS
    layer = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    r = s * scale / 2
    if glow:
        g = Image.new("RGBA", (s, s), (0, 0, 0, 0))
        ImageDraw.Draw(g).ellipse(
            [s / 2 - r * 0.55, s / 2 - r * 0.55, s / 2 + r * 0.55, s / 2 + r * 0.55],
            fill=GLOW + (190,),
        )
        layer = Image.alpha_composite(layer, g.filter(ImageFilter.GaussianBlur(s * 0.06)))
    d = ImageDraw.Draw(layer)
    d.polygon(spark_points(s / 2, s / 2, r), fill=color + (255,))
    small = r * 0.32
    d.polygon(spark_points(s / 2 + r * 0.62, s / 2 - r * 0.62, small, inner=0.22), fill=color + (235,))
    return layer.resize((size, size), Image.LANCZOS)


def app_icon(size, rgb=True):
    bg = gradient(size, size).convert("RGBA")
    img = Image.alpha_composite(bg, draw_spark(size))
    return img.convert("RGB") if rgb else img


def adaptive_foreground(size):
    # Android adaptive icons keep the art inside the central 66/108 safe zone.
    return draw_spark(size, scale=0.62 * 66 / 108)


def font(px):
    return ImageFont.truetype(FONT, px)


def wordmark(w, h, color=(255, 255, 255), fill=0.62):
    img = Image.new("RGBA", (w * SS, h * SS), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    size = int(h * SS * fill)
    f = font(size)
    box = d.textbbox((0, 0), NAME, font=f)
    # Shrink a long name so it fits the width with a small margin.
    if box[2] - box[0] > w * SS * 0.92:
        f = font(int(size * w * SS * 0.92 / (box[2] - box[0])))
        box = d.textbbox((0, 0), NAME, font=f)
    tw, th = box[2] - box[0], box[3] - box[1]
    d.text(((w * SS - tw) / 2 - box[0], (h * SS - th) / 2 - box[1]), NAME, font=f, fill=color + (255,))
    return img.resize((w, h), Image.LANCZOS)


def tall_mark(w, h):
    """The in-app mark: a spark above a spark cord, in the tall box the upstream mark used."""
    img = Image.new("RGBA", (w * SS, h * SS), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    W, H = w * SS, h * SS
    cord_w = W * 0.22
    d.rounded_rectangle([W / 2 - cord_w / 2, H * 0.36, W / 2 + cord_w / 2, H], radius=cord_w / 2, fill=BOTTOM + (255,))
    d.polygon(spark_points(W / 2, H * 0.17, W * 0.5, inner=0.2), fill=(255, 176, 60, 255))
    return img.resize((w, h), Image.LANCZOS)


def banner(w, h, mark_frac=0.62):
    bg = fast_gradient(w, h).convert("RGBA")
    m = draw_spark(int(h * mark_frac))
    bg.alpha_composite(m, (int(w * 0.08), (h - m.height) // 2))
    wm = wordmark(int(w * 0.5), int(h * 0.6))
    bg.alpha_composite(wm, (int(w * 0.08) + m.width, (h - wm.height) // 2))
    return bg.convert("RGB")


def save(img, root, rel):
    path = os.path.join(root, "fork", "overlay", rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.save(path, optimize=True)


def apple(root):
    cat = "iosApp/iosApp/Assets.xcassets"
    save(app_icon(1024), root, f"{cat}/AppIcon.appiconset/AppIcon.png")
    for pt in (16, 32, 128, 256, 512):
        for sc in (1, 2):
            save(app_icon(pt * sc, rgb=False), root, f"{cat}/AppIcon.appiconset/AppIcon-mac-{pt}x{pt}@{sc}x.png")
    tv = f"{cat}/TVAppIcon.brandassets"
    for stack, sizes in (("App Icon - App Store", [(1280, 768, "")]), ("App Icon", [(400, 240, ""), (800, 480, "@2x")])):
        for w, h, sfx in sizes:
            save(fast_gradient(w, h), root, f"{tv}/{stack}.imagestack/Layer0.imagestacklayer/Content.imageset/Content{sfx}.png")
            layer = Image.new("RGBA", (w, h), (0, 0, 0, 0))
            m = draw_spark(int(h * 0.8))
            layer.alpha_composite(m, ((w - m.width) // 2, (h - m.height) // 2))
            save(layer, root, f"{tv}/{stack}.imagestack/Layer1.imagestacklayer/Content.imageset/Content{sfx}.png")
    for name, w, h in (("Top Shelf Image Wide", 2320, 720), ("Top Shelf Image", 1920, 720)):
        save(banner(w, h, 0.5), root, f"{tv}/{name}.imageset/Content.png")
        save(banner(w * 2, h * 2, 0.5), root, f"{tv}/{name}.imageset/Content@2x.png")
    # In-app mark and wordmark: PNG replacements for the upstream SVGs. The
    # apply script swaps the imageset contents and Contents.json.
    save(tall_mark(266, 855), root, f"{cat}/SiloMark.imageset/spark-mark.png")
    save(tall_mark(532, 1710), root, f"{cat}/SiloMark.imageset/spark-mark@2x.png")
    save(wordmark(764, 400), root, f"{cat}/SiloWordmark.imageset/spark-wordmark.png")
    save(wordmark(1528, 800), root, f"{cat}/SiloWordmark.imageset/spark-wordmark@2x.png")


def android(root):
    dens = {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}
    for app, legacy in (("androidApp", 48), ("androidTvApp", 80)):
        res = f"{app}/src/androidMain/res"
        for d, f in dens.items():
            save(app_icon(int(legacy * f)), root, f"{res}/mipmap-{d}/ic_launcher.png")
            save(adaptive_foreground(int(108 * f)), root, f"{res}/mipmap-{d}/ic_launcher_foreground.png")
    save(banner(320, 180), root, "androidTvApp/src/androidMain/res/drawable/tv_banner.png")
    save(wordmark(764, 400), root, "androidApp/src/androidMain/res/drawable/silo_wordmark.png")
    # The TV app's vector mark and wordmark become bitmaps; the apply script
    # deletes the upstream vector files of the same name.
    save(tall_mark(64, 204), root, "androidTvApp/src/androidMain/res/drawable-nodpi/silo_mark.png")
    save(wordmark(764, 400), root, "androidTvApp/src/androidMain/res/drawable-nodpi/silo_wordmark.png")


def lockup(w, h, mark_frac=0.8, text_frac=0.62, gap_frac=0.06):
    """The sidebar/header lockup at w x h: a gold four-point spark with a small
    ember spark beside it, then the white name, centred on one line and left
    aligned, the way Silo's lockup puts its mark before the wordmark. The name
    shrinks to fit the width."""
    W, H = w * SS, h * SS
    mark = int(H * mark_frac)
    gap = H * gap_frac
    probe = ImageDraw.Draw(Image.new("RGBA", (1, 1)))
    size = int(H * text_frac * 1.32)
    f = font(size)
    box = probe.textbbox((0, 0), NAME, font=f)
    room = W * 0.97 - mark - gap
    if box[2] - box[0] > room:
        f = font(int(size * room / (box[2] - box[0])))
        box = probe.textbbox((0, 0), NAME, font=f)
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    gcx, gcy = mark * 0.5, H / 2
    glow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse(
        [gcx - mark * 0.3, gcy - mark * 0.3, gcx + mark * 0.3, gcy + mark * 0.3],
        fill=GLOW + (140,),
    )
    img = Image.alpha_composite(img, glow.filter(ImageFilter.GaussianBlur(mark * 0.12)))
    d = ImageDraw.Draw(img)
    d.polygon(spark_points(gcx, gcy, mark * 0.46, inner=0.2), fill=(255, 176, 59, 255))
    d.polygon(spark_points(gcx + mark * 0.42, gcy - mark * 0.36, mark * 0.13, inner=0.24), fill=BOTTOM + (255,))
    tx = mark + gap - box[0]
    ty = (H - (box[3] - box[1])) / 2 - box[1]
    d.text((tx, ty), NAME, font=f, fill=(255, 255, 255, 255))
    return img.resize((w, h), Image.LANCZOS)


def maskable_icon(size):
    # PWA maskable icons keep the art inside the central 80% safe zone.
    bg = gradient(size, size).convert("RGBA")
    return Image.alpha_composite(bg, draw_spark(size, scale=0.62 * 0.8)).convert("RGB")


def server(root):
    """The web app's icons, favicon, mark and sidebar wordmark."""
    pub = "web/public"
    save(app_icon(1024), root, f"{pub}/silo-icon-1024.png")
    # Drawn in 2.95:1 boxes; the server's apply-brand.sh widens the web
    # app's 2.35:1 logo boxes to fit the longer name.
    save(lockup(708, 240), root, f"{pub}/silo-wordmark-sidebar.png")
    save(app_icon(180), root, f"{pub}/apple-touch-icon.png")
    save(app_icon(192), root, f"{pub}/web-app-icon-192.png")
    save(app_icon(512), root, f"{pub}/web-app-icon-512.png")
    save(maskable_icon(512), root, f"{pub}/maskable-icon-512.png")
    path = os.path.join(root, "fork", "overlay", pub, "favicon.ico")
    app_icon(256).save(path, sizes=[(16, 16), (32, 32), (48, 48), (64, 64), (256, 256)])


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1]:
        apple(sys.argv[1])
    if len(sys.argv) > 2 and sys.argv[2]:
        android(sys.argv[2])
    if len(sys.argv) > 3 and sys.argv[3]:
        server(sys.argv[3])
    print("wrote overlays")
