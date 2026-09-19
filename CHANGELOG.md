# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Security

- **`alpine:3.22` was rebuilt upstream**; the pin moved from `sha256:365499d9dccb…` to `sha256:5291449c3df7…`. Same version, same tag, a rebuilt base image — the usual shape of a security fix in a base layer.

## [1.3.3] - 2026-09-18

### Security

- **`alpine:3.22` was rebuilt upstream**; the pin moved from `sha256:14358309a308…` to `sha256:365499d9dccb…`. Same version, same tag, a rebuilt base image — the usual shape of a security fix in a base layer.

## [1.3.2] - 2026-09-13

### Fixed

- **On 1.3.1, every world save failed.** ModernUO 0.15.6.178 publishes a save
  by renaming: it writes `Saves.next`, sets `Saves` aside, then renames the
  staged directory into place. This template mounted `./data` at `/app/Saves`,
  and a mount point cannot be renamed. Measured on a live shard forty seconds
  after the upgrade: the set-aside fell back to moving the contents out file by
  file, which emptied the host directory, and the rename into place failed
  because the mount point still existed. Every save failed from then on, once
  a minute, with the only complete copy of the world inside the container's
  writable layer, which the next recreate discards. The container stayed
  healthy, the port stayed open, the player count stayed normal.

  The mount is now the parent, `./data:/app/World`, and `world.savePath` is
  `World/Saves`. A new `init` service runs before the shard on every start: it
  moves a world found at the root of `./data` into `Saves/`, rewrites
  `world.savePath` in `config/modernuo.json`, writes a minimal configuration on
  a fresh deployment, refuses if both layouts hold a world, and changes nothing
  on a second run. `update.sh` copies a save stranded in the running container
  out to `data/Saves/` before recreating anything.

  The mechanism is proven in CI without a shard: a mount point cannot be
  renamed and a directory inside one can. So are the init step on every
  layout it may meet, the health check against fake state, and the index
  reader below. Nineteen assertions, negative cases included.

- **The health check could not see a shard that had stopped saving.** It
  checked for the process, and a server that cannot write its world down looks
  exactly like one that can. `tools/healthcheck.sh` now also requires the save
  on disk to be newer than `MODERNUO_SAVE_MAX_AGE` minutes, twenty by default,
  which is four missed saves at the shipped interval. The same file is what the
  test suite runs, so what CI proves is what production checks.

- **`tools/world-stats.sh` misread the save index and hardcoded its path.** The
  index gained an 8-byte field at version 5; reading the type count at the old
  offset produced 148836781 items and no types for a world of 174 thousand.
  Unknown versions are refused rather than guessed, and the path comes from
  `world.savePath` in the configuration, the same place the server reads it.

- The freshness check compared `MODERNUO_REF` with `!=` and would have called
  a newer pin behind. It orders the two versions now, as the rest of the fleet
  does. The init image's digest is re-resolved daily and scanned with Trivy
  like every other pinned image.

## [1.3.1] - 2026-09-13

### Changed

- **`MODERNUO_REF` moves from `0.15.6.145` to `0.15.6.178`.** The freshness
  check reported the lag daily and triage could not apply it: this repository
  pins a git ref and builds from source rather than pulling a published image,
  so there is no digest to swap and nothing for the automatic path to rewrite.

  The proof that the new ref is good is the same proof as for any other release
  here, the build and boot in CI, and it ran before this went out.

## [1.3.0] - 2026-09-07

### Added

- **`update.sh`: move between release tags on purpose.** It updates to the latest release (a combination this repository's CI has booted and smoke-tested), refuses to cross a major version unattended, refuses to run over local changes, and names any new required variable before anything has moved. `--dry-run` says what would happen.
- **A Trivy scan of the image this repository builds.** There is no upstream
  image to pin a digest to — the shard is compiled here — so the scan builds
  what the repository actually ships and looks at that, rather than at somebody
  else's work.

ner, bracketed
  it is red. `[M]odernUO` is the same pattern and does not match itself.
- **And the obvious alternative could never go green.** ModernUO is a .NET
  application, so the only `comm` in the container is `dotnet`: a check for
  `ModernUO` in `/proc/*/comm` returns 1 every time, including on a perfectly
  healthy shard.

### Added

- **A pinned default revision.** `MODERNUO_REF` defaulted to `main`, immediately
  under a comment warning that `main` quietly changes what you get between two
  builds of the same file. It now defaults to the 0.15.6.145 release, and the
  image tag follows it, so a running container says which shard code it is.
- **Resource limits.** The number matters more here than in most places: .NET's
  garbage collector expands to fill whatever it is offered, so the ceiling is
  what tells it when to stop. A shard measured over months peaked at 8.7 GB with
  4.4 GB resident under a 12 GB limit; 4 GB is the shipped starting point.
- **A stop grace period, and a warning next to it.** ModernUO does not save on
  shutdown — measured, 639 saves before a stop and 639 after — so a restart
  discards everything newer than the last autosave. The grace period does not
  fix that; only a short autosave interval does. It is there so an in-flight
  save is not cut in half.
- **`tty: false`, deliberately.** A TTY switches ModernUO to coloured output and
  the escape codes land between the fields of every log line, so anything
  reading those logs — a fail2ban filter, a login-attempt watcher, a grep —
  silently matches nothing.
- **Four end-to-end assertions** proving the health check both can and cannot
  fire, run in CI.

## [1.1.0] - 2026-09-02

### Added

- A verified build-and-boot pipeline in CI.

## [1.0.0] - 2026-09-02

### Added

- ModernUO built from a pinned upstream revision, with world saves, accounts and
  configuration on host paths, and UO client data supplied by the operator
  because those files belong to Electronic Arts.

[Unreleased]: https://github.com/heyvaldemar/modernuo-docker/compare/v1.3.3...HEAD
[1.3.3]: https://github.com/heyvaldemar/modernuo-docker/compare/v1.3.2...v1.3.3
[1.3.2]: https://github.com/heyvaldemar/modernuo-docker/releases/tag/v1.3.2
[1.3.1]: https://github.com/heyvaldemar/modernuo-docker/releases/tag/v1.3.1
[1.3.0]: https://github.com/heyvaldemar/modernuo-docker/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/heyvaldemar/modernuo-docker/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/heyvaldemar/modernuo-docker/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/heyvaldemar/modernuo-docker/releases/tag/v1.0.0
