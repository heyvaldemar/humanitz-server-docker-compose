#!/bin/bash
# Keep the server on the build Steam ships, and only ever restart an empty one.
#
#   scripts/refresh.sh             update if behind and nobody is on
#   scripts/refresh.sh --check     say whether it is behind, change nothing
#   scripts/refresh.sh --dry-run   go as far as deciding, change nothing
#   scripts/refresh.sh --force     restart even with players on, or unknown
#
# WHY. After a HumanitZ patch every player's client updates itself, and a
# server still on the old build turns all of them away while its container
# reports healthy. LinuxGSM fetches the new build when the server starts
# (UPDATE_ON_START), so the fix is a restart; this decides when one is due and
# when one would hurt somebody. LinuxGSM's own hourly update is off in the
# compose file: it restarts whoever is on, because it counts players over the
# Steam query, and HumanitZ does not answer it.
#
# BOTH BUILD NUMBERS ARE LINUXGSM'S, READ, NEVER ASSUMED: `check-update` prints
# the installed ("Local build") and Steam's ("Remote build") for the native
# Linux branch. An update counts only when the local build afterwards is the
# remote one.
#
# WHO IS ON COMES FROM RCON, AND UNKNOWN IS NOT ZERO. "N connected." from RCON
# `info`, asked three times. A server that does not answer is "?" and is
# skipped like an occupied one, and this exits 1, because a probe that can
# never tell is a probe somebody should look at. On the machine this template
# comes from, an update roll that read "cannot count" as zero had three game
# stacks reading as empty whatever was happening on them.
#
# tests/e2e-decisions.sh proves the decisions against a stand-in server.
#   HUMANITZ_PROJECT   the compose project   (default humanitz)
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

MODE=""
FORCE=false
for arg in "$@"; do
  case "$arg" in
    --check) MODE=check ;;
    --dry-run) MODE=dry-run ;;
    --force) FORCE=true ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

PROJECT="${HUMANITZ_PROJECT:-humanitz}"
COMPOSE="humanitz-server-docker-compose.yml"
say() { echo "$(date '+%F %T') $*"; }
# timeout(1) is GNU coreutils: on a host without it (macOS) the command runs
# without a limit rather than not at all.
limit() { if command -v timeout >/dev/null 2>&1; then timeout "$@"; else shift; "$@"; fi; }

cid="$(docker compose -p "$PROJECT" ps -q --status running humanitz-server 2>/dev/null || true)"
[ -n "$cid" ] || { say "the server is not running; nothing to refresh"; exit 0; }

# check-update <container>: LinuxGSM's own answer, colours removed.
check_update() {
  limit 300 docker exec -u linuxgsm -w /app "$1" ./hzserver check-update 2>&1 | sed 's/\x1b\[[0-9;]*m//g'
}
build_of() { grep -oE "$1 build: *[0-9]+" | grep -oE '[0-9]+$' | tail -1; }

installed=""; latest=""
for attempt in 1 2; do
  out="$(check_update "$cid")"
  installed="$(build_of Local <<<"$out")"
  latest="$(build_of Remote <<<"$out")"
  [ -n "$installed" ] && [ -n "$latest" ] && break
  [ "$attempt" = 1 ] && sleep "${HUMANITZ_REFRESH_RETRY_SECONDS:-20}"
done
if [ -z "$installed" ] || [ -z "$latest" ]; then
  say "could not read both builds from LinuxGSM: installed '${installed:-?}', Steam '${latest:-?}'; nothing changed" >&2
  exit 1
fi
if [ "$installed" = "$latest" ]; then
  say "up to date: build $installed"
  exit 0
fi
if [ "$MODE" = check ]; then
  say "behind: running build $installed, Steam ships $latest"
  exit 0
fi

players="$(docker exec -i "$cid" python3 - --status < scripts/rcon.py 2>/dev/null | sed -nE 's/.*"players": ([0-9]+).*/\1/p')"
case "$players" in ''|*[!0-9]*) players="?" ;; esac
if [ "$players" = "?" ] && [ "$FORCE" != "true" ]; then
  say "behind ($installed -> $latest), and RCON did not answer three times, so nobody can say who is on; not restarting. --force restarts anyway" >&2
  exit 1
fi
if [ "$players" != "?" ] && [ "$players" -gt 0 ] && [ "$FORCE" != "true" ]; then
  say "behind ($installed -> $latest), but $players player(s) are on; trying again next run"
  exit 0
fi
if [ "$MODE" = dry-run ]; then
  say "would restart to update ($installed -> $latest): players online: $players$([ "$FORCE" = "true" ] && echo ', forced')"
  exit 0
fi

# The backup asks the server to save first (RCON `save`).
scripts/backup.sh >/dev/null 2>&1 || say "the backup did not complete; updating anyway" >&2
say "behind ($installed -> $latest), players online: $players; restarting so LinuxGSM fetches it"
docker compose -f "$COMPOSE" -p "$PROJECT" restart humanitz-server >/dev/null
# LinuxGSM updates before the server starts; give it the time a patch takes.
now=""
for _ in $(seq 1 60); do
  sleep 10
  cid="$(docker compose -p "$PROJECT" ps -q --status running humanitz-server 2>/dev/null || true)"
  [ -n "$cid" ] || continue
  now="$(check_update "$cid" | build_of Local)"
  [ "$now" = "$latest" ] && break
done
if [ "$now" = "$latest" ]; then
  say "updated: build $installed -> $now"
  exit 0
fi
say "FAILED: still on build ${now:-unknown} ten minutes after the restart; players on the new client cannot join until it updates. docker compose -p $PROJECT logs --tail 200 humanitz-server" >&2
exit 1
