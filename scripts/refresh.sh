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
# STEAM'S SILENCE IS TOLERATED FOR A SPAN OF TIME, NOT A NUMBER OF RUNS. On
# the machine this template comes from, Steam stopped saying which build it
# ships for about five hours (SteamCMD timed out on every try) while nothing
# on the host was wrong. Its monitoring tolerated "three failures in a row",
# written for one caller every three hours; a second caller made three strikes
# land in 67 minutes, and it reported the host down. A count assumes a call
# rate, and the rate changes with whoever asks. So when LinuxGSM reports that
# it could not get Steam's build, this notes when Steam went quiet and exits 0
# until it has been quiet for HUMANITZ_REFRESH_STEAM_TOLERANCE seconds (three
# hours by default), however often it runs in between, and 1 after that. An
# installed build that cannot be read is a fault here, and exits 1 at once.
#
# WHAT LINUXGSM PRINTS WHEN STEAM IS QUIET. Neither build. It prints "Local
# build" and "Remote build" together, after it has asked Steam, and when Steam
# gives no build it stops at "[ FAIL ] ... Checking remote build" and exits 1
# (LinuxGSM v26.4.0 in the pinned image, run with SteamCMD answering nothing).
# Until v1.1.3 this waited for a local build without a remote one, which
# LinuxGSM never prints, and the stand-in in the tests printed exactly that:
# so the tolerance above was never reached, and a quiet Steam failed the run at
# once. Now the failure line is what says Steam is quiet, and the installed
# build comes from the app manifest, the file LinuxGSM reads it from.
#
# tests/e2e-decisions.sh proves the decisions against a stand-in server.
#   HUMANITZ_PROJECT   the compose project   (default humanitz)
#   HUMANITZ_REFRESH_STEAM_TOLERANCE    seconds of Steam silence before exit 1 (10800)
#   HUMANITZ_REFRESH_STEAM_SILENT_FILE  where that silence started (.humanitz-refresh-steam-silent)
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

# check-update <container>: LinuxGSM's own answer, colours removed, and the
# exec's own exit code (LinuxGSM's are 0 to 3, a timeout is 124).
check_update() {
  limit 300 docker exec -u linuxgsm -w /app "$1" ./hzserver check-update 2>&1 | sed 's/\x1b\[[0-9;]*[mK]//g' | tr '\r' '\n'
  return "${PIPESTATUS[0]}"
}
build_of() { grep -oE "$1 build: *[0-9]+" | grep -oE '[0-9]+$' | tail -1; }
# The installed build from the app manifest, as a number, or nothing.
APPID=2728330
manifest_build() {
  local out
  out=$(docker exec "$1" sh -c "grep -oE '\"buildid\"[[:space:]]+\"[0-9]+\"' /data/serverfiles/steamapps/appmanifest_$APPID.acf 2>/dev/null | grep -oE '[0-9]+' | head -1" 2>/dev/null) || return 0
  case "$out" in ''|*[!0-9]*) ;; *) echo "$out" ;; esac
}

# DOCKER CUTTING THE ANSWER OFF IS NOT STEAM GOING QUIET. An exec that ended
# with 125 or more is Docker failing, or the exec killed by a restart (137
# after part of the output, measured on Docker 29.7.2), and nothing it printed
# is counted: not as builds, and not as Steam's silence.
installed=""; latest=""; asked=0; quiet_steam=false
for attempt in 1 2; do
  out="$(check_update "$cid")"; asked=$?
  quiet_steam=false
  if [ "$asked" -lt 125 ]; then
    installed="$(build_of Local <<<"$out")"
    latest="$(build_of Remote <<<"$out")"
    [ -n "$installed" ] && [ -n "$latest" ] && break
    grep -qE '\[ FAIL \].*Checking remote build' <<<"$out" && quiet_steam=true
  else
    installed=""; latest=""
  fi
  [ "$attempt" = 1 ] && sleep "${HUMANITZ_REFRESH_RETRY_SECONDS:-20}"
done
if [ "$asked" -ge 125 ]; then
  say "could not ask LinuxGSM: docker exec ended with $asked, so Docker failed or the exec was cut off; that is not Steam going quiet. Nothing changed" >&2
  exit 1
fi
$quiet_steam && [ -z "$installed" ] && installed="$(manifest_build "$cid")"
SILENT_FILE=${HUMANITZ_REFRESH_STEAM_SILENT_FILE:-.humanitz-refresh-steam-silent}
TOLERANCE=${HUMANITZ_REFRESH_STEAM_TOLERANCE:-10800}
if $quiet_steam && [ -n "$installed" ]; then
  now_s=$(date +%s)
  if [ -L "$SILENT_FILE" ]; then
    say "$SILENT_FILE is a symlink; not following it, and not tolerating Steam's silence" >&2
    exit 1
  fi
  since=$(cat "$SILENT_FILE" 2>/dev/null)
  case "$since" in ''|*[!0-9]*) since="" ;; esac
  # A start in the future (a clock set back, a hand-edited file) would keep the
  # silence young forever, so it starts now instead. And a silence that cannot
  # be recorded cannot be timed: tolerating it would mean tolerating it forever.
  if [ -z "$since" ] || [ "$since" -gt "$now_s" ]; then
    since=$now_s
    if ! { echo "$since" > "$SILENT_FILE"; } 2>/dev/null; then
      say "cannot record when Steam went quiet in $SILENT_FILE; not tolerating it" >&2
      exit 1
    fi
  fi
  quiet=$((now_s - since))
  if [ "$quiet" -lt "$TOLERANCE" ]; then
    say "Steam did not say which build it ships (running build $installed); quiet for $((quiet / 60)) min, tolerated up to $((TOLERANCE / 60)) min; nothing changed"
    exit 0
  fi
  say "Steam has not said which build it ships for $((quiet / 60)) min, past the $((TOLERANCE / 60)) min tolerance (running build $installed); nothing changed" >&2
  exit 1
fi
if [ -z "$installed" ] || [ -z "$latest" ]; then
  say "could not read both builds from LinuxGSM: installed '${installed:-?}', Steam '${latest:-?}'; its last line: '$(grep -v '^[[:space:]]*$' <<<"$out" | tail -1)'; nothing changed" >&2
  exit 1
fi
rm -f "$SILENT_FILE"
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
