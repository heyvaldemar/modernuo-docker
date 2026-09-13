#!/bin/sh
# init-save-layout.sh — runs before the shard on every start, and is idempotent.
#
# THE SAVE DIRECTORY MUST NOT BE THE MOUNT POINT. ModernUO 0.15.6.178 publishes
# a world save by renaming: it writes <savePath>.next, sets <savePath> aside as
# <savePath>.previous-<stamp>, then renames the staged directory into place. A
# bind mount cannot be renamed. What actually happens, measured on a live shard
# forty seconds after the upgrade: the set-aside falls back to moving the
# CONTENTS out file by file, which empties the host directory, and the rename
# into place then fails because the mount point still exists. Every save fails
# from then on, once a minute, with the only complete copy of the world sitting
# in <savePath>.next inside the container's writable layer, which a recreate
# throws away. Nothing on the host says a word: the container stays healthy,
# the port stays open, the player count stays normal.
#
# So the mount is the PARENT (./data:/app/World), world.savePath is World/Saves,
# and this script does the two things a deployment on the old layout needs:
#   1. move a save that sits at the root of ./data into ./data/Saves/
#   2. point world.savePath at World/Saves in config/modernuo.json
# Both are checked, not assumed, and both refuse rather than guess.
set -eu

WORLD=${WORLD_DIR:-/world}
CONF=${CONFIG_DIR:-/configuration}
CFG="$CONF/modernuo.json"
WANT=${SAVE_PATH:-World/Saves}
SUB=${WANT#World/}

mkdir -p "$WORLD/$SUB" "$CONF"

# ── 1. a save at the root of the mount is the old layout ──────────────────────
if [ -e "$WORLD/Items" ] || [ -e "$WORLD/Mobiles" ] || [ -e "$WORLD/Accounts" ]; then
  if [ -n "$(ls -A "$WORLD/$SUB" 2>/dev/null)" ]; then
    echo "REFUSING TO GUESS: a save sits at $WORLD/ (old layout) and another under $WORLD/$SUB/." >&2
    echo "Two worlds, and no way to know which one is yours. Move one aside by hand, then start again." >&2
    exit 1
  fi
  echo "old save layout found at $WORLD/; moving it into $WORLD/$SUB/"
  for entry in "$WORLD"/* "$WORLD"/.[!.]*; do
    [ -e "$entry" ] || continue
    name=$(basename "$entry")
    case "$name" in "$SUB"|"$SUB".*) continue ;; esac
    mv "$entry" "$WORLD/$SUB/$name"
    echo "  moved $name"
  done
fi

# ── 2. world.savePath must name the subdirectory, not the mount ───────────────
if [ -f "$CFG" ]; then
  if grep -q '"world.savePath"' "$CFG"; then
    cur=$(sed -n 's/.*"world.savePath": *"\([^"]*\)".*/\1/p' "$CFG" | head -n 1)
    if [ "$cur" != "$WANT" ]; then
      sed -i 's|"world.savePath": *"[^"]*"|"world.savePath": "'"$WANT"'"|' "$CFG"
      echo "world.savePath: $cur -> $WANT"
    fi
  elif grep -qE '"settings": *\{ *\}' "$CFG"; then
    sed -i 's|"settings": *{ *}|"settings": { "world.savePath": "'"$WANT"'" }|' "$CFG"
    echo "world.savePath added: $WANT"
  elif grep -q '"settings"' "$CFG"; then
    # Inserted as the first key. ModernUO keeps settings as a sorted dictionary
    # and re-sorts on its next save, so position does not matter to it.
    sed -i 's|"settings": *{|"settings": {\n    "world.savePath": "'"$WANT"'",|' "$CFG"
    echo "world.savePath added: $WANT"
  fi
else
  # A fresh deployment. ModernUO reads this, then fills in everything else
  # itself on first boot exactly as it would with no file at all: the prompts
  # run for whatever is still empty, and that is everything but this key.
  printf '{\n  "settings": {\n    "world.savePath": "%s"\n  }\n}\n' "$WANT" > "$CFG"
  echo "fresh configuration written with world.savePath $WANT"
fi

grep -q '"world.savePath": *"'"$WANT"'"' "$CFG" || {
  echo "world.savePath is not $WANT in $CFG after editing it; refusing to start the shard on the wrong layout" >&2
  exit 1
}
echo "save layout ok: $WORLD/$SUB with world.savePath $WANT"
