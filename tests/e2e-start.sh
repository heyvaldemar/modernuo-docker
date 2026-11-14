#!/bin/bash
# tools/start.sh against the image this repository builds, with a stand-in
# for the shard (tests/fixtures/fake-dotnet, first on PATH): CI has no UO
# client files, so no real shard runs here. What is proven is the signal
# path; the save itself is measured on a live shard.
#
#   the control   the image's own entrypoint: the server is headless (no
#                 console), and a stop writes no world
#   start.sh      the server gets a terminal, its colour codes do not reach
#                 `docker logs`, process 1 is start.sh, the health check
#                 finds the server under it, and on docker stop
#                 "save" goes to the console, the world is written after the
#                 stop began and before the server gets SIGTERM, which it
#                 exits by (143), inside the grace period
#
#   tests/e2e-start.sh [image]   (default: the compose file's image)
# shellcheck disable=SC2015   # pass and fail always exit 0, so "A && pass || fail" is if-then-else here
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

PASSED=0; FAILED=0
pass() { echo "  PASS: $1"; PASSED=$((PASSED+1)); }
fail() { echo "  FAIL: $1"; FAILED=$((FAILED+1)); }

IMAGE="${1:-modernuo:$(sed -n 's/.*MODERNUO_REF:-\([0-9.]*\)}.*/\1/p' docker-compose.yml | head -1)}"
docker image inspect "$IMAGE" >/dev/null 2>&1 || { echo "no image $IMAGE; build it first (docker compose build)"; exit 1; }
C1="muo-starttest-bare-$$"; C2="muo-starttest-wrapped-$$"
cleanup() { docker rm -f "$C1" "$C2" >/dev/null 2>&1; }
trap cleanup EXIT
run() {  # name, wrapped|bare
  set -- "$1" "$2" -e MODERNUO_STOP_SAVE_WAIT=10 -v "$PWD/tests/fixtures/fake-dotnet:/usr/local/bin/dotnet:ro"
  if [ "$2" = wrapped ]; then
    docker run -d --name "$1" "${@:3}" --entrypoint /bin/bash -v "$PWD/tools/start.sh:/start.sh:ro" -v "$PWD/tools/healthcheck.sh:/healthcheck.sh:ro" "$IMAGE" /start.sh >/dev/null
  else
    docker run -d --name "$1" "${@:3}" "$IMAGE" >/dev/null
  fi
  for _ in $(seq 1 30); do docker logs "$1" 2>&1 | grep -q 'Console input' && return 0; sleep 1; done
  return 1
}
mtime() { docker exec "$1" sh -c 'stat -c %Y /app/World/Saves/Items/Items.bin 2>/dev/null || echo none'; }

echo "    $IMAGE"
echo
echo "=== the image's own entrypoint (the control) ==="
if run "$C1" bare; then
  docker logs "$C1" 2>&1 | grep -q 'headless' && pass "headless: no console to save on" || fail "the stand-in had a console under the image's own entrypoint"
  docker stop -t 30 "$C1" >/dev/null
  [ "$(docker inspect -f '{{.State.ExitCode}}' "$C1")" = 143 ] && ! docker logs "$C1" 2>&1 | grep -q 'World saved' \
    && pass "a stop: exit 143, and no world written" || fail "the control wrote a world, or exited $(docker inspect -f '{{.State.ExitCode}}' "$C1")"
else
  fail "the image's own entrypoint never started the stand-in"
fi

echo
echo "=== tools/start.sh ==="
if run "$C2" wrapped; then
  logs="$(docker logs "$C2" 2>&1)"
  grep -q 'Console input enabled' <<<"$logs" && pass "the server has a terminal: its console is on" || fail "the server is headless under start.sh: $(head -3 <<<"$logs" | tr '\n' ' ')"
  [ "$(grep -c $'\033' <<<"$logs")" = 0 ] && pass "no colour codes in docker logs" || fail "colour codes reached docker logs"
  p1="$(docker exec "$C2" sh -c 'tr "\0" " " </proc/1/cmdline')"
  [[ $p1 == "/bin/bash /start.sh"* ]] && pass "process 1 is tools/start.sh" || fail "process 1 is: $p1"
  docker exec "$C2" sh /healthcheck.sh && pass "the health check finds the server under start.sh (pgrep -x dotnet)" \
    || fail "the health check is red with the server running under start.sh"
  [ "$(mtime "$C2")" = none ] && pass "no world before the stop" || fail "a world before the stop"
  since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  s0=$SECONDS; docker stop -t 60 "$C2" >/dev/null; secs=$((SECONDS - s0))
  code="$(docker inspect -f '{{.State.ExitCode}}' "$C2")"
  after="$(docker logs --since "$since" "$C2" 2>&1)"
  order="$(grep -n -E 'start.sh: stopping|World saved|start.sh: the world is saved|Detected SIGTERM' <<<"$after" | cut -d: -f2- | tr '\n' '|')"
  echo "    the stop, in order: $order"
  [[ $order == *"start.sh: stopping"*"|"*"World saved"*"|"*"start.sh: the world is saved"*"|"*"Detected SIGTERM"* ]] \
    && pass "\"save\" on the console, the world written, then SIGTERM to the server" || fail "the stop's lines out of order or missing"
  [ "$code" = 143 ] && [ "$secs" -lt 50 ] && pass "exit 143, ${secs}s of 60" || fail "exit $code after ${secs}s"
else
  fail "start.sh never started the stand-in: $(docker logs --tail 5 "$C2" 2>&1 | tr '\n' ' ')"
fi

echo
echo "passed: $PASSED   failed: $FAILED"
[ "$FAILED" -eq 0 ]
