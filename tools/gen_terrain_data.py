"""Regenerate Features/MapTerrainData.lua from the WoW Forever client's own files.

Run after the client updates (the world's tile layout or pictures can change):

    python tools/gen_terrain_data.py            # writes Features/MapTerrainData.lua
    python tools/gen_terrain_data.py --check    # only compares with the current file

What it does (read-only on the game folder, needs only Python 3 and the game installed):
  1. finds the Forever product ("wowf") in <WoW>/.build.info and its build config;
  2. reads the encoding + root files of that build from the local CASC storage (<WoW>/Data/data);
  3. reads each world's .wdt (azeroth, kalimdor, 2991) and takes, for every tile the world has terrain for
     (MAIN chunk, flag 1), the minimap picture file ID from the MAID chunk (field 7).
So the output holds exactly the tiles this client has - no listfile guessing, no tiles from other versions.
The three .wdt file data IDs below come from the community listfile (github.com/wowdev/wow-listfile).
"""
import os, re, struct, sys, zlib, glob

WOW = os.environ.get("WOW_DIR", r"C:\Program Files (x86)\World of Warcraft")
PRODUCT = "wowf"
# world (instance) id -> file data id of world/maps/<folder>/<folder>.wdt
WDT = {0: 775971, 1: 782779, 2991: 7198644}
# Dungeons and raids whose terrain tiles actually show the place (open-air instances). Picked by looking at
# every instance's tiles (2026-11-22): indoor dungeons (Scholomance, Deadmines, Shadowfang Keep, BWL, Naxxramas,
# ...) only have the ground ABOVE them, and many have no terrain tiles at all - those keep the game's dungeon map.
# Left out because some of their tiles aren't in this client: Caverns of Time, Nightmare Grove, Excavation Site.
# World id -> (.wdt file data id, name); both from the client's own Map.db2 (fields Directory/MapName/WdtFileDataID).
DUNGEONS = {
    47: (790640, "Razorfen Kraul"),
    189: (788662, "Scarlet Monastery"),
    209: (791169, "Zul'Farrak"),
    309: (791432, "Zul'Gurub"),
    329: (791063, "Stratholme"),
    509: (775637, "Ruins of Ahn'Qiraj"),
    531: (775840, "Ahn'Qiraj Temple"),
    2720: (5554791, "The Searing Basin"),
    2784: (5900942, "Demon Fall Canyon"),
    2789: (5922434, "The Tainted Scar"),
    2791: (5930564, "Storm Cliffs"),
    2804: (6081492, "The Crystal Vale"),
    2807: (6099634, "Burning of Andorhal"),
    2853: (6357503, "Deadwind Pass"),
    2856: (6372264, "Scarlet Enclave"),
    2902: (6635982, "The Scarab Dais"),
    2959: (6982267, "City of Dalaran"),
    2999: (7255103, "Ruins of Lordaeron"),
}
WDT.update({w: v[0] for w, v in DUNGEONS.items()})
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Features", "MapTerrainData.lua")

HEADER = """-- P13Tweaks data: file IDs of the game's minimap terrain tiles, for MapTerrain.lua.
-- Generated from the game client's OWN world files, not from a listfile: for each world the tile table of
-- its .wdt (world/maps/azeroth/azeroth.wdt, kalimdor/kalimdor.wdt, 2991/2991.wdt; "has terrain" flag) and the
-- minimap picture file ID listed for each tile (MAID chunk, field 7), read from the WoW Forever build %s.
-- So every tile here exists in this client, and no tile it has is missing. Key = column * 64 + row.
-- Keyed by world (instance) ID: [0] = Eastern Kingdoms (folder Azeroth), [1] = Kalimdor,
-- [2991] = Zephras Isle (Forever's own island map, folder 2991), and the open-air dungeons and raids listed
-- in ns.TerrainDungeons (their tiles are drawn on the game's dungeon maps).
-- (Regenerate with tools/gen_terrain_data.py after a client update.)
local ADDON_NAME, ns = ...

ns.TerrainDungeons = {
%s}

ns.TerrainTiles = {
"""


def product_build():
    lines = open(os.path.join(WOW, ".build.info"), encoding="utf-8").read().splitlines()
    cols = [c.split("!")[0] for c in lines[0].split("|")]
    for ln in lines[1:]:
        row = dict(zip(cols, ln.split("|")))
        if row.get("Product") == PRODUCT:
            return row["Build Key"], row["Version"]
    sys.exit("product %r not found in .build.info" % PRODUCT)


DATA = os.path.join(WOW, "Data", "data")


def load_index():
    """ekey[:9] -> (archive, offset, encoded size), from every .idx (v7: 18-byte entries)."""
    idx = {}
    for path in sorted(glob.glob(os.path.join(DATA, "*.idx"))):
        d = open(path, "rb").read()
        entries_size = struct.unpack_from("<I", d, 0x20)[0]
        for o in range(0x28, 0x28 + entries_size - 17, 18):
            off5 = int.from_bytes(d[o + 9:o + 14], "big")
            idx[d[o:o + 9]] = (off5 >> 30, off5 & 0x3FFFFFFF, struct.unpack_from("<I", d, o + 14)[0])
    return idx


def blte(b):
    assert b[:4] == b"BLTE", "not BLTE"
    hsz = struct.unpack_from(">I", b, 4)[0]
    if hsz == 0:
        return b[9:] if b[8:9] == b"N" else zlib.decompress(b[9:])
    n = int.from_bytes(b[9:12], "big")
    sizes = [struct.unpack_from(">I", b, 12 + 24 * i)[0] for i in range(n)]
    pos, out = hsz, []
    for s in sizes:
        blk = b[pos:pos + s]
        pos += s
        out.append(blk[1:] if blk[:1] == b"N" else zlib.decompress(blk[1:]) if blk[:1] == b"Z" else sys.exit("BLTE chunk type %r" % blk[:1]))
    return b"".join(out)


