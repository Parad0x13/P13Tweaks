# Generates Media/Arrow.tga: a white anti-aliased arrow pointing up (tinted in-game).
import os, struct

SIZE = 64
SS = 4  # supersampling per axis

# Arrow outline in 0-1 coords, y down (top-left origin): a chevron-style arrowhead with a notch.
POLY = [(0.50, 0.04), (0.84, 0.82), (0.50, 0.64), (0.16, 0.82)]  # fits inside a circle so rotation never clips

def inside(px, py, poly):
    hit = False
    j = len(poly) - 1
    for i in range(len(poly)):
        xi, yi = poly[i]; xj, yj = poly[j]
        if (yi > py) != (yj > py) and px < (xj - xi) * (py - yi) / (yj - yi) + xi:
            hit = not hit
        j = i
    return hit

pixels = bytearray()
for y in range(SIZE):
    for x in range(SIZE):
        n = sum(inside((x + (sx + 0.5) / SS) / SIZE, (y + (sy + 0.5) / SS) / SIZE, POLY)
                for sx in range(SS) for sy in range(SS))
        pixels += bytes((255, 255, 255, round(255 * n / (SS * SS))))  # BGRA

header = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, SIZE, SIZE, 32, 0x28)
out = os.path.join(os.path.dirname(__file__), "..", "Media", "Arrow.tga")
with open(out, "wb") as f:
    f.write(header + pixels)
print("wrote", os.path.abspath(out))
