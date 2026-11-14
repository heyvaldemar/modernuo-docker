#!/bin/bash
# Can the process half of this health check actually go red, and green?
#
# Three ways it could not, all of them in the shape this container has:
#
#   1. LOOKING FOR THE WRONG NAME. ModernUO is a .NET application, so the
#      server's `comm` is `dotnet`. A check for `ModernUO` in /proc/*/comm
#      returns 1 every single time, including when the shard is perfectly
#      healthy, so a check written that way is red forever.
#
#   2. MATCHING ITSELF. `pgrep -f ModernUO` also sees the command line of the
#      shell running the check, so it is satisfied by its own text and returns
#      0 on a container where nothing of the sort is running. Green forever,
#      which is worse.
#
#   3. MATCHING THE WRAPPER. tools/start.sh runs the server under script(1),
#      whose command line carries the server's: `pgrep -f '[M]odernUO'` is
#      green on script alone, with no server under it.
#
# So the check asks for the comm, `pgrep -x dotnet`. Each claim is measured
# here rather than asserted in a comment.
# shellcheck disable=SC2015   # pass and fail always exit 0, so "A && pass || fail" is if-then-else here
set -uo pipefail

IMAGE="${MODERNUO_BASE_IMAGE:-mcr.microsoft.com/dotnet/runtime:11.0}"
RUN="uohc-$$"
PASSED=0; FAILED=0
cleanup() { docker rm -f "$RUN" >/dev/null 2>&1; }
trap cleanup EXIT

pass() { echo "  PASS: $1"; PASSED=$((PASSED+1)); }
fail() { echo "  FAIL: $1"; FAILED=$((FAILED+1)); }

echo "=== the health check, against a container with no shard in it ==="
echo

# NOTHING is running here. Every check below should therefore be RED, and the
# ones that are not are the traps this file exists to document.
if docker run --rm "$IMAGE" sh -c "pgrep -f ModernUO >/dev/null" 2>/dev/null; then
  pass "pgrep -f ModernUO is GREEN on an empty container: it matches itself"
else
  fail "pgrep -f ModernUO did not match its own command line, so trap 2 is not real and the header is wrong"
fi

if docker run --rm "$IMAGE" sh -c "pgrep -x dotnet >/dev/null" 2>/dev/null; then
  fail "pgrep -x dotnet was green with nothing running"
else
  pass "pgrep -x dotnet is red, as it must be"
fi

comms="$(docker run --rm "$IMAGE" sh -c 'sleep 5 & cat /proc/[0-9]*/comm 2>/dev/null | sort -u | tr "\n" " "' 2>/dev/null)"
if printf '%s' "$comms" | grep -q 'ModernUO'; then
  fail "a comm named ModernUO exists after all, so trap 1 needs revisiting"
else
  pass "no comm is named ModernUO (saw: ${comms:-nothing}): a /proc/*/comm check for it could never match"
fi

echo
echo "=== the wrapper, with no server under it ==="
echo
# The command line script(1) has under tools/start.sh, with the server gone:
# a shell script named script stands in for it, with the same arguments. (A copy
# of sleep cannot take another name here: the image's coreutils is one program
# that picks what to be by the name it was started under.)
standin() {  # name, arguments: a process with that comm and that command line
  docker rm -f "$RUN" >/dev/null 2>&1
  docker run -d --name "$RUN" "$IMAGE" sh -c 'n=$1; shift; printf "#!/bin/sh\nwhile :; do sleep 1; done\n" >"/tmp/$n" && chmod +x "/tmp/$n" && exec "/tmp/$n" "$@"' sh "$@" >/dev/null 2>&1
}
standin script -qfec "exec dotnet ModernUO.dll" /dev/null
seen=false
for _ in $(seq 1 30); do
  docker exec "$RUN" sh -c 'pgrep -x script >/dev/null' 2>/dev/null && { seen=true; break; }
  sleep 0.5
done
if [ "$seen" != true ]; then
  fail "the stand-in for script(1) never started"
else
  docker exec "$RUN" sh -c "pgrep -f '[M]odernUO' >/dev/null" 2>/dev/null \
    && pass "pgrep -f '[M]odernUO' is GREEN on the wrapper alone: trap 3" \
    || fail "pgrep -f '[M]odernUO' did not match the wrapper's command line, so trap 3 is not real and the header is wrong"
  docker exec "$RUN" sh -c 'pgrep -x dotnet >/dev/null' 2>/dev/null \
    && fail "pgrep -x dotnet was green on the wrapper alone" \
    || pass "pgrep -x dotnet is red on the wrapper alone"
fi

echo
echo "=== the server ==="
echo
# Now the positive case: a process whose comm is dotnet, the way the runtime's
# own dotnet has it, must make the check green. Otherwise it is red forever,
# which is the other way for a check to be useless.
standin dotnet ModernUO.dll
up=false
for _ in $(seq 1 30); do
  if docker exec "$RUN" sh -c 'pgrep -x dotnet >/dev/null' 2>/dev/null; then up=true; break; fi
  sleep 0.5
done
if [ "$up" = true ]; then
  pass "with a process named dotnet the check goes green"
else
  fail "the check stayed red with a dotnet process running, so it is red forever"
fi
# That the real server's comm is dotnet is measured on a live shard: tools/start.sh
# finds the server by that name to hand it SIGTERM, and a stop there took 1.2 s
# and exited 143; had the name been wrong, nothing would have reached the
# server and Docker would have killed it at 60 s.

echo
echo "passed: $PASSED   failed: $FAILED"
[ "$FAILED" -eq 0 ]
