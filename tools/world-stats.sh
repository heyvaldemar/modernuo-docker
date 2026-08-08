#!/bin/bash
# world-stats.sh — how much world is actually in the save.
#
# WHY: "is the world populated?" is otherwise answered by looking at a game
# client, which shows one screen at a time. A freshly created ModernUO world
# holds 46 items and 2 mobiles and looks, from any single screen of bare
# terrain, exactly like a shard whose generation simply has not reached you yet.
# A number settles it.
#
# It reads the SAVE INDEX, not the running server: ModernUO has no remote console
# and the index carries both an exact count and the type table. Nothing is
# stopped and nobody is kicked — the index files are only ever rewritten whole,
# at save time, so reading them while players are connected is safe.
#
# The counts change only when the server saves (autosave, or [Save), so a
# generation command run seconds ago will not show up until the next save.
#
# Usage: tools/world-stats.sh [container-name]     (default: uo)
set -uo pipefail
C=${1:-uo}

docker inspect "$C" >/dev/null 2>&1 || { echo "no container named $C"; exit 1; }

items=$(mktemp); mobs=$(mktemp)
trap 'rm -f "$items" "$mobs"' EXIT

docker exec "$C" sh -c 'cat /app/Saves/Items/Items.idx'     > "$items" 2>/dev/null
docker exec "$C" sh -c 'cat /app/Saves/Mobiles/Mobiles.idx' > "$mobs"  2>/dev/null

python3 - "$items" "$mobs" <<'PY'
import struct, sys

def varint(b, i):
    r = s = 0
    while True:
        x = b[i]; i += 1
        r |= (x & 0x7F) << s; s += 7
        if not x & 0x80:
            return r, i

def read(path):
    """(count, [type names]) from a ModernUO save index.

    Layout: int32 version, int32 typeCount, typeCount x <varint length, utf8>,
    int32 entry count, then the entries themselves."""
    try:
        b = open(path, "rb").read()
    except OSError:
        return 0, []
    if len(b) < 12:
        return 0, []
    tc, = struct.unpack_from("<i", b, 4)
    i = 8; types = []
    for _ in range(tc):
        n, i = varint(b, i)
        types.append(b[i:i+n].decode("utf-8", "ignore").split(".")[-1]); i += n
    cnt, = struct.unpack_from("<i", b, i)
    return cnt, types

ic, itypes = read(sys.argv[1])
mc, mtypes = read(sys.argv[2])

print("  items   %8d   (%d distinct types)" % (ic, len(itypes)))
print("  mobiles %8d   (%d distinct types)" % (mc, len(mtypes)))
print()

# Two separate questions, because a world can be fully decorated and still have
# nobody living in it — that is exactly the state a half-finished generation
# leaves behind, and the one most easily mistaken for success.
spawners = [t for t in itypes if "Spawner" in t]
print("  spawner types present:", ", ".join(spawners) if spawners else "NONE — nothing spawns")

TRADE = ("Vendor", "Smith", "Alchemist", "Banker", "Baker", "Tailor", "Provisioner",
         "Healer", "Barkeeper", "Herbalist", "Mage", "Butcher", "Miner", "Farmer")
trade = sorted({t for t in mtypes if any(k in t for k in TRADE)})
print("  townsfolk/vendor types: %d%s"
      % (len(trade), (" — " + ", ".join(trade[:8]) + "...") if trade else " — NONE"))
print()

if ic < 1000:
    print("  VERDICT: the world is EMPTY — decoration was never generated.")
elif not spawners:
    print("  VERDICT: decorated, but NOT inhabited — no spawners were imported.")
else:
    print("  VERDICT: decorated and inhabited.")
PY
