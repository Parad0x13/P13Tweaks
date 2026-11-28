"""Extract named files (e.g. Blizzard interface Lua/XML) from the WoW Forever CASC storage by path name hash.
Usage: python tools/casc_named.py <outdir> "Interface/AddOns/Blizzard_ActionBar/Shared/ActionButton.lua" ..."""
import os, sys, struct
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_terrain_data as g

M = 0xFFFFFFFF
def rot(x, k): return ((x << k) | (x >> (32 - k))) & M

def hashlittle2(data, pc=0, pb=0):
    length = len(data)
    a = b = c = (0xdeadbeef + length + pc) & M
    c = (c + pb) & M
    i = 0
    while length > 12:
        a = (a + struct.unpack_from("<I", data, i)[0]) & M
        b = (b + struct.unpack_from("<I", data, i + 4)[0]) & M
        c = (c + struct.unpack_from("<I", data, i + 8)[0]) & M
        a = (a - c) & M; a ^= rot(c, 4);  c = (c + b) & M
        b = (b - a) & M; b ^= rot(a, 6);  a = (a + c) & M
        c = (c - b) & M; c ^= rot(b, 8);  b = (b + a) & M
        a = (a - c) & M; a ^= rot(c, 16); c = (c + b) & M
        b = (b - a) & M; b ^= rot(a, 19); a = (a + c) & M
        c = (c - b) & M; c ^= rot(b, 4);  b = (b + a) & M
        length -= 12; i += 12
    if length == 0:
        return c, b
    tail = data[i:] + b"\0" * 12
    a = (a + struct.unpack_from("<I", tail, 0)[0]) & M
    b = (b + struct.unpack_from("<I", tail, 4)[0]) & M
    c = (c + struct.unpack_from("<I", tail, 8)[0]) & M
    c ^= b; c = (c - rot(b, 14)) & M
    a ^= c; a = (a - rot(c, 11)) & M
    b ^= a; b = (b - rot(a, 25)) & M
    c ^= b; c = (c - rot(b, 16)) & M
    a ^= c; a = (a - rot(c, 4)) & M
    b ^= a; b = (b - rot(a, 14)) & M
    c ^= b; c = (c - rot(b, 24)) & M
    return c, b

def name_hash(path):
    c, b = hashlittle2(path.replace("/", "\\").upper().encode())
    return (c << 32) | b

def root_named(root):
    """name hash -> content key (TSFM root; per block: fdid deltas, ckeys, then name hashes)."""
    header_size = struct.unpack_from("<I", root, 4)[0]
    pos, out = header_size, {}
    while pos < len(root):
        n = struct.unpack_from("<I", root, pos)[0]
        flags2 = struct.unpack_from("<I", root, pos + 12)[0]
        named = not (flags2 & 0x10000000)
        p = pos + 17 + n * 4
        cks = p
        p += n * 16
        if named:
            for i in range(n):
                h = struct.unpack_from("<Q", root, p + i * 8)[0]
                out.setdefault(h, root[cks + i * 16:cks + i * 16 + 16])
            p += n * 8
        pos = p
    return out

def main():
    paths = sys.argv[2:]
    outdir = sys.argv[1]
    build_key, _ = g.product_build()
    cfg = {}
    for ln in open(os.path.join(g.WOW, "Data", "config", build_key[:2], build_key[2:4], build_key), encoding="utf-8", errors="replace"):
        if "=" in ln and not ln.startswith("#"):
            k, v = ln.split("=", 1); cfg[k.strip()] = v.strip()
    idx = g.load_index()
    enc = g.read_ekey(idx, cfg["encoding"].split()[1])
    rck = bytes.fromhex(cfg["root"])
    root = g.read_ekey(idx, g.encoding_lookup(enc, [rck])[rck].hex())
    named = root_named(root)
    print("named entries:", len(named))
    want = {p: named.get(name_hash(p)) for p in paths}
    eks = g.encoding_lookup(enc, [c for c in want.values() if c])
    os.makedirs(outdir, exist_ok=True)
    for p, ck in want.items():
        if not ck or ck not in eks or eks[ck][:9] not in idx:
            print("MISSING", p); continue
        data = g.read_ekey(idx, eks[ck].hex())
        dst = os.path.join(outdir, p.replace("/", "_"))
        open(dst, "wb").write(data)
        print("OK", p, len(data))

main()
