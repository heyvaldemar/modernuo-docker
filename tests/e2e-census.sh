#!/bin/bash
# Does tools/world-census.py count every entity of a save by type, compare two
# saves type by type, and refuse an index it cannot read exactly?
#
# No server and no client files: CI cannot run a shard (the client data is not
# redistributable), so the indexes are written here in the layout ModernUO's
# writer produces at the pinned MODERNUO_REF (GenericEntityPersistence.cs):
# version, the version 5 start time, the type table with its names behind
# 7-bit lengths that the writer pads to a fixed width, the entry count, and
# 26-byte entries. The two saves model an upgrade with a save migration: 1,469
# Backpack become VendorBuybackPack, 53 items decay off the ground, and the
# mobiles do not change.
#
#   ./tests/e2e-census.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

PASSED=0; FAILED=0
pass() { echo "  PASS: $1"; PASSED=$((PASSED+1)); }
fail() { echo "  FAIL: $1"; FAILED=$((FAILED+1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
CENSUS="${CENSUS:-tools/world-census.py}"

python3 - "$WORK" <<'PY'
import os, struct, sys
w = sys.argv[1]

def name(text):
    # WriteRaw reserves a length prefix wide enough for 3 bytes per character
    # and pads the actual length to that width; readers decode it the same.
    raw = text.encode()
    width = 1 if len(text) * 3 < 0x80 else 2
    n, out = len(raw), bytearray()
    for i in range(width):
        byte = n & 0x7F
        n >>= 7
        out.append(byte | (0x80 if i < width - 1 else 0))
    return bytes(out) + raw

def index(version, counts, ticks=638966496000000000):
    types = list(counts)
    b = struct.pack("<i", version) + (struct.pack("<q", ticks) if version == 5 else b"")
    b += struct.pack("<i", len(types)) + b"".join(name(t) for t in types)
    entries = [i for i, t in enumerate(types) for _ in range(counts[t])]
    b += struct.pack("<i", len(entries))
    for serial, t in enumerate(entries, 1):
        b += struct.pack("<HIqqi", t, serial, 0, serial * 40, 40)
    return b

def save(path, version, items, mobiles):
    for kind, counts in (("Items", items), ("Mobiles", mobiles)):
        os.makedirs(os.path.join(path, kind), exist_ok=True)
        open(os.path.join(path, kind, kind + ".idx"), "wb").write(index(version, counts))

mobiles = {"Server.Mobiles.Banker": 12, "Server.Mobiles.Rat": 340}
before = {"Server.Items.Backpack": 1600, "Server.Items.Gold": 2000, "Server.Items.Spawner": 90,
          "Server.Items.VendorBuybackPack": 0}
after = {"Server.Items.Backpack": 131, "Server.Items.Gold": 1947, "Server.Items.Spawner": 90,
         "Server.Items.VendorBuybackPack": 1469}
save(os.path.join(w, "before"), 5, before, mobiles)
save(os.path.join(w, "after"), 5, after, mobiles)
save(os.path.join(w, "v4"), 4, before, mobiles)

# What must be refused: a version this does not read, an index that ends
# before its entries, an entry naming a type the table does not have.
save(os.path.join(w, "v6"), 6, before, mobiles)
save(os.path.join(w, "short"), 5, before, mobiles)
p = os.path.join(w, "short", "Items", "Items.idx")
whole = open(p, "rb").read()           # read first: opening for write empties it
open(p, "wb").write(whole[:-26 * 10])
os.makedirs(os.path.join(w, "badtype", "Items"))
b = bytearray(index(5, {"Server.Items.Gold": 3}))
struct.pack_into("<H", b, len(b) - 26, 7)
open(os.path.join(w, "badtype", "Items", "Items.idx"), "wb").write(bytes(b))
os.makedirs(os.path.join(w, "empty"))
PY

echo "=== a census of a save, by type ==="
echo
if python3 "$CENSUS" "$WORK/before" > "$WORK/before.json" 2>"$WORK/err" \
   && python3 - "$WORK/before.json" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
i, m = c["Items"], c["Mobiles"]
assert i["version"] == 5 and i["total"] == 3690, i
assert i["by_type"] == {"Server.Items.Gold": 2000, "Server.Items.Backpack": 1600, "Server.Items.Spawner": 90}, i["by_type"]
assert m["total"] == 352 and m["by_type"]["Server.Mobiles.Rat"] == 340, m
assert i["saved"] and i["saved"].startswith("2025-"), i["saved"]
PY
then pass "version 5: 3,690 items and 352 mobiles, each type counted exactly, the save time read"
else fail "version 5 census: $(cat "$WORK/err"; head -c 300 "$WORK/before.json")"; fi

if python3 "$CENSUS" "$WORK/v4" > "$WORK/v4.json" 2>"$WORK/err" \
   && python3 -c 'import json,sys; a=json.load(open(sys.argv[1])); b=json.load(open(sys.argv[2])); assert a["Items"]["by_type"]==b["Items"]["by_type"] and a["Items"]["saved"] is None' "$WORK/v4.json" "$WORK/before.json" 2>>"$WORK/err"; then
  pass "version 4: the same counts, read without the version 5 start time"
else
  fail "version 4 census: $(cat "$WORK/err")"
fi

echo; echo "=== two saves compared, type by type ==="
echo
python3 "$CENSUS" "$WORK/after" > "$WORK/after.json"
out="$(python3 "$CENSUS" --compare "$WORK/before.json" "$WORK/after.json" 2>&1)"
if grep -qE '^Items +3690 -> +3637  \(-53\)$' <<<"$out"; then pass "totals: Items 3690 -> 3637 (-53)"; else fail "totals line: $out"; fi
if grep -qE '^ +-1469  Backpack  \(1600 -> 131\)$' <<<"$out" && grep -qE '^ +\+1469  VendorBuybackPack  \(0 -> 1469\)$' <<<"$out"; then
  pass "the migration shows as itself: Backpack -1469, VendorBuybackPack +1469"
else
  fail "the migration is not visible: $out"
fi
if grep -qE '^ +-53  Gold  \(2000 -> 1947\)$' <<<"$out" && ! grep -q "Spawner" <<<"$out"; then pass "decay shows as Gold -53, and an unchanged type is not listed"; else fail "the smaller moves: $out"; fi
if grep -A1 '^Mobiles' <<<"$out" | grep -q "every type holds the same count"; then pass "mobiles: every type holds the same count"; else fail "mobiles: $out"; fi

echo; echo "=== what it refuses rather than guesses ==="
echo
for c in "v6:index version 6" "short:holds room for" "badtype:names type 7 of 1" "empty:no <Kind>/<Kind>.idx"; do
  dir="${c%%:*}"; why="${c#*:}"
  out="$(python3 "$CENSUS" "$WORK/$dir" 2>&1)"; rc=$?
  if [ "$rc" = 2 ] && grep -q "$why" <<<"$out" && grep -q "nothing counted" <<<"$out" && ! grep -q '"total"' <<<"$out"; then
    pass "$dir: refused, exit 2 ($why)"
  else
    fail "$dir: exit $rc, said: $out"
  fi
done

echo
echo "passed: $PASSED   failed: $FAILED"
[ "$FAILED" -eq 0 ]
