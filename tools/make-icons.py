"""Draws the mod's GUI icons: shortcut silhouette, title bar buttons, and formula tiles.
Usage: python3 tools/make-icons.py"""
import math
import os

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

TOOLS = os.path.dirname(__file__)
MOD = os.path.join(TOOLS, "..", "mods", "logistic-formulas")
OUT = os.path.join(MOD, "graphics", "icons")
FONT = "/System/Library/Fonts/Supplemental/Arial Bold.ttf"
FONT_ITALIC = "/System/Library/Fonts/Supplemental/Arial Bold Italic.ttf"
SYMBOLS = "/System/Library/Fonts/Supplemental/Arial Unicode.ttf"
SCALE = 8  # supersampling factor
WHITE = (255, 255, 255, 255)
BLACK = (0, 0, 0, 255)


def canvas(size):
    s = size * SCALE
    return Image.new("RGBA", (s, s), (0, 0, 0, 0))


def finish(img, size, name):
    img.resize((size, size), Image.LANCZOS).save(os.path.join(OUT, name + ".png"))


def pin(color):
    img = canvas(32)
    d = ImageDraw.Draw(img)

    def p(x, y):
        return (x * SCALE, y * SCALE)

    # Head, body and plate of a pushpin, tilted 45 degrees, point at the lower left.
    d.polygon([p(17, 3), p(29, 15), p(26, 18), p(14, 6)], fill=color)
    d.polygon([p(18, 8), p(24, 14), p(19, 19), p(13, 13)], fill=color)
    d.polygon([p(9, 13), p(19, 23), p(17, 25), p(7, 15)], fill=color)
    d.line([p(12, 20), p(4, 28)], fill=color, width=3 * SCALE)
    return img


def resize(color, grow):
    """Two diagonal arrows, pointing out of (grow) or into the corners."""
    img = canvas(32)
    d = ImageDraw.Draw(img)

    def p(x, y):
        return (x * SCALE, y * SCALE)

    for sign in (1, -1):
        # Corner at (cx, cy); the arrow runs along the diagonal towards or away from it.
        cx, cy = (26, 6) if sign == 1 else (6, 26)
        inner = (19, 13) if sign == 1 else (13, 19)
        tip, base = ((cx, cy), inner) if grow else (inner, (cx, cy))
        d.line([p(*base), p(*tip)], fill=color, width=3 * SCALE)
        tx, ty = tip
        dx = 1 if tx > base[0] else -1
        dy = 1 if ty > base[1] else -1
        d.polygon([p(tx + dx, ty + dy), p(tx - 7 * dx, ty + dy), p(tx + dx, ty - 7 * dy)], fill=color)
    return img


def maximize(color):
    """A window outline with a thick title bar: fill the screen."""
    img = canvas(32)
    d = ImageDraw.Draw(img)
    d.rectangle([4 * SCALE, 5 * SCALE, 28 * SCALE, 27 * SCALE], outline=color, width=3 * SCALE)
    d.rectangle([4 * SCALE, 5 * SCALE, 28 * SCALE, 11 * SCALE], fill=color)
    return img


SIZE = 64


def center_fg(fg, size=SIZE, dx=0, dy=0):
    """Shifts `fg` so the bounding box of its visible pixels is centered."""
    bbox = fg.getbbox()
    if not bbox:
        return fg
    s = size * SCALE
    cx = (bbox[0] + bbox[2]) / 2.0
    cy = (bbox[1] + bbox[3]) / 2.0
    ox = int(round(s / 2.0 - cx + dx * SCALE))
    oy = int(round(s / 2.0 - cy + dy * SCALE))
    out = canvas(size)
    out.paste(fg, (ox, oy))
    return out


def history_arrow(color, redo):
    """A curved arrow turning back to the left (undo), or mirrored to the right (redo)."""
    img = canvas(32)
    d = ImageDraw.Draw(img)
    r, cx, cy, w = 9, 16, 18, 3
    d.arc([(cx - r) * SCALE, (cy - r) * SCALE, (cx + r) * SCALE, (cy + r) * SCALE], 180, 405,
          fill=color, width=w * SCALE)
    # Arrowhead at the arc's left end, pointing down.
    x = cx - r + w / 2
    d.polygon([(x * SCALE, (cy + 7) * SCALE), ((x - 6) * SCALE, (cy - 1) * SCALE), ((x + 6) * SCALE, (cy - 1) * SCALE)],
              fill=color)
    return img.transpose(Image.FLIP_LEFT_RIGHT) if redo else img


