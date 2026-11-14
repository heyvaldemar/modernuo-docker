#!/bin/bash
# start.sh - ModernUO on a console it can be told to save on, and a save
# before every stop.
#
# MODERNUO DOES NOT SAVE ON SHUTDOWN. On SIGTERM it shuts down ("Detected
# SIGTERM", "Shutting down") without writing the world, so every stop,
# restart and update lost everything since the last autosave (measured on a
# live shard: 639 saves before a stop and 639 after; the compose file says
# more). Its console has a "save" command, but ModernUO reads its console only
# from a terminal: with standard input redirected it calls itself headless and
# turns console input off. So the server runs on a pseudo-terminal, script(1),
# whose input is a pipe only this script holds.
#
# ON SIGTERM this script writes "save" to that console, waits up to
# MODERNUO_STOP_SAVE_WAIT seconds (30) for the save to finish, judged by the
# world's Items.bin being written after the stop began, and then hands
# SIGTERM to the server, which shuts down as it always has. Docker's grace
# period (60 s) covers both.
#
# THE LOG. A terminal makes ModernUO colour its output, which is why the
# compose file gives the container none; the colour codes and the terminal's
# carriage returns are taken out here, on the way to `docker compose logs`.
#
# PROCESS 1 STAYS THIS SCRIPT, so that it gets Docker's SIGTERM, and it waits
# for the server's last lines before it exits with the server's status.
#
# Read whole before it runs: one brace group, ending in exit.
{
set -u
SAVE=${MODERNUO_SAVE_FILE:-/app/World/Saves/Items/Items.bin}
WAIT=${MODERNUO_STOP_SAVE_WAIT:-30}
case "$WAIT" in ''|*[!0-9]*) WAIT=30 ;; esac

console=/tmp/modernuo-console
rm -f "$console"
mkfifo -m 600 "$console" || { echo "start.sh: cannot make the console pipe" >&2; exit 1; }
exec 3<>"$console" || { echo "start.sh: cannot open the console pipe" >&2; exit 1; }
rm -f "$console"
command -v script >/dev/null || { echo "start.sh: script(1) is missing from the image; ModernUO would run headless, with no console to save on" >&2; exit 1; }

status=/tmp/start-status.$$
rm -f "$status"
{ script -qfec "exec dotnet ModernUO.dll" /dev/null <&3 3<&- 2>&1; echo "$?" >"$status"; } \
  | sed -u -E $'s/\x1b\\[[0-9;?]*[ -\\/]*[@-~]//g; s/\x1b[()][0-9A-Za-z]//g; s/\r$//' &
pl=$!

# shellcheck disable=SC2329   # called from stop, which the trap runs
server() {  # the dotnet process, by its own name: script's command line names ModernUO too
  local p c
  for p in /proc/[0-9]*; do
    read -r c <"$p/comm" 2>/dev/null || continue
    [ "$c" = dotnet ] && { echo "${p#/proc/}"; return 0; }
  done
  return 1
}
stopping=0
# shellcheck disable=SC2329   # run by the trap below
stop() {
  [ "$stopping" = 1 ] && return
  stopping=1
  local t m=0 pid
  t=$(date +%s)
  echo "start.sh: stopping: \"save\" on the server's console first"
  printf 'save\n' >&3
  for _ in $(seq 1 "$WAIT"); do
    m=$(stat -c %Y "$SAVE" 2>/dev/null || echo 0)
    [ "$m" -ge "$t" ] && break
    sleep 1
  done
  if [ "$m" -ge "$t" ]; then
    echo "start.sh: the world is saved (${SAVE##*/} written $(( m - t ))s after the stop began); the server stops now"
  else
    echo "start.sh: no save within ${WAIT}s; the server stops now, and the world is as of its last autosave"
  fi
  pid=$(server) && kill -TERM "$pid" 2>/dev/null
}
trap stop TERM INT
while kill -0 "$pl" 2>/dev/null; do wait "$pl"; done
rc="$(cat "$status" 2>/dev/null)"
exit "${rc:-1}"
}
