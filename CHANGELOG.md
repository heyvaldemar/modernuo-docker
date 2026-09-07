# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

_(no unreleased changes yet)_

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

[Unreleased]: https://github.com/heyvaldemar/modernuo-docker/compare/v1.3.0...HEAD
[1.3.0]: https://github.com/heyvaldemar/modernuo-docker/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/heyvaldemar/modernuo-docker/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/heyvaldemar/modernuo-docker/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/heyvaldemar/modernuo-docker/releases/tag/v1.0.0
