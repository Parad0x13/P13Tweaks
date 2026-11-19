# Generates Media/P13Icon.tga: the Parad0x13 glider (the 5 green squares that draw a "P"),
# on a transparent background, for the minimap button. Anti-aliased by supersampling.
# Usage: python make_icon.py [out.tga]
#   Set SHOW_ALL = True to also draw the coral "1" and blue "3" squares (full 3x3 grid).
import os, struct, sys

SIZE = 64          # texture size (WoW needs a power of two); shown at 15x15 UI units
CELL = 14          # square size in pixels
GAP = 3            # gap between squares (CELL*3 + GAP*2 = 48, centred => edges on texel boundaries)
RADIUS = 0.0       # corner rounding per square in pixels (0 = sharp)
SS = 8             # supersampling per axis
SHADE = 0.25       # black overlay opacity at the bottom-right (0 at top-left); 0 = no fade
SHOW_ALL = False

GREEN = (0x3f, 0xb9, 0x50)
BLUE = (0x58, 0xa6, 0xff)
CORAL = (0xf8, 0x51, 0x49)

GLIDER = {(0, 0): GREEN, (1, 0): GREEN, (0, 1): GREEN, (2, 1): GREEN, (0, 2): GREEN}
EXTRA = {(2, 0): CORAL, (1, 1): BLUE, (1, 2): BLUE, (2, 2): BLUE}
CELLS = dict(GLIDER, **EXTRA) if SHOW_ALL else GLIDER

span = 3 * CELL + 2 * GAP
origin = (SIZE - span) / 2.0
pitch = CELL + GAP


def cell_at(px, py):
    x, y = px - origin, py - origin
    if not (0 <= x < span and 0 <= y < span):
        return None
    col, row = int(x // pitch), int(y // pitch)
    lx, ly = x - col * pitch, y - row * pitch
    if col > 2 or row > 2 or lx >= CELL or ly >= CELL or (col, row) not in CELLS:
        return None
    if RADIUS > 0:
        dx = max(RADIUS - lx, 0, lx - (CELL - RADIUS))
        dy = max(RADIUS - ly, 0, ly - (CELL - RADIUS))
        if dx * dx + dy * dy > RADIUS * RADIUS:
            return None
    base = CELLS[(col, row)]
    k = 1.0 - SHADE * (x + y) / (2.0 * span)   # diagonal fade, 0% top-left -> SHADE bottom-right
    return (base[0] * k, base[1] * k, base[2] * k)


pixels = bytearray()
for y in range(SIZE):
    for x in range(SIZE):
        r = g = b = n = 0
        for sy in range(SS):
            for sx in range(SS):
                c = cell_at(x + (sx + 0.5) / SS, y + (sy + 0.5) / SS)
                if c:
                    r += c[0]; g += c[1]; b += c[2]; n += 1
        if n:
            pixels += bytes((round(b / n), round(g / n), round(r / n), int(255 * n / (SS * SS))))  # BGRA
        else:
            pixels += bytes((0, 0, 0, 0))

# 18-byte header: uncompressed true-colour, 32bpp, 8 alpha bits, top-left origin
header = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, SIZE, SIZE, 32, 0x28)
out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "..", "Media", "P13Icon.tga")
with open(out, "wb") as f:
    f.write(header + pixels)
print("wrote", os.path.abspath(out))
