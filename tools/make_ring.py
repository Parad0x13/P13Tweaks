# Generates Media/Ring.tga: a white anti-aliased ring with a soft glow (tinted in-game).
import math, os, struct

SIZE = 128
RADIUS = 54.0      # ring centre line
HALF_WIDTH = 4.0   # half thickness of the solid ring
GLOW = 8.0         # soft falloff outside the solid part

c = (SIZE - 1) / 2
pixels = bytearray()
for y in range(SIZE):
    for x in range(SIZE):
        d = abs(math.hypot(x - c, y - c) - RADIUS)
        if d <= HALF_WIDTH:
            a = 1.0
        elif d <= HALF_WIDTH + GLOW:
            t = 1 - (d - HALF_WIDTH) / GLOW
            a = 0.55 * t * t
        else:
            a = 0.0
        pixels += bytes((255, 255, 255, int(a * 255)))  # BGRA

# 18-byte header: uncompressed true-colour, 32bpp, 8 alpha bits, top-left origin
header = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, SIZE, SIZE, 32, 0x28)
out = os.path.join(os.path.dirname(__file__), "..", "Media", "Ring.tga")
with open(out, "wb") as f:
    f.write(header + pixels)
print("wrote", os.path.abspath(out))
