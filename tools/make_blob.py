# Generates Media/Blob.tga: a white soft round spot (alpha fades from the middle to the edge), tinted in-game.
# Used by the farming heatmap (FarmHeat.lua).
import math, os, struct

SIZE = 64

c = (SIZE - 1) / 2
pixels = bytearray()
for y in range(SIZE):
    for x in range(SIZE):
        d = math.hypot(x - c, y - c) / (SIZE / 2)   # 0 in the middle, 1 at the edge
        a = max(0.0, 1 - d)
        a = a * a * (3 - 2 * a)                      # smoothstep: soft edge, fuller middle
        pixels += bytes((255, 255, 255, int(a * 255)))  # BGRA

# 18-byte header: uncompressed true-colour, 32bpp, 8 alpha bits, top-left origin
header = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, SIZE, SIZE, 32, 0x28)
out = os.path.join(os.path.dirname(__file__), "..", "Media", "Blob.tga")
with open(out, "wb") as f:
    f.write(header + pixels)
print("wrote", os.path.abspath(out))
