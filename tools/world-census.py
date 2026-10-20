#!/usr/bin/env python3
"""world-census.py: every entity in a ModernUO save, counted by type, and two
censuses compared.

    tools/world-census.py SAVES_DIR > before.json        a census of a save
    tools/world-census.py --compare before.json after.json

WHY. An upgrade that migrates the save format is a world change: old saves
load, and going back means restoring a backup. "It started and players can log
in" says nothing about whether every item came through. A count per type does:
take a census of the old build's last save, upgrade, take one of the new
build's first save, and compare. On the server this template comes from,
0.15.6.218 to 0.15.6.240 (two save migrations) was verified that way: the new
build loaded exactly the item and mobile counts of the old build's last save,
and the per-type comparison showed the release's one intended migration,
1,469 Backpack becoming VendorBuybackPack, with every other move explained by
minutes of spawning and decay.

WHAT IS READ: the save index of every entity kind in SAVES_DIR (Items,
Mobiles, Guilds, ...), <Kind>/<Kind>.idx, in the layout ModernUO writes from
index version 4 (GenericEntityPersistence.cs at the pinned MODERNUO_REF):

    int32  version (4 or 5)
    int64  the save's start time, .NET ticks           (version 5 only)
    int32  type count, then each type's full name: a 7-bit length, UTF-8
    int32  entry count, then per entry:
           uint16 type index, uint32 serial, int64 created, int64 bin offset,
           int32 length                                 (26 bytes)

Only the index is read, never the data file, and nothing is written: it is safe
on a copy of a live save or on one restored from a backup.

ANY INDEX THAT CANNOT BE READ EXACTLY IS REFUSED, NOT COUNTED. An unknown
version, a file that ends before its entries do, or a type index outside the
type table exits 2 with the reason. A census that guesses is worse than none:
the tool beside this one, world-stats.sh, once read a version 5 index at the
version 4 offset and reported 148,836,781 items and no types for a shard that
held 174 thousand.
"""
import datetime
import json
import os
import struct
import sys

ENTRY = struct.Struct("<HIqqi")  # type index, serial, created, bin offset, length


def refuse(message):
    sys.stderr.write("world-census: %s; nothing counted\n" % message)
    sys.exit(2)


def varint(data, offset, path):
    value = shift = 0
    while True:
        if offset >= len(data):
            refuse("%s ends inside a type name's length" % path)
        byte = data[offset]
        offset += 1
        value |= (byte & 0x7F) << shift
        shift += 7
        if not byte & 0x80:
            return value, offset
        if shift > 35:
            refuse("%s has a type name length that does not end" % path)


def read_index(path):
    data = open(path, "rb").read()
    if len(data) < 8:
        refuse("%s is too short to be a save index" % path)
    (version,) = struct.unpack_from("<i", data, 0)
    if version not in (4, 5):
        refuse("%s is index version %d; this reads versions 4 and 5" % (path, version))
    offset, saved = 4, None
    if version == 5:
        (ticks,) = struct.unpack_from("<q", data, offset)
        offset += 8
        if ticks > 0:
            saved = (datetime.datetime(1, 1, 1) + datetime.timedelta(microseconds=ticks // 10)).isoformat() + "Z"
    if offset + 4 > len(data):
        refuse("%s ends before its type table" % path)
    (type_count,) = struct.unpack_from("<i", data, offset)
    offset += 4
    if type_count < 0 or type_count > 65536:
        refuse("%s claims %d types" % (path, type_count))
    types = []
    for _ in range(type_count):
        length, offset = varint(data, offset, path)
        if offset + length > len(data):
            refuse("%s ends inside its type table" % path)
        types.append(data[offset:offset + length].decode("utf-8", "replace"))
        offset += length
    if offset + 4 > len(data):
        refuse("%s ends before its entry count" % path)
    (count,) = struct.unpack_from("<i", data, offset)
    offset += 4
    if count < 0 or offset + count * ENTRY.size > len(data):
        refuse("%s says %d entries and holds room for %d" % (path, count, (len(data) - offset) // ENTRY.size))
    by_type = {}
    for i in range(count):
        type_index = ENTRY.unpack_from(data, offset + i * ENTRY.size)[0]
        if type_index >= len(types):
            refuse("%s entry %d names type %d of %d" % (path, i, type_index, len(types)))
        name = types[type_index]
        by_type[name] = by_type.get(name, 0) + 1
    return {"version": version, "saved": saved, "total": count,
            "by_type": dict(sorted(by_type.items(), key=lambda kv: (-kv[1], kv[0])))}


def census(saves):
    kinds = {}
    for kind in sorted(os.listdir(saves)):
        path = os.path.join(saves, kind, kind + ".idx")
        if os.path.isfile(path):
            kinds[kind] = read_index(path)
    if not kinds:
        refuse("no <Kind>/<Kind>.idx under %s: not a save directory, or the shard has not saved yet" % saves)
    return kinds


def short(name):
    return name.rsplit(".", 1)[-1]


def compare(before, after):
    lines = []
    for kind in sorted(set(before) | set(after)):
        b = before.get(kind, {"total": 0, "by_type": {}})
        a = after.get(kind, {"total": 0, "by_type": {}})
        lines.append("%-8s %9d -> %9d  (%+d)" % (kind, b["total"], a["total"], a["total"] - b["total"]))
        moves = []
        for name in set(b["by_type"]) | set(a["by_type"]):
            delta = a["by_type"].get(name, 0) - b["by_type"].get(name, 0)
            if delta:
                moves.append((delta, name))
        for delta, name in sorted(moves, key=lambda m: (-abs(m[0]), m[1])):
            lines.append("  %+8d  %s  (%d -> %d)" % (delta, short(name), b["by_type"].get(name, 0), a["by_type"].get(name, 0)))
        if not moves:
            lines.append("  every type holds the same count")
    return "\n".join(lines)


def main(argv):
    if len(argv) == 3 and argv[0] == "--compare":
        before, after = (json.load(open(p)) for p in argv[1:])
        print(compare(before, after))
        return 0
    if len(argv) == 1 and os.path.isdir(argv[0]):
        print(json.dumps(census(argv[0]), indent=1))
        return 0
    sys.stderr.write(__doc__.split("\n\n")[1] + "\n")
    return 64


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
