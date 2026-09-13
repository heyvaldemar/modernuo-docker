#!/bin/sh
# The shard is healthy when its process is up AND it has written its world to
# disk recently. A server that cannot save looks exactly like one that can:
# process up, port open, players connected. On 2026-09-13 a shard served a world
# it could no longer write down for six minutes, and only a person opening the
# save directory for an unrelated reason noticed. This asks the one question
# that covers a full disk, a wrong permission, a broken mount and the next
# upstream rearrangement alike: is the save on disk newer than it should be?
set -u
pgrep -f '[M]odernUO' >/dev/null || exit 1

SAVE=${MODERNUO_SAVE_FILE:-/app/World/Saves/Items/Items.bin}
MAX=${MODERNUO_SAVE_MAX_AGE:-20}
now=$(date +%s)
if [ -f "$SAVE" ]; then
  age=$(( (now - $(stat -c %Y "$SAVE")) / 60 ))
else
  # No save yet: fine while the shard is young, a failure once it has been up
  # longer than the window. A world that is never written is a world lost.
  age=$(( $(ps -o etimes= -p 1 | tr -d ' ') / 60 ))
fi
[ "$age" -lt "$MAX" ]
