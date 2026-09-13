#!/bin/bash
# Update this deployment to the latest release of the template.
#
# Moves between RELEASE TAGS, never to an arbitrary commit: a tag is a
# combination the repository's CI has booted and smoke-tested. Refuses to
# cross a major version unattended, refuses to run over local changes, and
# names any new required variable before anything has moved.
#
#   ./update.sh              update to the latest release
#   ./update.sh --dry-run    say what would happen
#   ./update.sh --allow-major   cross a major version, after reading its notes
set -euo pipefail
cd "$(dirname "$0")"

COMPOSE_FILE="docker-compose.yml"
PROJECT="${COMPOSE_PROJECT_NAME:-modernuo-docker}"
DRY_RUN=false
ALLOW_MAJOR=false
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --allow-major) ALLOW_MAJOR=true ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

# Local changes would be carried across the checkout or block it half way.
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "local changes present — commit or stash them first, nothing updated" >&2
  exit 1
fi

git fetch --tags --quiet origin

latest="$(git tag -l 'v*' --sort=-v:refname | head -1)"
if [ -z "$latest" ]; then
  echo "no release tags found — nothing to update to" >&2
  exit 1
fi

current="$(git describe --tags --abbrev=0 2>/dev/null || echo 'v0.0.0')"
if [ "$(git rev-parse HEAD)" = "$(git rev-parse "$latest^{commit}")" ]; then
  echo "already on $latest"
  exit 0
fi

# A major version is where contracts change. Its release notes are the
# decision; this script will not make it for you.
cur_major="${current#v}"; cur_major="${cur_major%%.*}"
new_major="${latest#v}";  new_major="${new_major%%.*}"
if [ "$new_major" != "$cur_major" ] && [ "$ALLOW_MAJOR" != "true" ]; then
  echo "refusing to cross a major version unattended: $current -> $latest" >&2
  echo "read the release notes, then re-run with --allow-major:" >&2
  echo "  https://github.com/heyvaldemar/modernuo-docker/releases/tag/$latest" >&2
  exit 3
fi

# NEW VARIABLES SINCE YOUR VERSION. An update can add a required variable,
# and `docker compose up` would then stop with a message naming it - after
# the checkout, with the tree already on the new tag. Better to say so here,
# before anything has moved. Names only, never values.
if [ -n "${COMPOSE_FILES+x}" ]; then _files=("${COMPOSE_FILES[@]}"); else _files=("${COMPOSE_FILE:-}"); fi
_new="$(comm -13 <(git show "HEAD:.env.example" 2>/dev/null | grep -oE '^[A-Z0-9_]+=' | tr -d '=' | sort -u) \
               <(git show "$latest:.env.example" 2>/dev/null | grep -oE '^[A-Z0-9_]+=' | tr -d '=' | sort -u))"
if [ -n "$_new" ]; then
  echo "new variables in .env.example since $current:"
  while IFS= read -r _k; do echo "  $_k"; done <<<"$_new"
  _required=""
  for _f in "${_files[@]}"; do
    _required="$_required $(git show "$latest:$_f" 2>/dev/null | grep -oE '\$\{[A-Z0-9_]+:\?' | sed -E 's/^\$\{//; s/:\?$//' | tr '\n' ' ')"
  done
  _missing=""
  for _k in $_new; do
    case " $_required " in *" $_k "*) grep -qE "^${_k}=." .env 2>/dev/null || _missing="$_missing $_k" ;; esac
  done
  if [ -n "$_missing" ]; then
    echo "required in $latest and not set in .env:$_missing" >&2
    echo "see .env.example at $latest for what each one is; nothing was changed" >&2
    [ "$DRY_RUN" = "true" ] || exit 4
  fi
fi

echo "updating $current -> $latest"
if [ "$DRY_RUN" = "true" ]; then
  git log --oneline "HEAD..$latest^{commit}" | sed 's/^/  would apply: /'
  echo "dry run — nothing changed"
  exit 0
fi

# A WORLD STRANDED INSIDE THE OLD CONTAINER IS COPIED OUT BEFORE ANYTHING IS
# RECREATED. Releases 1.3.1 and earlier mounted ./data at /app/Saves, which is
# the directory ModernUO 0.15.6.178 renames on every save. On that layout every
# save after the upgrade failed, the host directory was emptied by the first
# attempt, and the only complete copy of the world sits in /app/Saves.next in
# the running container's writable layer. `docker compose up` recreates the
# container and that layer is gone. So: if the running shard holds a staged
# save and the host holds no world at all, the staged one is copied out first.
rescue_staged_save() {
  local c staged
  c="$(docker compose -f "$COMPOSE_FILE" -p "$PROJECT" ps -q modernuo 2>/dev/null | head -n 1)"
  [ -n "$c" ] || return 0
  docker exec "$c" test -d /app/Saves.next 2>/dev/null || return 0
  if [ -f data/Saves/Items/Items.bin ] || [ -f data/Items/Items.bin ]; then
    echo "the running shard holds a staged save at /app/Saves.next, but the host already has a world; leaving both alone" >&2
    return 0
  fi
  staged="data/rescued-$(date +%Y%m%d-%H%M%S)"
  echo "RESCUING a world that exists only inside the running container: /app/Saves.next -> $staged" >&2
  docker cp "$c:/app/Saves.next" "$staged"
  mkdir -p data/Saves
  mv "$staged"/* data/Saves/ && rmdir "$staged"
  echo "rescued into data/Saves/; the init service will start the shard on it" >&2
}
rescue_staged_save

git checkout -q "$latest"
docker compose -f "$COMPOSE_FILE" -p "$PROJECT" up -d --build --remove-orphans
echo "now on $latest"
