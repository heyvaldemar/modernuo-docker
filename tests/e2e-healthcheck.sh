#!/bin/bash
# Can this health check actually go red?
#
# Two ways it could not, both of which have happened in the shape this
# container has:
#
#   1. LOOKING FOR THE WRONG NAME. ModernUO is a .NET application, so the only
#      `comm` in the container is `dotnet`. A check for `ModernUO` in
#      /proc/*/comm returns 1 every single time — including when the shard is
#      perfectly healthy — so a check written that way is red forever, or, if
#      it has a fallback, resting on it while its first branch never fires.
#
#   2. MATCHING ITSELF. `pgrep -f ModernUO` also sees the command line of the
#      shell running the check, so it is satisfied by its own text and returns
#      0 on a container where nothing of the sort is running. Green forever,
#      which is worse.
#
# The bracket splits the pattern so it cannot match its own text. That claim is
# measured here rather than asserted in a comment.
set -uo pipefail

IMAGE="${MODERNUO_BASE_IMAGE:-mcr.microsoft.com/dotnet/runtime:10.0}"
RUN="uohc-$$"
PASSED=0; FAILED=0
cleanup() { docker rm -f "$RUN" >/dev/null 2>&1; }
trap cleanup EXIT

pass() { echo "  PASS: $1"; PASSED=$((PASSED+1)); }
fail() { echo "  FAIL: $1"; FAILED=$((FAILED+1)); }

echo "=== the health check, against a container with no shard in it ==="
echo

# NOTHING is running here. Every check below should therefore be RED, and the
# ones that are not are the bugs this file exists to document.
if docker run --rm "$IMAGE" sh -c "pgrep -f ModernUO >/dev/null" 2>/dev/null; then
  pass "without the bracket the check is GREEN on an empty container - it matches itself"
else
  fail "pgrep -f ModernUO did not match its own command line, so the bracket buys nothing and the comment in the compose file is wrong"
fi

if docker run --rm "$IMAGE" sh -c "pgrep -f '[M]odernUO' >/dev/null" 2>/dev/null; then
  fail "the bracketed check was green with nothing running"
else
  pass "with the bracket it is red, as it must be"
fi

# And the name really is dotnet, which is why /proc/*/comm cannot be used.
comms="$(docker run --rm "$IMAGE" sh -c 'sleep 5 & cat /proc/[0-9]*/comm 2>/dev/null | sort -u | tr "\n" " "' 2>/dev/null)"
if printf '%s' "$comms" | grep -q 'ModernUO'; then
  fail "a comm named ModernUO exists after all, so the reasoning in the compose file needs revisiting"
else
  pass "no comm is named ModernUO (saw: ${comms:-nothing}) - a /proc/*/comm check could never match"
fi

# Now the positive case: with something whose command line contains the name,
# the bracketed check must go green. Otherwise it is red forever, which is the
# other way for a check to be useless.
docker rm -f "$RUN" >/dev/null 2>&1
# `exec -a` is a bash builtin and this image's sh is dash, so the name is put
# into the command line the way the real process has it: as an argument. A real
# shard runs `dotnet /app/ModernUO.dll`, and pgrep -f reads the whole line.
docker run -d --name "$RUN" "$IMAGE" sh -c 'sleep 3600' /app/ModernUO.dll >/dev/null 2>&1
up=false
for _ in $(seq 1 30); do
  if docker exec "$RUN" sh -c "pgrep -f '[M]odernUO' >/dev/null" 2>/dev/null; then up=true; break; fi
  sleep 0.5
done
if [ "$up" = true ]; then
  pass "with a ModernUO command line present the bracketed check goes green"
else
  fail "the bracketed check stayed red with the shard running, so it is red forever"
  docker exec "$RUN" sh -c 'cat /proc/[0-9]*/cmdline | tr "\0" " "' 2>/dev/null | head -c 200
fi

echo
echo "passed: $PASSED   failed: $FAILED"
[ "$FAILED" -eq 0 ]
