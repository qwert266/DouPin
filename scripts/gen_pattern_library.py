"""内置图纸素材库生成器。

产出（写入 doupin-src/Sources/Resources/PatternLibrary/）：
  catalog.json   全部图案元数据 + RLE 网格（供 App 读取）
  preview/*.png  每个图案的拼豆质感预览图（1024 长边，带豆粒高光）

图形来源三类：
  1) 字形：字母/数字/常用汉字（系统字体渲染 → 网格 mask）
  2) 手绘像素图形：心/星/花/动物/物件等（多边形/方程填充）
  3) 纹理图案：格纹/条纹/棋盘/雪花等（程序生成）

每套图形配多套主题配色（取自 Mard 295 色真实色号），
因此同一图形会产出多个"配色版本"，都是可直接拼的真实图纸。

用法：python gen_pattern_library.py [数量上限] [--sample N]
"""
import io
import json
import math
import os
import random
import re
import sys

from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'doupin-src'))
OUT_DIR = os.path.join(ROOT, 'Sources', 'Resources', 'PatternLibrary')
PREVIEW_DIR = os.path.join(OUT_DIR, 'preview')
THUMB_DIR = os.path.join(OUT_DIR, 'thumb')
THUMB_DIR = os.path.join(OUT_DIR, 'thumb')
PALETTE_SWIFT = os.path.join(ROOT, 'Sources', 'Core', 'Palette.swift')

FONT_DIR = r'C:\Windows\Fonts'
random.seed(20260915)


# ---------------------------------------------------------------- 调色板

def load_palette():
    src = io.open(PALETTE_SWIFT, encoding='utf-8').read()
    pat = re.compile(
        r'BeadColor\(id:\s*(\d+),\s*mard:\s*"([^"]+)".*?r:\s*(\d+),\s*g:\s*(\d+),\s*b:\s*(\d+)\)')
    out = {}
    for m in pat.finditer(src):
        out[int(m.group(1))] = (m.group(2), int(m.group(3)), int(m.group(4)), int(m.group(5)))
    return out


def rgb_of(pal, cid):
    return pal[cid][1:]


def hsv_sort_key(pal, cid):
    r, g, b = rgb_of(pal, cid)
    mx, mn = max(r, g, b), min(r, g, b)
    v = mx / 255.0
    s = 0 if mx == 0 else (mx - mn) / mx
    if mx == mn:
        h = 0
    elif mx == r:
        h = (60 * (g - b) / (mx - mn)) % 360
    elif mx == g:
        h = 60 * (b - r) / (mx - mn) + 120
    else:
        h = 60 * (r - g) / (mx - mn) + 240
    return (h, s, v)


def pick_by_hue(pal, hue_range, count, v_min=0.25, s_min=0.15):
    """按色相区间挑色号（用于自动组装主题配色）"""
    lo, hi = hue_range
    cands = []
    for cid in pal:
        h, s, v = hsv_sort_key(pal, cid)
        if lo <= h <= hi and v >= v_min and s >= s_min:
            cands.append((v, cid))
    cands.sort()
    if not cands:
        return []
    if len(cands) <= count:
        return [c for _, c in cands]
    step = len(cands) / count
    return [cands[int(i * step)][1] for i in range(count)]


# ---------------------------------------------------------------- 配色方案
# 每套：名称 + 主色序列（深→浅）。全部取自 295 色真实色号。

