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