def wrap(color):
    """f(·): wrap a node in a function."""
    fg = canvas(32)
    d = ImageDraw.Draw(fg)
    f = ImageFont.truetype(FONT, 22 * SCALE)
    d.text((16 * SCALE, 16 * SCALE), "f(·)", font=f, fill=color, anchor="mm", stroke_width=SCALE // 3, stroke_fill=color)
    return center_fg(fg, 32)


# Family colors, so related functions read alike at a glance.
SOURCE = (52, 101, 164)
ARITHMETIC = (64, 138, 64)
COMPARE = (196, 110, 30)
QUALITY = (128, 70, 160)
STACKS = (170, 140, 20)
FILTER = (30, 140, 140)
LOGISTICS = (170, 60, 70)
GUIDE = (78, 90, 114)


def clamp(v):
    return max(0, min(255, int(round(v))))


def shade(color, factor):
    if factor >= 0:
        return tuple(clamp(c + (255 - c) * factor) for c in color)
    return tuple(clamp(c * (1 + factor)) for c in color)


def tile(color):
    """Rounded square with a vertical gradient and a bevel, like the game's icon tiles."""
    s = SIZE * SCALE
    m = 2 * SCALE
    rad = 10 * SCALE
    mask = Image.new("L", (s, s), 0)
    ImageDraw.Draw(mask).rounded_rectangle([m, m, s - m, s - m], radius=rad, fill=255)

    top_c = shade(color, 0.16)
    bot_c = shade(color, -0.18)
    grad = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    gd = ImageDraw.Draw(grad)
    span = max(1, (s - 2 * m))
    for y in range(m, s - m):
        t = (y - m) / span
        r = clamp(top_c[0] + (bot_c[0] - top_c[0]) * t)
        g = clamp(top_c[1] + (bot_c[1] - top_c[1]) * t)
        b = clamp(top_c[2] + (bot_c[2] - top_c[2]) * t)
        gd.line([(m, y), (s - m, y)], fill=(r, g, b, 255))

    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    img.paste(grad, (0, 0), mask)
    d = ImageDraw.Draw(img)
    # Light inner edge, dark outer rim.
    d.rounded_rectangle([m + SCALE, m + SCALE, s - m - SCALE, s - m - SCALE], radius=rad - SCALE,
                        outline=(255, 255, 255, 45), width=int(round(1.5 * SCALE)))
    d.rounded_rectangle([m, m, s - m, s - m], radius=rad,
                        outline=(0, 0, 0, 95), width=2 * SCALE)
    return img


def finish_tile(color, draw_fn, dx=0, dy=0):
    """A tile with the glyph drawn by draw_fn, centered and with a drop shadow."""
    fg = canvas(SIZE)
    draw_fn(fg, ImageDraw.Draw(fg))
    fg = center_fg(fg, SIZE, dx=dx, dy=dy)

    # The shadow keeps the white glyph readable on light tiles.
    shadow = Image.new("RGBA", fg.size, (0, 0, 0, 0))
    alpha = fg.split()[3]
    dark = Image.new("RGBA", fg.size, (0, 0, 0, 90))
    shifted_alpha = ImageChops.offset(alpha, 0, int(round(1.6 * SCALE)))
    shadow.paste(dark, (0, 0), shifted_alpha)
    shadow = shadow.filter(ImageFilter.GaussianBlur(radius=0.8 * SCALE))

    base = tile(color)
    base.alpha_composite(shadow)
    base.alpha_composite(fg)
    return base


def p(x, y):
    return (x * SCALE, y * SCALE)


def rbox(d, x0, y0, x1, y1, r=1.5, fill=WHITE, outline=None, width=0):
    d.rounded_rectangle([p(x0, y0), p(x1, y1)], radius=r * SCALE, fill=fill, outline=outline, width=int(round(width * SCALE)))


def stroke_line(d, pts, w, fill=WHITE):
    """Polyline with round caps and joints."""
    px_pts = [p(x, y) for x, y in pts]
    lw = int(round(w * SCALE))
    d.line(px_pts, fill=fill, width=lw, joint="curve")
    r = w * SCALE / 2.0
    for px, py in px_pts:
        d.ellipse([px - r, py - r, px + r, py + r], fill=fill)


def arrow_h(d, x0, x1, cy, shaft_w=4.4, head_len=9.5, head_half_h=8.5, fill=WHITE):
    """Horizontal arrow pointing from x0 to x1 (tip at x1)."""
    sgn = 1 if x1 > x0 else -1
    neck = x1 - sgn * head_len
    d.rounded_rectangle([p(min(x0, neck + sgn * 1.5), cy - shaft_w / 2),
                         p(max(x0, neck + sgn * 1.5), cy + shaft_w / 2)],
                        radius=1.2 * SCALE, fill=fill)
    d.polygon([p(x1, cy), p(neck, cy - head_half_h), p(neck, cy + head_half_h)], fill=fill)


def arrow_v(d, cx, y0, y1, shaft_w=4.4, head_len=8.5, head_half_w=8.0, fill=WHITE):
    """Vertical arrow pointing from y0 to y1 (tip at y1)."""
    sgn = 1 if y1 > y0 else -1
    neck = y1 - sgn * head_len
    d.rounded_rectangle([p(cx - shaft_w / 2, min(y0, neck + sgn * 1.5)),
                         p(cx + shaft_w / 2, max(y0, neck + sgn * 1.5))],
                        radius=1.2 * SCALE, fill=fill)
    d.polygon([p(cx, y1), p(cx - head_half_w, neck), p(cx + head_half_w, neck)], fill=fill)


def diamond(d, cx, cy, r, fill=WHITE):
    d.polygon([p(cx, cy - r), p(cx + r, cy), p(cx, cy + r), p(cx - r, cy)], fill=fill)


def funnel_shape(d, fill=WHITE):
    d.polygon([p(13, 15), p(51, 15), p(36.5, 32), p(36.5, 49), p(27.5, 44), p(27.5, 32)], fill=fill)


def draw_text(d, text, size, font=FONT, fill=WHITE, stroke=0):
    f = ImageFont.truetype(font, int(round(size * SCALE)))
    c = SIZE * SCALE / 2.0
    d.text((c, c), text, font=f, fill=fill, anchor="mm",
           stroke_width=int(round(stroke * SCALE)), stroke_fill=fill if stroke else None)


def icons():
    out = {}

    # SOURCE
    def draw_group(_, d):
        for i in range(3):
            y = 17 + i * 11.5
            rbox(d, 14, y, 22, y + 7.5, r=1.8)
            rbox(d, 26, y + 1.2, 50, y + 6.3, r=1.8)

    out["group"] = finish_tile(SOURCE, draw_group)

    def draw_constant(_, d):
        draw_text(d, "{ }", 33, FONT, stroke=0.4)

    out["constant"] = finish_tile(SOURCE, draw_constant)

    for name, into in [("ingredients", True), ("products", False)]:
        def draw_recipe(_, d, into=into):
            if into:
                arrow_h(d, 11, 27, 32, shaft_w=4.4, head_len=8.5, head_half_h=7.5)
                rbox(d, 30, 20, 53, 44, r=3.0)
            else:
                rbox(d, 11, 20, 34, 44, r=3.0)
                arrow_h(d, 37, 53, 32, shaft_w=4.4, head_len=8.5, head_half_h=7.5)

        out[name] = finish_tile(SOURCE, draw_recipe)

    def draw_network(_, d):
        for x, y in [(18, 18), (46, 18), (18, 46), (46, 46)]:
            stroke_line(d, [(32, 32), (x, y)], 4.2)
            d.ellipse([p(x - 5.5, y - 5.5), p(x + 5.5, y + 5.5)], fill=WHITE)
        rbox(d, 25.5, 25.5, 38.5, 38.5, r=2.5)

    out["network"] = finish_tile(SOURCE, draw_network)

    # ARITHMETIC
    def draw_sum(_, d):
        stroke_line(d, [(17, 32), (47, 32)], 5.4)
        stroke_line(d, [(32, 17), (32, 47)], 5.4)

    def draw_sub(_, d):
        stroke_line(d, [(17, 32), (47, 32)], 5.4)

    def draw_mul(_, d):
        stroke_line(d, [(20, 20), (44, 44)], 5.4)
        stroke_line(d, [(44, 20), (20, 44)], 5.4)

    def draw_div(_, d):
        stroke_line(d, [(17, 32), (47, 32)], 5.4)
        for cy in (20.5, 43.5):
            d.ellipse([p(32 - 3.8, cy - 3.8), p(32 + 3.8, cy + 3.8)], fill=WHITE)

    out["sum"] = finish_tile(ARITHMETIC, draw_sum)
    out["subtract"] = finish_tile(ARITHMETIC, draw_sub)
    out["multiply"] = finish_tile(ARITHMETIC, draw_mul)
    out["divide"] = finish_tile(ARITHMETIC, draw_div)

    # COMPARE
    out["highest"] = finish_tile(COMPARE, lambda _, d: draw_text(d, "MAX", 19.5, FONT, stroke=0.3))
    out["lowest"] = finish_tile(COMPARE, lambda _, d: draw_text(d, "MIN", 19.5, FONT, stroke=0.3))

    def draw_keep_pos(_, d):
        stroke_line(d, [(15, 22), (28, 32), (15, 42)], 4.6)
        d.ellipse([p(33, 20.5), p(49, 43.5)], outline=WHITE, width=int(round(4.6 * SCALE)))

    out["keep-positive"] = finish_tile(COMPARE, draw_keep_pos)

    # A bar with an arrow pushing counts up to it from below (at-least) or down to it from above (at-most).
    def draw_at_least(_, d):
        rbox(d, 14, 17, 50, 22.5, r=1.4)
        arrow_v(d, 32, 48, 26, shaft_w=4.4, head_len=8.5, head_half_w=8.0)

    def draw_at_most(_, d):
        rbox(d, 14, 41.5, 50, 47, r=1.4)
        arrow_v(d, 32, 16, 38, shaft_w=4.4, head_len=8.5, head_half_w=8.0)

    out["at-least"] = finish_tile(COMPARE, draw_at_least)
    out["at-most"] = finish_tile(COMPARE, draw_at_most)

    # QUALITY: a diamond, then an arrow or an equals sign.
    def draw_q_up(_, d):
        diamond(d, 23, 32, 11.5)
        arrow_v(d, 43.5, 44, 20, shaft_w=4.4, head_len=8.5, head_half_w=8.0)

    def draw_q_down(_, d):
        diamond(d, 23, 32, 11.5)
        arrow_v(d, 43.5, 20, 44, shaft_w=4.4, head_len=8.5, head_half_w=8.0)

    def draw_q_set(_, d):
        diamond(d, 23, 32, 11.5)
        rbox(d, 38, 25, 51, 29.5, r=1.4)
        rbox(d, 38, 34.5, 51, 39, r=1.4)

    out["quality-up"] = finish_tile(QUALITY, draw_q_up)
    out["quality-down"] = finish_tile(QUALITY, draw_q_down)
    out["set-quality"] = finish_tile(QUALITY, draw_q_set)

    # STACKS
    def draw_round_stacks(_, d):
        for i in range(3):
            y = 17.5 + i * 11
            if i == 0:
                rbox(d, 12, y, 34, y + 7.5, r=1.6, fill=None, outline=WHITE, width=2.8)
            else:
                rbox(d, 12, y, 34, y + 7.5, r=1.6)
        arrow_v(d, 45, 46.5, 17.5, shaft_w=4.2, head_len=8.5, head_half_w=7.5)

    def draw_set_stacks(_, d):
        for i in range(3):
            y = 17.5 + i * 11
            rbox(d, 15, y, 49, y + 7.5, r=1.8)

    out["round-to-stacks"] = finish_tile(STACKS, draw_round_stacks)
    out["set-stacks"] = finish_tile(STACKS, draw_set_stacks)

    # FILTER
    out["keep"] = finish_tile(FILTER, lambda _, d: funnel_shape(d))

    def draw_drop(fg, d):
        funnel_shape(d)
        # A slash through the funnel, with a transparent gap around it.
        cut = canvas(SIZE)
        stroke_line(ImageDraw.Draw(cut), [(14, 50), (50, 14)], 9.0, fill=WHITE)
        fg_alpha = ImageChops.subtract(fg.split()[3], cut.split()[3])
        fg.putalpha(fg_alpha)
        stroke_line(d, [(14, 50), (50, 14)], 4.4, fill=WHITE)

    out["drop"] = finish_tile(FILTER, draw_drop)

    # LOGISTICS
    def draw_le(_, d):
        stroke_line(d, [(44, 17), (20, 27), (44, 37)], 4.8)
        stroke_line(d, [(20, 46), (44, 46)], 4.8)

    def draw_ge(_, d):
        stroke_line(d, [(20, 17), (44, 27), (20, 37)], 4.8)
        stroke_line(d, [(20, 46), (44, 46)], 4.8)

    def draw_inf(_, d):
        # Lemniscate of Bernoulli, stretched vertically.
        pts = []
        a = 18.5
        for i in range(121):
            t = 2 * math.pi * i / 120.0
            denom = 1 + math.sin(t) ** 2
            x = 32 + (a * math.cos(t)) / denom
            y = 32 + (a * math.sin(t) * math.cos(t)) / denom * 1.45
            pts.append((x, y))
        stroke_line(d, pts, 4.4)

    def draw_get_max(_, d):
        stroke_line(d, [(40, 15), (24, 21.5), (40, 28)], 4.0)
        stroke_line(d, [(24, 34), (40, 34)], 4.0)
        rbox(d, 17, 40, 47, 44.2, r=1.4)
        rbox(d, 17, 47.5, 47, 51.7, r=1.4)

    def draw_import_from(fg, d):
        # A ringed planet and an arrow leaving it.
        d.ellipse([p(13, 21), p(33, 41)], fill=WHITE)
        cut = canvas(SIZE)
        stroke_line(ImageDraw.Draw(cut), [(9, 38), (37, 24)], 5.0, fill=WHITE)
        fg.putalpha(ImageChops.subtract(fg.split()[3], cut.split()[3]))
        stroke_line(d, [(10, 37.5), (36, 24.5)], 2.4, fill=WHITE)
        arrow_h(d, 39, 54, 31, shaft_w=4.2, head_len=8.0, head_half_h=7.2)

    def draw_request_from(_, d):
        # A platform above a planet, with an arrow from the planet up to it.
        rbox(d, 25, 13, 39, 19, r=1.8)
        rbox(d, 15, 17, 49, 22, r=1.8)
        arrow_v(d, 32, 34, 24, shaft_w=3.8, head_len=5.8, head_half_w=6.5)
        d.ellipse([p(22, 35), p(42, 55)], fill=WHITE)

    out["set-max"] = finish_tile(LOGISTICS, draw_le)
    out["min-delivery"] = finish_tile(LOGISTICS, draw_ge)
    out["no-max"] = finish_tile(LOGISTICS, draw_inf)
    out["get-max"] = finish_tile(LOGISTICS, draw_get_max)
    out["import-from"] = finish_tile(LOGISTICS, draw_import_from)
    out["request-from"] = finish_tile(LOGISTICS, draw_request_from)
    return out


def guide_icons():
    out = {}

    def draw_overview(_, d):
        f_it = ImageFont.truetype(FONT_ITALIC, int(round(27 * SCALE)))
        f_bd = ImageFont.truetype(FONT, int(round(23 * SCALE)))
        d.text(p(20, 32), "f", font=f_it, fill=WHITE, anchor="mm")
        d.text(p(39, 32), "(x)", font=f_bd, fill=WHITE, anchor="mm")

    def draw_language(_, d):
        draw_text(d, "(  )", 33, FONT, stroke=0.4)
        d.ellipse([p(29.5, 29.5), p(34.5, 34.5)], fill=WHITE)

    def draw_settings(_, d):
        arrow_h(d, 16, 48, 23, shaft_w=4.0, head_len=8.0, head_half_h=6.8)
        arrow_h(d, 48, 16, 41, shaft_w=4.0, head_len=8.0, head_half_h=6.8)

    def draw_mall(_, d):
        rbox(d, 13, 14, 51, 20.5, r=1.8)
        for row in range(2):
            for col in range(3):
                x = 13 + col * 14
                y = 25.5 + row * 13
                rbox(d, x, y, x + 10, y + 10, r=2.0)

    def draw_space(_, d):
        # Rocket: fuselage, fins and nozzle.
        d.polygon([p(32, 11), p(40, 24), p(40, 43), p(24, 43), p(24, 24)], fill=WHITE)
        d.polygon([p(24, 31), p(15, 44), p(24, 42)], fill=WHITE)
        d.polygon([p(40, 31), p(49, 44), p(40, 42)], fill=WHITE)
        d.polygon([p(27, 43), p(37, 43), p(39, 50), p(25, 50)], fill=WHITE)

    def draw_editor(_, d):
        rbox(d, 13, 15, 35, 21.5, r=1.8)
        rbox(d, 17, 21, 21.5, 46, r=1.2)
        rbox(d, 20, 29, 51, 35, r=1.8)
        rbox(d, 20, 41, 45, 47, r=1.8)

    out["overview"] = finish_tile(GUIDE, draw_overview)
    out["language"] = finish_tile(GUIDE, draw_language)
    out["settings"] = finish_tile(GUIDE, draw_settings)
    out["strategy-mall"] = finish_tile(GUIDE, draw_mall)
    out["strategy-space"] = finish_tile(GUIDE, draw_space)
    out["editor"] = finish_tile(GUIDE, draw_editor)
    return out


def shortcut(size):
    """Monochrome f(x) branching to three logistic slots, matching the mod emblem."""
    img = canvas(size)
    d = ImageDraw.Draw(img)

    def u(v):
        return v * (size / 56.0) * SCALE

    f_it = ImageFont.truetype(FONT_ITALIC, int(round(u(24))))
    f_bd = ImageFont.truetype(FONT, int(round(u(20))))
    d.text((u(16), u(13.5)), "f", font=f_it, fill=BLACK, anchor="mm")
    d.text((u(34.5), u(13.5)), "(x)", font=f_bd, fill=BLACK, anchor="mm")

    w = max(1.8 * SCALE, u(3.0))
    cx, lx, rx = u(28), u(11), u(45)
    y_top, y_bar, y_bot = u(27.5), u(33.5), u(39.5)
    d.line([(cx, y_top), (cx, y_bot)], fill=BLACK, width=int(round(w)))
    d.line([(lx + u(3.5), y_bar), (rx - u(3.5), y_bar)], fill=BLACK, width=int(round(w)))
    for x in (lx, rx):
        inset = u(3.5) if x == lx else -u(3.5)
        d.line([(x + inset, y_bar), (x, y_bar + u(3.5))], fill=BLACK, width=int(round(w)))
        d.line([(x, y_bar + u(3.5)), (x, y_bot)], fill=BLACK, width=int(round(w)))
        for jx, jy in [(x + inset, y_bar), (x, y_bar + u(3.5))]:
            d.ellipse([jx - w / 2, jy - w / 2, jx + w / 2, jy + w / 2], fill=BLACK)

    half_box = u(5.6)
    stroke = int(round(u(3.2 if size <= 24 else 2.8)))
    for bx in (lx, cx, rx):
        d.rectangle([bx - half_box, y_bot, bx + half_box, u(50.7)], outline=BLACK, width=stroke)
    return img


os.makedirs(OUT, exist_ok=True)
finish(pin(WHITE), 32, "pin-white")
finish(pin((30, 30, 30, 255)), 32, "pin-black")
for grow, name in [(True, "larger"), (False, "smaller")]:
    finish(resize(WHITE, grow), 32, name + "-white")
    finish(resize((30, 30, 30, 255), grow), 32, name + "-black")
finish(maximize(WHITE), 32, "maximize-white")
finish(maximize((30, 30, 30, 255)), 32, "maximize-black")
finish(wrap((0, 0, 0, 255)), 32, "wrap")
finish(history_arrow((0, 0, 0, 255), False), 32, "undo")
finish(history_arrow((0, 0, 0, 255), True), 32, "redo")
for sz in (56, 24):
    finish(shortcut(sz), sz, f"shortcut-x{sz}")
mod_icon = Image.open(os.path.join(TOOLS, "mod-icon.png"))
mod_icon.resize((128, 128), Image.LANCZOS).save(os.path.join(OUT, "mod-icon.png"))
mod_icon.resize((144, 144), Image.LANCZOS).save(os.path.join(MOD, "thumbnail.png"))
for name, img in icons().items():
    finish(img, SIZE, "fn-" + name)
for name, img in guide_icons().items():
    finish(img, SIZE, "doc-" + name)