def build_schemes(pal):
    def darkest(cids):
        return sorted(cids, key=lambda c: sum(rgb_of(pal, c)))[0]

    def lightest(cids):
        return sorted(cids, key=lambda c: -sum(rgb_of(pal, c)))[0]

    schemes = []

    def add(name, name_en, cids):
        cids = [c for c in cids if c in pal]
        if len(cids) >= 3:
            schemes.append({'name': name, 'nameEn': name_en, 'colors': cids})

    warm = pick_by_hue(pal, (20, 60), 8, v_min=0.5)
    pink = pick_by_hue(pal, (300, 360), 7, v_min=0.5) + pick_by_hue(pal, (0, 20), 4, v_min=0.5)
    green = pick_by_hue(pal, (80, 160), 8, v_min=0.35)
    blue = pick_by_hue(pal, (180, 250), 8, v_min=0.35)
    purple = pick_by_hue(pal, (255, 300), 6, v_min=0.35)
    cyan = pick_by_hue(pal, (160, 200), 5, v_min=0.4)
    yellow = pick_by_hue(pal, (45, 70), 6, v_min=0.6)

    add('暖阳', 'Sunny', warm + [1])
    add('樱花', 'Sakura', pink + [2])
    add('森林', 'Forest', green + [2])
    add('海洋', 'Ocean', blue + [1])
    add('紫罗兰', 'Violet', purple + yellow[:2])
    add('薄荷', 'Mint', cyan + green[:3] + [1])
    add('柠檬', 'Lemon', yellow + warm[:3] + [1])
    add('糖果', 'Candy', pink[:3] + cyan[:2] + yellow[:2] + [2])
    add('霓虹', 'Neon', [darkest(pink), darkest(cyan), darkest(green), darkest(blue), lightest(yellow)])
    add('莫兰迪', 'Morandi', [c for c in (green[:3] + pink[:3] + blue[:3] + warm[:3])][:10])
    add('圣诞', 'Christmas', [darkest(green), green[len(green) // 2], darkest(pink), lightest(pink), 1])
    add('大地', 'Earth', warm[:4] + green[:3] + [16])
    add('黑白', 'Mono', [])
    return schemes


def mono_scheme(pal):
    """黑白灰：挑低饱和色号"""
    cands = []
    for cid in pal:
        h, s, v = hsv_sort_key(pal, cid)
        if s < 0.12:
            cands.append((v, cid))
    cands.sort()
    step = max(1, len(cands) // 6)
    return [cid for _, cid in cands[::step]][:6] or [list(pal.keys())[0]]


# ---------------------------------------------------------------- 图形 mask

def font(path, size):
    try:
        return ImageFont.truetype(path, size)
    except Exception:
        return None


def glyph_mask(ch, grid, bold=True):
    """把字符渲染成 grid×grid 的 0/1 网格（1 = 有豆）"""
    SS = 8  # 超采样
    size = grid * SS
    img = Image.new('L', (size, size), 0)
    d = ImageDraw.Draw(img)
    f = None
    for path in candidate_fonts():
        f = font(path, int(size * 0.82 if not re.match(r'[A-Za-z0-9]', ch) else size * 0.80))
        if f is not None:
            break
    if f is None:
        return None
    bbox = d.textbbox((0, 0), ch, font=f)
    w, h = bbox[2] - bbox[0], bbox[3] - bbox[1]
    d.text(((size - w) / 2 - bbox[0], (size - h) / 2 - bbox[1]), ch, font=f, fill=255)
    small = img.resize((grid, grid), Image.LANCZOS)
    px = small.load()
    return [[1 if px[x, y] > 110 else 0 for x in range(grid)] for y in range(grid)]


def canvas(grid):
    return [[0] * grid for _ in range(grid)]


def draw_shape(kind, g):
    """手绘像素图形（g = 网格尺寸）"""
    m = canvas(g)
    c = (g - 1) / 2.0

    def put(x, y):
        if 0 <= x < g and 0 <= y < g:
            m[y][x] = 1

    if kind == 'heart':
        for y in range(g):
            for x in range(g):
                nx, ny = (x - c) / (g * 0.36), (y - c * 1.02) / (g * 0.36)
                if (nx * nx + ny * ny - 1) ** 3 - nx * nx * ny ** 3 <= 0:
                    put(x, y)
    elif kind == 'star':
        R, r = g * 0.46, g * 0.19
        pts = []
        for i in range(10):
            ang = -math.pi / 2 + i * math.pi / 5
            rad = R if i % 2 == 0 else r
            pts.append((c + rad * math.cos(ang), c + rad * math.sin(ang)))
        poly(m, pts)
    elif kind == 'circle':
        for y in range(g):
            for x in range(g):
                if (x - c) ** 2 + (y - c) ** 2 <= (g * 0.44) ** 2:
                    put(x, y)
    elif kind == 'ring':
        for y in range(g):
            for x in range(g):
                d = math.hypot(x - c, y - c)
                if g * 0.30 <= d <= g * 0.46:
                    put(x, y)
    elif kind == 'square':
        for y in range(int(c - g * 0.36), int(c + g * 0.36) + 1):
            for x in range(int(c - g * 0.36), int(c + g * 0.36) + 1):
                put(x, y)
    elif kind == 'triangle':
        poly(m, [(c, c - g * 0.44), (c - g * 0.44, c + g * 0.36), (c + g * 0.44, c + g * 0.36)])
    elif kind == 'diamond':
        poly(m, [(c, c - g * 0.46), (c + g * 0.42, c), (c, c + g * 0.46), (c - g * 0.42, c)])
    elif kind == 'flower':
        for k in range(6):
            ang = k * math.pi / 3
            px_, py_ = c + g * 0.26 * math.cos(ang), c + g * 0.26 * math.sin(ang)
            for y in range(g):
                for x in range(g):
                    if (x - px_) ** 2 + (y - py_) ** 2 <= (g * 0.155) ** 2:
                        put(x, y)
    elif kind == 'tree':
        poly(m, [(c, c - g * 0.44), (c - g * 0.38, c + g * 0.10), (c + g * 0.38, c + g * 0.10)])
        for y in range(int(c + g * 0.14), int(c + g * 0.44) + 1):
            for x in range(int(c - g * 0.07), int(c + g * 0.08)):
                put(x, y)
    elif kind == 'house':
        poly(m, [(c, c - g * 0.42), (c - g * 0.40, c - g * 0.02), (c + g * 0.40, c - g * 0.02)])
        for y in range(int(c + g * 0.02), int(c + g * 0.42) + 1):
            for x in range(int(c - g * 0.32), int(c + g * 0.33)):
                put(x, y)
    elif kind == 'cat':
        poly(m, [(c - g * 0.34, c + g * 0.40), (c - g * 0.16, c - g * 0.44),
                 (c + g * 0.16, c - g * 0.44), (c + g * 0.34, c + g * 0.40)])
        for y in range(g):
            for x in range(g):
                if (x - c) ** 2 + ((y - c - g * 0.06) * 1.06) ** 2 <= (g * 0.36) ** 2:
                    put(x, y)
    elif kind == 'rabbit':
        for sgn in (-1, 1):
            for y in range(int(c - g * 0.46), int(c)):
                for x in range(int(c + sgn * g * 0.12), int(c + sgn * g * 0.26)):
                    put(x, y)
        for y in range(g):
            for x in range(g):
                if (x - c) ** 2 + ((y - c - g * 0.16) * 1.1) ** 2 <= (g * 0.32) ** 2:
                    put(x, y)
    elif kind == 'cloud':
        for cx, cy, rr in ((c - g * 0.18, c + g * 0.04, g * 0.20),
                           (c + g * 0.06, c - g * 0.02, g * 0.26),
                           (c + g * 0.28, c + g * 0.06, g * 0.18)):
            for y in range(g):
                for x in range(g):
                    if (x - cx) ** 2 + (y - cy) ** 2 <= rr * rr:
                        put(x, y)
    elif kind == 'moon':
        for y in range(g):
            for x in range(g):
                if (x - c) ** 2 + (y - c) ** 2 <= (g * 0.44) ** 2 and \
                   (x - c + g * 0.18) ** 2 + (y - c - g * 0.05) ** 2 > (g * 0.40) ** 2:
                    put(x, y)
    elif kind == 'sun':
        for y in range(g):
            for x in range(g):
                if (x - c) ** 2 + (y - c) ** 2 <= (g * 0.24) ** 2:
                    put(x, y)
        for k in range(8):
            ang = k * math.pi / 4
            for t in range(int(g * 0.28), int(g * 0.46)):
                put(int(round(c + t * math.cos(ang))), int(round(c + t * math.sin(ang))))
                put(int(round(c + t * math.cos(ang))) + 1, int(round(c + t * math.sin(ang))))
    elif kind == 'fish':
        for y in range(g):
            for x in range(g):
                nx, ny = (x - c + g * 0.06) / (g * 0.30), (y - c) / (g * 0.20)
                if nx * nx + ny * ny <= 1:
                    put(x, y)
        poly(m, [(c + g * 0.26, c), (c + g * 0.46, c - g * 0.22), (c + g * 0.46, c + g * 0.22)])
    elif kind == 'music':
        for y in range(int(c - g * 0.42), int(c + g * 0.22)):
            for x in range(int(c + g * 0.16), int(c + g * 0.28)):
                put(x, y)
        for y in range(g):
            for x in range(g):
                if (x - c + g * 0.06) ** 2 / (g * 0.13) ** 2 + (y - c - g * 0.24) ** 2 / (g * 0.10) ** 2 <= 1 or \
                   (x - c - g * 0.22) ** 2 / (g * 0.13) ** 2 + (y - c - g * 0.18) ** 2 / (g * 0.10) ** 2 <= 1:
                    put(x, y)
    elif kind == 'cup':
        poly(m, [(c - g * 0.26, c - g * 0.20), (c + g * 0.22, c - g * 0.20),
                 (c + g * 0.14, c + g * 0.40), (c - g * 0.18, c + g * 0.40)])
        for y in range(int(c - g * 0.06), int(c + g * 0.16)):
            for x in range(int(c + g * 0.22), int(c + g * 0.40)):
                put(x, y)
    elif kind == 'crown':
        poly(m, [(c - g * 0.42, c + g * 0.34), (c - g * 0.42, c - g * 0.30), (c - g * 0.20, c - g * 0.02),
                 (c, c - g * 0.40), (c + g * 0.20, c - g * 0.02), (c + g * 0.42, c - g * 0.30),
                 (c + g * 0.42, c + g * 0.34)])
    elif kind == 'gift':
        for y in range(int(c - g * 0.26), int(c + g * 0.42)):
            for x in range(int(c - g * 0.36), int(c + g * 0.37)):
                put(x, y)
        for y in range(int(c - g * 0.42), int(c - g * 0.26)):
            for x in range(int(c - g * 0.26), int(c + g * 0.27)):
                put(x, y)
    return m


def poly(m, pts):
    """扫描线填充多边形"""
    g = len(m)
    ys = [p[1] for p in pts]
    for y in range(max(0, int(min(ys))), min(g, int(max(ys)) + 1)):
        xs = []
        for i in range(len(pts)):
            x1, y1 = pts[i]
            x2, y2 = pts[(i + 1) % len(pts)]
            if (y1 <= y < y2) or (y2 <= y < y1):
                xs.append(x1 + (y - y1) * (x2 - x1) / (y2 - y1))
        xs.sort()
        for i in range(0, len(xs) - 1, 2):
            for x in range(max(0, int(xs[i])), min(g, int(xs[i + 1]) + 1)):
                m[y][x] = 1


def draw_texture(kind, g):
    m = canvas(g)
    if kind == 'stripes' or kind == 'checker' or kind == 'hstripe':
        for y in range(g):
            for x in range(g):
                if (x // 3 + y // 3) % 2 == 0:
                    m[y][x] = 1
    elif kind == 'dots':
        for y in range(g):
            for x in range(g):
                if x % 4 == 1 and y % 4 == 1:
                    m[y][x] = 1
    elif kind == 'frame':
        for y in range(g):
            for x in range(g):
                if x < 2 or y < 2 or x >= g - 2 or y >= g - 2:
                    m[y][x] = 1
    elif kind == 'corners':
        b = g // 4
        for y in range(g):
            for x in range(g):
                if (x < b and y < b) or (x >= g - b and y < b) or (x < b and y >= g - b) or (x >= g - b and y >= g - b):
                    if (x + y) % 3 != 0:
                        m[y][x] = 1
    elif kind == 'waves':
        for x in range(g):
            yy = int(g / 2 + (g * 0.22) * math.sin(2 * math.pi * x / (g / 2)))
            for d in (0, 1, 2):
                if 0 <= yy + d < g:
                    m[yy + d][x] = 1
    elif kind == 'snow':
        c = (g - 1) / 2
        for k in range(6):
            ang = k * math.pi / 3
            for t in [x * 0.5 for x in range(1, int(g * 0.9))]:
                if t > g * 0.46:
                    break
                put = (int(round(c + t * math.cos(ang))), int(round(c + t * math.sin(ang))))
                if 0 <= put[0] < g and 0 <= put[1] < g:
                    m[put[1]][put[0]] = 1
    return m


# ---------------------------------------------------------------- 上色

def colorize(mask, scheme_colors, pal, outline=True):
    """mask → 网格（0=空，其余=色号）。主色主体 + 深色描边 + 可选点缀"""
    g = len(mask)
    cells = [[0] * g for _ in range(g)]
    if not scheme_colors:
        return cells
    main = scheme_colors[len(scheme_colors) // 2]
    dark = scheme_colors[0]
    light = scheme_colors[-1]
    for y in range(g):
        for x in range(g):
            if not mask[y][x]:
                continue
            edge = False
            for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                yy, xx = y + dy, x + dx
                if yy < 0 or yy >= g or xx < 0 or xx >= g or not mask[yy][xx]:
                    edge = True
                    break
            if outline and edge:
                cells[y][x] = dark
            else:
                # 内部按到中心距离做一点层次：靠近中心用亮色
                c = (g - 1) / 2
                d = math.hypot(x - c, y - c) / (g * 0.5)
                cells[y][x] = main if d > 0.42 else (light if len(scheme_colors) > 3 else main)
    return cells


def rle_encode(cells):
    flat = [c for row in cells for c in row]
    out = []
    cur, cnt = flat[0], 1
    for v in flat[1:]:
        if v == cur:
            cnt += 1
        else:
            out.append(f'{cnt}x{cur}')
            cur, cnt = v, 1
    out.append(f'{cnt}x{cur}')
    return ','.join(out)


# ---------------------------------------------------------------- 预览渲染

_NOISE_CACHE = {}


def _noise(side):
    if side not in _NOISE_CACHE:
        _NOISE_CACHE[side] = Image.effect_noise((side, side), 16).convert('L')
    return _NOISE_CACHE[side]


def render_thumb(cells, pal, path, long_side=256):
    """列表用缩略图（轻量，不带噪点，保证滚动流畅）"""
    g = len(cells)
    cell = max(4, long_side // g)
    side = cell * g
    img = Image.new('RGB', (side, side), (247, 245, 240))
    d = ImageDraw.Draw(img)
    pad = max(1, int(cell * 0.07))
    for y, row in enumerate(cells):
        for x, cid in enumerate(row):
            if cid == 0:
                continue
            r, gg, b = rgb_of(pal, cid)
            d.rounded_rectangle([x * cell + pad, y * cell + pad,
                                 (x + 1) * cell - pad, (y + 1) * cell - pad],
                                radius=max(1, int(cell * 0.22)), fill=(r, gg, b))
    img.save(path, 'PNG', compress_level=6)
    return os.path.getsize(path)


def render_thumb(cells, pal, path, long_side=256):
    """列表用缩略图（轻量，不带噪点，保证滚动流畅）"""
    g = len(cells)
    cell = max(4, long_side // g)
    side = cell * g
    img = Image.new('RGB', (side, side), (247, 245, 240))
    d = ImageDraw.Draw(img)
    pad = max(1, int(cell * 0.07))
    for y, row in enumerate(cells):
        for x, cid in enumerate(row):
            if cid == 0:
                continue
            r, gg, b = rgb_of(pal, cid)
            d.rounded_rectangle([x * cell + pad, y * cell + pad,
                                 (x + 1) * cell - pad, (y + 1) * cell - pad],
                                radius=max(1, int(cell * 0.22)), fill=(r, gg, b))
    img.save(path, 'PNG', compress_level=6)
    return os.path.getsize(path)


def render_preview(cells, pal, path, long_side=2048):
    g = len(cells)
    cell = max(6, long_side // g)
    side = cell * g

    # 底色：米白拼豆垫板 + 稀疏噪点（让预览更有实物感）
    img = Image.new('RGB', (side, side), (247, 245, 240))
    mask = _noise(side).point(lambda v: 255 if v > 204 else 0)
    grain = Image.new('RGB', (side, side), (238, 235, 228))
    img = Image.composite(grain, img, mask)

    # 垫板网格淡纹（每格一道极浅的分隔线）
    d0 = ImageDraw.Draw(img)
    for i in range(g + 1):
        d0.line([(i * cell, 0), (i * cell, side)], fill=(240, 237, 231), width=1)
        d0.line([(0, i * cell), (side, i * cell)], fill=(240, 237, 231), width=1)

    d = ImageDraw.Draw(img)
    pad = max(1, int(cell * 0.07))
    for y, row in enumerate(cells):
        for x, cid in enumerate(row):
            if cid == 0:
                continue
            r, g_, b = rgb_of(pal, cid)
            x0, y0 = x * cell + pad, y * cell + pad
            x1, y1 = (x + 1) * cell - pad, (y + 1) * cell - pad
            d.rounded_rectangle([x0, y0, x1, y1], radius=max(1, int(cell * 0.22)),
                                fill=(r, g_, b))
            # 豆粒高光（提升质感，也让 PNG 不至于被压成纯色块）
            hi = (min(255, int(r + (255 - r) * 0.38)),
                  min(255, int(g_ + (255 - g_) * 0.38)),
                  min(255, int(b + (255 - b) * 0.38)))
            d.ellipse([x0 + cell * 0.18, y0 + cell * 0.16,
                       x0 + cell * 0.52, y0 + cell * 0.48], fill=hi)
    img.save(path, 'PNG', compress_level=6)
    return os.path.getsize(path)


# ---------------------------------------------------------------- 主流程

GLYPHS_LATIN = [chr(c) for c in range(ord('A'), ord('Z') + 1)] + [str(i) for i in range(10)]
GLYPHS_CJK = list('福爱家梦星月云海花猫兔熊心情心意快乐生日新年好运平安喜乐甜暖心暖阳光')
SHAPES = ['heart', 'star', 'circle', 'ring', 'square', 'triangle', 'diamond', 'flower',
          'tree', 'house', 'cat', 'rabbit', 'cloud', 'moon', 'sun', 'fish', 'music',
          'cup', 'crown', 'gift']
TEXTURES = ['stripes', 'checker', 'dots', 'frame', 'corners', 'waves', 'snow']

SHAPE_NAMES = {
    'heart': ('爱心', 'Heart'), 'star': ('星星', 'Star'), 'circle': ('圆点', 'Circle'),
    'ring': ('圆环', 'Ring'), 'square': ('方块', 'Square'), 'triangle': ('三角', 'Triangle'),
    'diamond': ('菱形', 'Diamond'), 'flower': ('小花', 'Flower'), 'tree': ('小树', 'Tree'),
    'house': ('房子', 'House'), 'cat': ('小猫', 'Cat'), 'rabbit': ('兔子', 'Rabbit'),
    'cloud': ('云朵', 'Cloud'), 'moon': ('月牙', 'Moon'), 'sun': ('太阳', 'Sun'),
    'fish': ('小鱼', 'Fish'), 'music': ('音符', 'Music'), 'cup': ('咖啡杯', 'Cup'),
    'crown': ('皇冠', 'Crown'), 'gift': ('礼物', 'Gift'),
}
TEXTURE_NAMES = {
    'stripes': ('格纹', 'Gingham'), 'checker': ('棋盘格', 'Checker'),
    'dots': ('波点', 'Polka Dots'), 'frame': ('边框', 'Frame'),
    'corners': ('四角花', 'Corners'), 'waves': ('波浪', 'Waves'), 'snow': ('雪花', 'Snowflake'),
}
CATEGORY = {'glyph': ('字母数字', 'Letters'), 'cjk': ('汉字', 'Characters'),
            'shape': ('图形', 'Shapes'), 'texture': ('纹理', 'Textures')}


def main():
    limit = int(sys.argv[1]) if len(sys.argv) > 1 and sys.argv[1].isdigit() else 10 ** 9
    sample = '--sample' in sys.argv

    pal = load_palette()
    print('调色板色号数:', len(pal))
    schemes = build_schemes(pal)
    schemes = [s for s in schemes if s['colors']] + [{'name': '黑白', 'nameEn': 'Mono', 'colors': mono_scheme(pal)}]
    print('配色方案:', len(schemes))

    os.makedirs(PREVIEW_DIR, exist_ok=True)
    os.makedirs(THUMB_DIR, exist_ok=True)
    os.makedirs(THUMB_DIR, exist_ok=True)
    catalog = []
    total_bytes = 0
    grid_choices = [29, 29, 32, 48]

    def emit(kind, key, name_zh, name_en, cat, mask, palette_subset, grid):
        nonlocal total_bytes
        cells = colorize(mask, palette_subset, pal)
        beads = sum(1 for row in cells for c in row if c)
        if beads < max(12, grid * grid * 0.03):
            return
        pid = f'{kind}_{key}_{len(catalog):04d}'
        prev_name = f'{pid}.png'
        size = render_preview(cells, pal, os.path.join(PREVIEW_DIR, prev_name),
                              long_side=2048)
        thumb_name = f'{pid}_t.png'
        render_thumb(cells, pal, os.path.join(THUMB_DIR, thumb_name))
        thumb_name = f'{pid}_t.png'
        render_thumb(cells, pal, os.path.join(THUMB_DIR, thumb_name))
        total_bytes += size
        colors_used = len({c for row in cells for c in row if c})
        catalog.append({
            'id': pid,
            'name': name_zh,
            'nameEn': name_en,
            'category': cat,
            'categoryEn': CATEGORY[cat][1],
            'w': grid, 'h': grid,
            'cells': rle_encode(cells),
            'colors': colors_used,
            'beads': beads,
            'preview': prev_name,
            'thumb': thumb_name,
            'thumb': thumb_name,
        })

    # 1) 字形（字母/数字）
    for i, ch in enumerate(GLYPHS_LATIN):
        if len(catalog) >= limit:
            break
        grid = grid_choices[i % len(grid_choices)]
        mask = glyph_mask(ch, grid)
        if not mask:
            continue
        for s in schemes:
            if len(catalog) >= limit:
                break
            emit('letter', ch.lower(), f'字母{ch}', f'Letter {ch}', 'glyph', mask, s['colors'], grid)

    # 2) 汉字
    for i, ch in enumerate(GLYPHS_CJK):
        if len(catalog) >= limit:
            break
        grid = 48 if i % 2 else 32
        mask = glyph_mask(ch, grid)
        if not mask:
            continue
        for s in schemes:
            if len(catalog) >= limit:
                break
            emit('cjk', f'u{ord(ch)}', f'「{ch}」', ch, 'cjk', mask, s['colors'], grid)

    # 3) 图形
    for i, kind in enumerate(SHAPES):
        if len(catalog) >= limit:
            break
        zh, en = SHAPE_NAMES[kind]
        for grid in (29, 48):
            if len(catalog) >= limit:
                break
            mask = draw_shape(kind, grid)
            for sc in schemes:
                if len(catalog) >= limit:
                    break
                emit('shape', f'{kind}{grid}', f'{zh}·{sc["name"]}',
                     f'{en} · {sc["nameEn"]}', 'shape', mask, sc['colors'], grid)

    # 4) 纹理
    for i, kind in enumerate(TEXTURES):
        if len(catalog) >= limit:
            break
        grid = 29 if kind in ('frame', 'corners') else 32
        mask = draw_texture(kind, grid)
        zh, en = TEXTURE_NAMES[kind]
        for s in schemes:
            if len(catalog) >= limit:
                break
            emit('texture', kind, f'{zh}·{s["name"]}', f'{en} · {s["nameEn"]}', 'texture', mask, s['colors'], grid)

    catalog_path = os.path.join(OUT_DIR, 'catalog.json')
    with io.open(catalog_path, 'w', encoding='utf-8', newline='\n') as f:
        json.dump({'version': 1, 'patterns': catalog}, f, ensure_ascii=False, separators=(',', ':'))

    print(f'图案数: {len(catalog)}')
    print(f'预览图总大小: {total_bytes / 1024 / 1024:.1f} MB')
    if catalog:
        print(f'单张预览平均: {total_bytes / len(catalog) / 1024:.0f} KB')
    print(f'catalog.json: {os.path.getsize(catalog_path) / 1024:.0f} KB')
    print('输出目录:', OUT_DIR)


if __name__ == '__main__':
    main()
