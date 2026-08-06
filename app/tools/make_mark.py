#!/usr/bin/env python3
"""Generate every piece of lore-mark artwork from one set of numbers.

Why the mark and the icon document are shaped this way: docs/decisions.md,
2026-08-06. Design authority: docs/design/prototypes/icon-lore-lowercase.html,
section "Chosen 2026-08-06", whose corrections T1-T5 are the constants below.

Outputs — all committed, so a build never runs this script:

    Sources/Lore/Assets/Lore.icon/                    macOS 26 icon document
    Sources/Lore/Assets/Lore.icns                     legacy icns, 16-512 @1x/@2x
    Sources/Lore/Assets/BrandMark.pdf                 sidebar chip, 1024 grid
    Sources/Lore/Assets/MenuBarMark.pdf               status item, 16 x 18 box
    Sources/Lore/Views/Design/LoreMarkGeometry.swift  the numbers the app draws with

Usage:   python3 tools/make_mark.py
Needs:   rsvg-convert (brew install librsvg) and iconutil (Xcode tools).
"""

import json
import os
import shutil
import subprocess
import tempfile

APP = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ASSETS = f'{APP}/Sources/Lore/Assets'
DESIGN = f'{APP}/Sources/Lore/Views/Design'

# --------------------------------------------------------------------- geometry
# Menlo's lowercase l, mapped into the 1024 macOS icon grid: the font's 2048-em
# outline scaled so its 1562-unit ink height becomes 496 and its baseline lands
# on y = 756.
KNEE, BASE, STEM_R = 627.4, 756.0, 525.34
FLAG_X, FLAG_Y = 373.23, 305.73
TAIL_X, TAIL_IN, TOP = 650.77, 576.78, 260.0

W = 62.0                # stem and foot bar, both at parity (T1, T2)
FINAL_INK = 512.0       # ink height, 62.1% of the 824 body (T3)
RIM_DOCK, RIM_CHIP = 0.10, 0.24   # rim per context (T5)

INK = {'x': FLAG_X, 'y': TOP, 'w': TAIL_X - FLAG_X, 'h': BASE - TOP}

# The macOS app-icon squircle: 824 body in a 1024 canvas, r = 22.55% of the body,
# 60% continuous corner smoothing. Frozen from figma-squircle so the shape is
# identical at every size (a CSS border-radius is visibly wrong next to it).
SQUIRCLE = (
    'M 626.7 100 c 104.06 0 156.1 0 195.84 20.25 a 185.81 185.81 0 0 1 81.2 81.2 '
    'c 20.25 39.75 20.25 91.78 20.25 195.84 L 924 626.7 c 0 104.06 0 156.1 -20.25 195.84 '
    'a 185.81 185.81 0 0 1 -81.2 81.2 c -39.75 20.25 -91.78 20.25 -195.84 20.25 L 397.3 924 '
    'c -104.06 0 -156.1 0 -195.84 -20.25 a 185.81 185.81 0 0 1 -81.2 -81.2 '
    'c -20.25 -39.75 -20.25 -91.78 -20.25 -195.84 L 100 397.3 c 0 -104.06 0 -156.1 20.25 -195.84 '
    'a 185.81 185.81 0 0 1 81.2 -81.2 c 39.75 -20.25 91.78 -20.25 195.84 -20.25 Z')

GRAPHITE = ('#33333a', '#151517')   # the Console tile
INK_WHITE, INK_ALPHA = '#FFFFFF', 0.94

# Status item, in the item's own points (board section "Menu bar", variant B:
# the bead sits to the right of the glyph, on the ink's optical middle).
MB_BOX, MB_H, MB_INK, MB_BEAD, MB_GAP, MB_TOP = 16.0, 18.0, 10.0, 3.2, 1.9, 3.6

ICNS_SIZES = (16, 32, 128, 256, 512)


def menlo_l():
    """The letter, at the board's stem/foot-bar weight."""
    sl = STEM_R - W
    t_top = BASE - W
    d = t_top - KNEE
    return (f'M{STEM_R} {KNEE}'
            f'Q{STEM_R} {KNEE + 0.496 * d:.2f} 539.78 {KNEE + 0.748 * d:.2f}'
            f'Q554.23 {t_top:.2f} 582.49 {t_top:.2f}'
            f'H{TAIL_X}V{BASE:.0f}H{TAIL_IN}'
            f'Q524.38 {BASE:.0f} 495.65 722.5'
            f'Q{sl:.2f} 689 {sl:.2f} {KNEE}'
            f'V{FLAG_Y}H{FLAG_X}V{TOP:.0f}H{STEM_R}Z')


