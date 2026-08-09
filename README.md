# modernuo-docker

Multi-stage Docker build for [ModernUO](https://github.com/modernuo/ModernUO) — the Ultima Online shard emulator on .NET 10. Compose stack, upstream release watcher, and no game data baked into the image.

---

## Why this exists

ModernUO ships no official Docker image, and its GitHub releases contain no prebuilt binaries — they are source tags. Running it in a container therefore means building it yourself, and the build has a few sharp edges that cost an evening to find and one line each to fix. They are documented below so they cost you neither.

The result is a small runtime image: the published server, the .NET runtime, and two native libraries. Everything specific to your shard — world saves, accounts, configuration, and the Ultima Online client files — is mounted at runtime and stays yours.

## Quick start

```bash
git clone https://github.com/heyvaldemar/modernuo-docker.git
cd modernuo-docker
cp .env.example .env          # pin a release tag
mkdir -p data config uodata
```

Copy your Ultima Online client files into `uodata/` — see [Game data](#game-data) — then:

```bash
docker compose up -d --build
```

The shard listens on TCP 2593. First start creates the world; subsequent starts load it from `data/`.

To upgrade, change `MODERNUO_REF` in `.env` and rebuild:

```bash
docker compose up -d --build
```

## What is in the image, and what is not

**In:** the ModernUO server published for `linux-x64`, the .NET 10 runtime, and `libdeflate` and `libargon2` from Debian.

**Not in:** any Ultima Online game data. `/uodata` is a volume. This is deliberate and is explained under [Legal](#legal).

The build clones ModernUO rather than copying a tarball, because its build tool stamps the commit it was built from and needs git history to do so. Pin `MODERNUO_REF` to a release tag if you want two builds of the same Dockerfile to produce the same server; `main` tracks the tip and will not.

---

## Errors this build already solves

If you arrived here from a search engine with one of these, the fix is in the Dockerfile.

### `Could not load libdeflate` — server dies at `Core.Setup`

ModernUO P/Invokes `libdeflate` for save compression. Debian packages it as `libdeflate.so.0` — **versioned only** — while .NET's `DllImport` resolves the **unversioned** `libdeflate.so`. The library is installed, the loader still cannot find it, and the server exits during startup before it prints anything useful.

```dockerfile
RUN ln -sf /usr/lib/x86_64-linux-gnu/libdeflate.so.0 /usr/lib/x86_64-linux-gnu/libdeflate.so
```

### `Could not load libargon2` — same failure, same cause

Argon2 is used for password hashing and has exactly the same versioned/unversioned mismatch.

```dockerfile
RUN ln -sf /usr/lib/x86_64-linux-gnu/libargon2.so.1 /usr/lib/x86_64-linux-gnu/libargon2.so
```

Both symlinks are already in the Dockerfile. Neither is needed on distributions that ship an unversioned development symlink, which is why this bites on slim runtime images specifically and not on a developer machine.

---

## Populating a fresh world

**A new world is empty, and that is not a bug.** ModernUO creates the world but does not decorate or populate it. On a first boot the server reports:

```
Loading world done (46 items, 2 mobiles)
```

A generated world is closer to 170,000 items and 29,000 mobiles. Until you generate it there are no vendors, no signs, no doors, no dungeon spawns — only bare terrain, which looks convincingly like a working shard right up until you walk into Britain and find nobody there.

Generation is a one-time manual step, run in game, and the data for it already ships in `Data/`.

### Every command needs a staff character — and staff status is decided at character creation

This is the part that costs an evening. Raising an account's access level does **not** promote a character that already exists. From `CharacterCreation.cs`:

```csharp
newChar.AccessLevel = args.Account.AccessLevel;
```

The level is copied once, when the character is made. A character created before the account was promoted stays a `Player` forever, the command system does not even recognise its input as a command, and nothing is written to `Logs/Commands/` — so it looks exactly like the commands are broken.

**Create a new character after the account is an Owner.** A staff character starts outside the normal towns, which is a quick way to confirm the level took effect.

### The commands

All of these require `AccessLevel.Developer` or higher. The command prefix is `[` by default.

```
[Decorate       world decoration: furniture, lighting, signs' backing, town dressing
[SignGen        world and shop signs on all facets
[MoonGen        public moongates (removes old ones first)
[TelGen         world and dungeon teleporters
[SHTelGen       solen hive teleporters
[DoorGen        doors, by analysing the map — the slow one
[ImportSpawners <pattern>   creatures and vendors
[Save
```

Optional, depending on what you want present: `[GenChamps`, `[GenKhaldun`, `[GenStealArties`, `[SecretLocGen`.

**Command names do not always match the method names** you may find by searching the assembly. The registered names are what matters: it is `TelGen`, not `GenTeleporter`; `GenChamps`, not `ChampGen`; `GenLeverPuzzle`, not `GenLampPuzzle`.

`[Decorate` is safe to re-run. It calls `FindItem` for each piece and skips anything already standing there, so running it again after enabling a new facet adds only the new content.

### `ImportSpawners` needs an argument, and globs are fragile

`[ImportSpawners` (aliases `GenerateSpawners`, `GenSpawners`) takes a search pattern relative to the server's base directory. With no argument it prints usage and does nothing:

```
[GenerateSpawners Data/Spawns/shared/**/*.json
```

The spawn sets are split by era. `shared/` holds the bulk — dungeons, town life, vendors, wildlife — and applies to any era. `uoml/` and `post-uoml/` are **alternative** versions of the same handful of files for later eras, not additions to `shared/`; importing them on top duplicates spawn points or imports content from an era your shard does not have.

Typing a pattern into a game client is more error-prone than it looks. `shared/**/*.json` arriving at the server as `shared/*/.json` matches nothing, and the only symptom is a quiet "No files found matching the pattern". If a glob refuses to work, merge the files and pass a plain path — the spawn files are JSON arrays of objects with unique `guid`s, so concatenating them is safe:

```bash
python3 - <<'EOF'
import json, glob
FACETS = ("felucca", "trammel", "ilshenar")   # only what your expansion enables
out, seen = [], set()
for facet in FACETS:
    for f in sorted(glob.glob(f"Data/Spawns/shared/{facet}/*.json")):
        for s in json.load(open(f)):
            if s["guid"] not in seen:
                seen.add(s["guid"]); out.append(s)
json.dump(out, open("Data/Spawns/all.json", "w"), indent=1)
print(len(out), "spawners")
EOF
```

Then `[GenerateSpawners Data/Spawns/all.json`, with no special characters to lose.

Name only the facets your expansion actually has. `shared/` also carries `malas/` and `tokuno/`, and importing those into a shard where the map is not enabled just produces failures the importer has to report.

### Checking that it worked

Walking around proves one screen at a time. `tools/world-stats.sh` reads the save index and answers in a second:

```
$ tools/world-stats.sh
  items     168966   (788 distinct types)
  mobiles    29025   (367 distinct types)

  spawner types present: Spawner, RegionSpawner
  townsfolk/vendor types: 27 — Alchemist, Baker, Banker, Barkeeper, Butcher...

  VERDICT: decorated and inhabited.
```

It distinguishes the two states that are easy to confuse: a world can be fully decorated and still have nobody living in it. Counts update when the server saves, so run `[Save` first if you have just generated something.

### What not to run

Generators exist for content your expansion may not include. Check `Configuration/expansion.json` first — on a pre-AoS shard, `[GenGauntlet` and `[GenLeverPuzzle` (Doom) and `[DecorateMag` (ruined Magincia) belong to later eras. `[Decorate` itself is expansion-aware and simply skips facets that are not enabled.

## Operating it

Four things that are not obvious until they cost you something.

### The world is not saved on shutdown

Stopping the container does **not** save. Measured on a running shard: 639 completed saves before `docker compose stop`, 639 after. Everything that changed since the last autosave is discarded — accounts, characters, items, the lot.

This is easy to miss because the failure is silent and delayed. A password changed in game, a character created, an item moved: restart within the autosave window and it never happened, with nothing in any log to say so.

The autosave interval is the only thing standing between a restart and lost work:

```json
"autosave.saveDelay": "00:01:00"
```

The shipped default is five minutes. On a small world a save takes 0.02–0.07 seconds, so shortening it costs nothing measurable and shrinks the window fivefold. Check that it is actually running before trusting it:

```bash
docker logs uo --since 5m 2>&1 | grep -ac 'Saving world done'
```

There is a console command to force a save, but it needs an interactive TTY — see below for why giving the container one is a bad trade.

### Do not give the container a TTY

`tty: true` makes ModernUO colourise its output, and the escape codes land **between the fields of every log line**:

```
Login: <esc>[36m1.2.3.4<esc>[37m Invalid password for 'someone'
```

Anything that reads those logs — a fail2ban filter, an alerting script, a grep in a cron job — expects a plain space there and silently matches nothing. A monitor that quietly stops matching is worse than no monitor: it reports healthy while seeing nothing.

The only thing a TTY buys is the interactive console, whose useful command is `save`. Shortening the autosave interval achieves the same end without breaking every log consumer.

### `[Password` refuses for anyone whose address has changed

The in-game password command is gated on the account's **first ever** recorded address, from `AccountHandler.cs`:

```csharp
if (accessList[0].MatchClassC(ipAddress))
{
    acct.SetPassword(pass);
}
else
{
    // files a support page instead
}
```

A residential connection gets a new address every so often. Once it does, every account older than that change is permanently unable to use the command — the check compares against the *first* address, not the most recent one.

Worse, look at what the fallback writes:

```csharp
$"[Automated: Change Password]<br>Desired password: {pass}<br>..."
```

The desired password goes into the support ticket **in clear text**, readable by anyone who opens the queue with `[Pages`.

`tools/set-password.sh` exists for this. It replaces the stored Argon2 string directly, with the server stopped, and verifies the result by performing a real login rather than assuming the edit worked. The hash length is fixed by its parameters — 95 characters for `m=8192,t=3,p=1` with a 16-byte salt — so the replacement is byte-for-byte and nothing in the file moves.

```bash
tools/set-password.sh myaccount
```

The new password is written to a mode-600 file, never printed.

### Two people in one household cannot both play

```json
"accountHandler.maxAccountsPerIP": "1"
```

That is the default, and it counts addresses, not people. Two players behind one router see the second registration refused. Raise it to whatever your household or friend group needs.

## Keeping up with releases

`uowatch/` is a small watcher that polls the ModernUO release feed and reports when upstream is ahead of what you built.

It compares upstream against `PINNED_VERSION` rather than announcing every release, so it tells you that you are **behind** instead of merely that something happened — a distinction that matters once you have ignored one notification. It posts a Slack-shaped JSON payload, which Mattermost, Slack and Discord all accept.

```bash
cd uowatch
cp .env.example .env          # webhook, and the version you built
docker compose up -d
```

A locally built image has no registry to watch, so tools like Diun and Watchtower cannot see it. This is the substitute: it follows the upstream *source* release rather than an image digest, which for a build-from-source project is the more accurate signal anyway.

## Game data

ModernUO needs the art, map and tile files from an Ultima Online installation. Get them from a legitimate copy of the game — the [Ultima Online Classic Client](https://uo.com/client-download/) is a free download from Broadsword, and ModernUO documents which files it expects.

Copy them into `uodata/`. The compose file mounts that directory read-only, so the server can never modify your client files.

## Legal

**ModernUO is licensed GPL-3.0.** This repository contains build tooling — a Dockerfile, a compose stack, and a watcher script — not ModernUO's source, which is fetched from upstream at build time. If you distribute an image built from this Dockerfile, you are distributing GPL-3.0 software and take on its obligations, including making the corresponding source available. Building for your own use carries no such obligation.

**Ultima Online's client files are copyright Electronic Arts** and are not redistributable. They are not in this repository, not in the image, and never will be; the Dockerfile declares `/uodata` as a volume precisely so there is no way to bake them in by accident. Supply them yourself from your own installation.

## Licence

The contents of this repository are MIT-licensed. ModernUO itself remains GPL-3.0 and is not covered by that grant.
