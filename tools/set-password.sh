#!/bin/bash
# set-password.sh <account> — set a ModernUO account password from the host.
#
# WHY THIS EXISTS. ModernUO offers two ways to change a password and both can be
# unavailable at once:
#
#   [Password  is gated on accessList[0] — the FIRST address ever recorded on the
#              account — compared by class C. A residential connection changes
#              address eventually, and from that moment every older account is
#              permanently locked out of the command. The fallback path does not
#              change the password at all: it files a support ticket, with the
#              desired password written into the ticket body in clear text.
#
#   [admin     requires an account you can already log into that holds admin
#              rights, which is no help when that is the account you are locked
#              out of.
#
# HOW IT IS SAFE. The stored value is an Argon2 string whose length is fixed by
# its parameters — 95 characters for m=8192,t=3,p=1 with a 16-byte salt. A new
# hash with the same parameters is exactly as long, so this is a byte-for-byte
# replacement inside Accounts.bin: no field moves, no length prefix changes,
# nothing else in the file is touched. If the lengths ever differ the script
# stops rather than shifting the remainder of the file.
#
# THE SERVER MUST BE STOPPED. ModernUO holds accounts in memory and writes them
# out on every autosave, so an edit under a running server is overwritten within
# the minute.
#
# The new password is written to a mode-600 file and never printed: passwords
# echoed to a terminal end up in scrollback, in shell history, and in screenshots.
set -euo pipefail
cd "$(dirname "$0")/.."

ACCT=${1:?usage: tools/set-password.sh <account>}
SERVICE=${MODERNUO_SERVICE:-uo}
DATA=${MODERNUO_DATA:-data}
FILE="$DATA/Accounts/Accounts.bin"
OUT="secrets/uo-$ACCT-password"
STAMP=$(date +%Y%m%d-%H%M%S)

test -f "$FILE" || { echo "no $FILE — is MODERNUO_DATA set correctly?"; exit 1; }

echo "== stopping $SERVICE"
docker compose stop "$SERVICE" >/dev/null

# The accounts directory is written by the server as root, so even the backup
# goes through a container rather than assuming the invoking user can write there.
docker run --rm -v "$PWD/$DATA:/d" alpine:3 \
  cp /d/Accounts/Accounts.bin "/d/Accounts/Accounts.bin.bak-$STAMP"
echo "   backup: $FILE.bak-$STAMP"

mkdir -p secrets
# NOT `tr -dc ... </dev/urandom | head -c 12`: head closes the pipe, tr dies of
# SIGPIPE, and with `set -o pipefail` the pipeline returns 141, which `set -e`
# turns into a silent exit — leaving the server stopped and nothing changed.
NEW=$(head -c 64 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-16)

docker run --rm -v "$PWD/$DATA:/d" -v "$PWD/tools/sethash.py:/sethash.py:ro" \
  -e ACCT="$ACCT" -e NEW="$NEW" python:3-slim \
  sh -c 'pip install -q argon2-cffi >/dev/null 2>&1 && python3 /sethash.py'

install -m 600 /dev/null "$OUT"
printf '%s\n' "$NEW" > "$OUT"
echo "   new password written to $OUT (mode 600, not printed)"

echo "== starting $SERVICE"
docker compose up -d "$SERVICE" >/dev/null
for _ in $(seq 1 20); do
  [ "$(docker compose ps -q "$SERVICE" | xargs -r docker inspect -f '{{.State.Health.Status}}' 2>/dev/null)" = healthy ] && break
  sleep 5
done

# VERIFY BY LOGGING IN. A wrong hash and a right one look identical in the file,
# so the only honest check is to speak the login protocol and see what the server
# says. 0xA8 is the server list — the reply to a successful account login.
echo "== verifying with a real login"
docker compose exec -T "$SERVICE" true 2>/dev/null || true
docker run --rm --network "container:$(docker compose ps -q "$SERVICE")" \
  -e ACCT="$ACCT" -e NEW="$NEW" python:3-alpine python3 -c '
import os, socket, struct, time
a=os.environ["ACCT"].encode(); p=os.environ["NEW"].encode()
s=socket.create_connection(("127.0.0.1",2593),timeout=8)
s.sendall(struct.pack(">I",0x7F000001))
s.sendall(b"\x80"+a.ljust(30,b"\0")+p.ljust(30,b"\0")+b"\x5d")
time.sleep(0.6); r=s.recv(256); s.close()
print("   ACCEPTED" if r and r[0]==0xA8 else "   REFUSED (0x%02X)" % (r[0] if r else 0))'