def centroid_x():
    """Ink centroid — stem, top-left flag and foot bar as three rectangles (T4).

    Not the bounding-box centre: the stem carries ~78% of the mass and sits left
    of it, so centring the box leaves the mark visibly leaning.
    """
    sl = STEM_R - W
    parts = [
        (W * (BASE - TOP), (sl + STEM_R) / 2),
        ((sl - FLAG_X) * (FLAG_Y - TOP), (FLAG_X + sl) / 2),
        ((TAIL_X - TAIL_IN) * W, (TAIL_IN + TAIL_X) / 2),
    ]
    area = sum(p[0] for p in parts)
    return sum(p[0] * p[1] for p in parts) / area


def glyph():
    """The letter on the 1024 grid: scaled to T3's ink height, centroid on the
    body axis."""
    k = FINAL_INK / INK['h']
    cx, cy = INK['x'] + INK['w'] / 2, INK['y'] + INK['h'] / 2
    tx = 512 - cx * k + (512 - centroid_x()) * k
    ty = 508 - cy * k
    return (f'<path d="{menlo_l()}" fill="{INK_WHITE}" fill-opacity="{INK_ALPHA}" '
            f'transform="translate({tx:.2f} {ty:.2f}) scale({k:.4f})"/>')


# ------------------------------------------------------------------------ SVG
def glyph_svg():
    """The .icon layer: the letter alone, no tile.

    Icon Composer supplies the squircle, the material and the shadow; a layer
    that drew its own body would be masked twice.
    """
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" '
            'viewBox="0 0 1024 1024">' + glyph() + '</svg>\n')


def tile_svg(rim_alpha):
    """The whole Console tile as flat artwork — for the surfaces macOS does not
    composite for us (the sidebar chip, the legacy icns). Body, sheen, glyph, rim.
    """
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" '
        'viewBox="0 0 1024 1024">'
        '<defs><linearGradient id="g" x1="0" y1="0" x2="0" y2="1">'
        f'<stop offset="0" stop-color="{GRAPHITE[0]}"/>'
        f'<stop offset="1" stop-color="{GRAPHITE[1]}"/></linearGradient>'
        '<linearGradient id="sheen" x1="0" y1="0" x2="0" y2="1">'
        '<stop offset="0" stop-color="#ffffff" stop-opacity=".11"/>'
        '<stop offset="1" stop-color="#ffffff" stop-opacity="0"/></linearGradient>'
        f'<clipPath id="sq"><path d="{SQUIRCLE}"/></clipPath></defs>'
        '<g clip-path="url(#sq)">'
        '<rect x="100" y="100" width="824" height="824" fill="url(#g)"/>'
        '<rect x="100" y="100" width="824" height="400" fill="url(#sheen)"/>'
        + glyph() +
        '</g>'
        f'<path d="{SQUIRCLE}" fill="none" stroke="#ffffff" stroke-opacity="{rim_alpha}" '
        'stroke-width="4"/>'
        '</svg>\n')


def _mb_layout():
    """Glyph scale, glyph width and group left edge inside the 16 x 18 box.

    Variant B: glyph and bead are centred as a group, so the letter sits left of
    the box axis and the bead's space is reserved whether or not it is showing —
    the item must not twitch when a recording starts.
    """
    k = MB_INK / INK['h']
    gw = INK['w'] * k
    return k, gw, (MB_BOX - (gw + MB_GAP + MB_BEAD)) / 2


def menubar_svg():
    """The status-item glyph in its own box. Black, for a template image."""
    k, _, x0 = _mb_layout()
    tx = x0 - INK['x'] * k
    ty = MB_TOP - INK['y'] * k
    # Drawn at 4x the point box: rsvg maps px to pt at 0.75, and 18px would round
    # to a 14pt page — a 3.7% vertical stretch that would slide the glyph off the
    # baseline. 64 x 72 px lands on an exact 48 x 54 pt page.
    return ('<svg xmlns="http://www.w3.org/2000/svg" '
            f'width="{MB_BOX * 4:g}" height="{MB_H * 4:g}" viewBox="0 0 {MB_BOX:g} {MB_H:g}">'
            f'<path d="{menlo_l()}" fill="#000000" '
            f'transform="translate({tx:.4f} {ty:.4f}) scale({k:.6f})"/></svg>\n')