def read_ekey(idx, ekey_hex):
    arch, off, size = idx[bytes.fromhex(ekey_hex)[:9]]
    with open(os.path.join(DATA, "data.%03d" % arch), "rb") as f:
        f.seek(off)
        return blte(f.read(size)[30:])   # (30-byte local header in front of the BLTE data)


def encoding_lookup(enc, wanted):
    """content key (16 bytes) -> encoded key (16 bytes) for the wanted content keys."""
    assert enc[:2] == b"EN"
    ckh, ekh = enc[3], enc[4]
    page = struct.unpack_from(">H", enc, 5)[0] * 1024
    ce_count = struct.unpack_from(">I", enc, 9)[0]
    espec = struct.unpack_from(">I", enc, 18)[0]
    pos = 22 + espec + ce_count * (ckh + 16)
    todo, found = set(wanted), {}
    for _ in range(ce_count):
        pg = enc[pos:pos + page]
        pos += page
        p = 0
        while p + 6 + ckh <= len(pg) and pg[p]:
            ck = pg[p + 6:p + 6 + ckh]
            if ck in todo:
                found[ck] = pg[p + 6 + ckh:p + 6 + ckh + ekh]
                todo.discard(ck)
            p += 6 + ckh + pg[p] * ekh
        if not todo:
            break
    return found


def root_ckeys(root, wanted_fdids):
    """fdid -> content key, from a TSFM version-2 root (17-byte block headers)."""
    assert root[:4] == b"TSFM"
    header_size, _ver, total, _named = struct.unpack_from("<IIII", root, 4)
    pos, got, out = header_size, 0, {}
    while pos < len(root):
        n = struct.unpack_from("<I", root, pos)[0]
        flags2 = struct.unpack_from("<I", root, pos + 12)[0]
        rec = 16 + (0 if flags2 & 0x10000000 else 8)
        p = pos + 17
        deltas = struct.unpack_from("<%di" % n, root, p)
        recp = p + n * 4
        fid = -1
        for i in range(n):
            fid += deltas[i] + 1
            if fid in wanted_fdids and fid not in out:
                out[fid] = root[recp + i * rec:recp + i * rec + 16]
        got += n
        pos = recp + n * rec
    assert pos == len(root) and got == total, "root layout changed - generator needs updating"
    return out


def wdt_tiles(b):
    """{col*64+row: minimap picture file id} for every tile the world has terrain for."""
    ch, p = {}, 0
    while p + 8 <= len(b):
        tag = b[p:p + 4][::-1].decode("latin1")
        size = struct.unpack_from("<I", b, p + 4)[0]
        ch[tag] = b[p + 8:p + 8 + size]
        p += 8 + size
    maid = struct.unpack("<%dI" % (4096 * 8), ch["MAID"])
    tiles = {}
    for i in range(4096):                      # index = row * 64 + col
        if struct.unpack_from("<I", ch["MAIN"], i * 8)[0] & 1 and maid[i * 8 + 7]:
            tiles[(i % 64) * 64 + i // 64] = maid[i * 8 + 7]
    return tiles


def main():
    build_key, version = product_build()
    cfg = {}
    cfg_path = os.path.join(WOW, "Data", "config", build_key[:2], build_key[2:4], build_key)
    for ln in open(cfg_path, encoding="utf-8", errors="replace"):
        if "=" in ln and not ln.startswith("#"):
            k, v = ln.split("=", 1)
            cfg[k.strip()] = v.strip()
    idx = load_index()
    enc = read_ekey(idx, cfg["encoding"].split()[1])
    root_ck = bytes.fromhex(cfg["root"])
    root = read_ekey(idx, encoding_lookup(enc, [root_ck])[root_ck].hex())
    cks = root_ckeys(root, set(WDT.values()))
    eks = encoding_lookup(enc, list(cks.values()))
    dungeons = "".join("[%d] = true,   -- %s\n" % (w, n) for w, (_, n) in DUNGEONS.items())
    out = [HEADER % (version, dungeons)]
    for world, fid in WDT.items():
        tiles = wdt_tiles(read_ekey(idx, eks[cks[fid]].hex()))
        print("world %d: %d tiles" % (world, len(tiles)))
        if world in DUNGEONS:   # every listed tile's picture must be in this client
            pcks = root_ckeys(root, set(tiles.values()))
            peks = encoding_lookup(enc, list(pcks.values()))
            missing = [f for f in tiles.values() if f not in pcks or pcks[f] not in peks or peks[pcks[f]][:9] not in idx]
            assert not missing, "world %d: %d tile pictures not in the client" % (world, len(missing))
        out.append("[%d] = {\n" % world)
        items = sorted(tiles.items())
        for i in range(0, len(items), 8):
            out.append(", ".join("[%d]=%d" % kv for kv in items[i:i + 8]) + ",\n")
        out.append("},\n")
    out.append("}\n")
    text = "".join(out)
    cur = open(OUT, encoding="utf-8", newline="").read() if os.path.exists(OUT) else ""
    if "--check" in sys.argv:
        print("up to date" if cur.replace("\r\n", "\n") == text else "DIFFERENT from the current file")
        return
    with open(OUT, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    print("wrote", os.path.normpath(OUT))


if __name__ == "__main__":
    main()
