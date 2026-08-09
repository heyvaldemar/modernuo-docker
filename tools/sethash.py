# Replace one account's Argon2 hash inside ModernUO's Accounts.bin, in place.
# Kept as its own file rather than a heredoc inside `docker run sh -c '...'`:
# that form needs the terminator to be the last line of a single-quoted string,
# and when it is not the shell swallows the whole block and the script exits
# silently having done nothing.
import os, re, sys
from argon2 import PasswordHasher, Type

acct = os.environ["ACCT"].encode()
new = os.environ["NEW"]
p = "/d/Accounts/Accounts.bin"
d = open(p, "rb").read()

i = d.find(bytes([len(acct)]) + acct)
if i < 0:
    print("FAILED: account not found"); sys.exit(1)
m = re.search(rb"\$argon2[!-~]+", d[i:])
if not m:
    print("FAILED: no hash after that account"); sys.exit(1)
old = m.group(0)

ph = PasswordHasher(time_cost=3, memory_cost=8192, parallelism=1,
                    hash_len=32, salt_len=16, type=Type.I)
fresh = ph.hash(new).encode()

# Length equality IS the safety argument: same parameters, same salt size, same
# string length, so this cannot shift anything after the record.
if len(fresh) != len(old):
    print("FAILED: %d vs %d bytes — refusing" % (len(fresh), len(old))); sys.exit(1)

start = i + m.start()
open(p, "wb").write(d[:start] + fresh + d[start + len(old):])
print("   replaced hash for %s (%d bytes, length unchanged)" % (acct.decode(), len(fresh)))