def bead_center():
    """Where the recording bead goes, in the same box (variant B)."""
    k, gw, x0 = _mb_layout()
    return x0 + gw + MB_GAP + MB_BEAD / 2, MB_TOP + MB_INK / 2


# -------------------------------------------------------------------- emitters
def icon_document(path):
    """Write Lore.icon — one layer over one background fill.

    macOS 26 owns the Dark appearance, and every `-specializations` key is
    dropped silently by actool, so this document is the Console coat in both
    appearances; the board's Paper light coat needs a manual Icon Composer pass.
    docs/decisions.md, 2026-08-06.
    """
    def srgb(hexstr):
        h = hexstr.lstrip('#')
        r, g, b = (int(h[i:i + 2], 16) / 255 for i in (0, 2, 4))
        return f'extended-srgb:{r:.5f},{g:.5f},{b:.5f},{1.0:.5f}'

    shutil.rmtree(path, ignore_errors=True)
    os.makedirs(f'{path}/Assets')
    with open(f'{path}/Assets/mark.svg', 'w') as fh:
        fh.write(glyph_svg())
    doc = {
        'fill': {'linear-gradient': [srgb(GRAPHITE[0]), srgb(GRAPHITE[1])]},
        'groups': [{'layers': [{'image-name': 'mark.svg', 'name': 'mark'}]}],
        'supported-platforms': {'circles': ['watchOS'], 'squares': ['macOS']},
    }
    with open(f'{path}/icon.json', 'w') as fh:
        json.dump(doc, fh, indent=2)
        fh.write('\n')


def svg_to_pdf(svg, out):
    # Cairo stamps the PDF with the current time unless SOURCE_DATE_EPOCH pins
    # it, which would make every regeneration a binary diff in git.
    env = dict(os.environ, SOURCE_DATE_EPOCH='0')
    subprocess.run(['rsvg-convert', '-f', 'pdf', '-o', out],
                   input=svg.encode(), check=True, env=env)


def write_icns(out):
    """Assemble the icns macOS reads through CFBundleIconFile.

    actool emits one too, but only with the 16 and 128 slots — every other size
    the Dock and Finder ask for is then upsampled from those. Render them all.
    """
    svg = tile_svg(RIM_DOCK).encode()
    env = dict(os.environ, SOURCE_DATE_EPOCH='0')
    with tempfile.TemporaryDirectory() as tmp:
        iconset = f'{tmp}/Lore.iconset'
        os.makedirs(iconset)
        for size in ICNS_SIZES:
            for scale, suffix in ((1, ''), (2, '@2x')):
                px = str(size * scale)
                subprocess.run(
                    ['rsvg-convert', '-f', 'png', '-w', px, '-h', px,
                     '-o', f'{iconset}/icon_{size}x{size}{suffix}.png'],
                    input=svg, check=True, env=env)
        subprocess.run(['iconutil', '--convert', 'icns', '--output', out, iconset],
                       check=True)


def write_geometry(out):
    """Emit the numbers the app itself must know, so nothing hand-copies them."""
    bx, by = bead_center()
    with open(out, 'w') as fh:
        fh.write(f'''// Generated by tools/make_mark.py — do not edit.
//
// The status-item numbers, in the item's own points, straight from the artwork
// that drew MenuBarMark.pdf. Variant B: the bead sits beside the glyph and its
// space is reserved in both states, so the letter never hops.

import CoreGraphics

enum LoreMarkGeometry {{
    /// The status-item drawing box — glyph and bead together.
    static let statusBox = CGSize(width: {MB_BOX:g}, height: {MB_H:g})

    /// Bead diameter at a 16pt status item, not the 8pt of the in-window dot.
    static let beadSize: CGFloat = {MB_BEAD:g}

    /// Bead centre inside `statusBox`, measured from its top-left.
    static let beadCenter = CGPoint(x: {bx:.3f}, y: {by:.3f})
}}
''')


def main():
    icon = f'{ASSETS}/Lore.icon'
    icns = f'{ASSETS}/Lore.icns'
    chip = f'{ASSETS}/BrandMark.pdf'
    menubar = f'{ASSETS}/MenuBarMark.pdf'
    geometry = f'{DESIGN}/LoreMarkGeometry.swift'

    icon_document(icon)
    write_icns(icns)
    svg_to_pdf(tile_svg(RIM_CHIP), chip)
    svg_to_pdf(menubar_svg(), menubar)
    write_geometry(geometry)

    for path in (icon, icns, chip, menubar, geometry):
        print('wrote', path)


if __name__ == '__main__':
    main()
