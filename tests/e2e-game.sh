#!/bin/bash
# The real game, through the compose file, on this machine: does everything the
# README says hold against HumanitZ itself?
#
#   tests/e2e-game.sh        needs .env, a free volume name, and about 2 GB
#
# The game is small enough to install on every run (78 seconds and 1.4 GB on
# a CI runner), so this is not a stand-in: the settings written from .env, the
# status over RCON, the silence of the Steam query, RCON published nowhere,
# LinuxGSM's hourly update absent, a ban through RCON, a backup flushed by RCON
# and restored file by file, and the health check going red when the game
# dies inside a container that keeps running.
#
# It creates and removes its own volume and compose project, so it never
# touches a server already running here.
# shellcheck disable=SC2016  # single-quoted $BASE and $WORLD expand inside the helper container, on purpose
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

PASSED=0; FAILED=0
pass() { echo "  PASS: $1"; PASSED=$((PASSED+1)); }
fail() { echo "  FAIL: $1"; FAILED=$((FAILED+1)); }

[ -f .env ] || { echo "no .env: copy .env.example and set the two passwords"; exit 1; }
export HUMANITZ_PROJECT="humanitz-game-$$"
export HUMANITZ_VOLUME="humanitz-server-data"
WORK="$(mktemp -d)"
export HUMANITZ_BACKUP_DIR="$WORK/backups"
COMPOSE="humanitz-server-docker-compose.yml"
BASE=/data/serverfiles/HumanitZServer
# The world file this template's settings produce: Save_DedicatedSave.sav,
# measured on a CI runner. Other settings can name it differently, which is
# why scripts/backup.sh and scripts/restore.sh match any Save_*.sav.
WORLD="$BASE/Saved/SaveGames/SaveList/Default/DedicatedSave/Save_DedicatedSave.sav"
BANNED=76561190000000009

if docker volume inspect "$HUMANITZ_VOLUME" >/dev/null 2>&1; then
  echo "a volume called $HUMANITZ_VOLUME already exists here; this test creates and removes its own, so it will not run next to it"
  exit 1
fi
compose() { docker compose -f "$COMPOSE" -p "$HUMANITZ_PROJECT" "$@"; }
cleanup() {
  # The server's own words before it is removed, when anything failed.
  if [ "$FAILED" -gt 0 ]; then echo; echo "--- the server's log"; compose logs --tail 120 humanitz-server 2>&1; fi
  compose down -t 30 >/dev/null 2>&1
  docker volume rm -f "$HUMANITZ_VOLUME" >/dev/null 2>&1
  docker run --rm -v "$WORK":/w alpine:3.20 sh -c 'rm -rf /w/* /w/.[!.]*' >/dev/null 2>&1
  rm -rf "$WORK"
}
trap cleanup EXIT
vol() { docker run --rm -v "$HUMANITZ_VOLUME":/data -e BASE="$BASE" -e WORLD="$WORLD" alpine:3.20 sh -c "$1"; }
env_value() { grep -E "^$1=" .env | head -1 | cut -d= -f2-; }
healthy() {
  for _ in $(seq 1 "$1"); do
    [ "$(docker inspect -f '{{.State.Health.Status}}' "$(compose ps -q humanitz-server)" 2>/dev/null)" = healthy ] && return 0
    sleep 10
  done
  return 1
}
rcon_ready() {
  for _ in $(seq 1 30); do scripts/rcon.sh info >/dev/null 2>&1 && return 0; sleep 5; done
  return 1
}

echo "=== the real server, from an empty volume ==="
echo
docker volume create "$HUMANITZ_VOLUME" >/dev/null
start=$(date +%s)
compose up -d >/dev/null 2>&1
if healthy 90 && rcon_ready; then
  pass "installed, started and answering RCON in $(( $(date +%s) - start ))s"
else
  fail "the server did not come up healthy with RCON answering"
  compose logs --tail 80 humanitz-server
  echo; echo "passed: $PASSED   failed: $FAILED"; exit 1
fi

echo; echo "--- the settings come from .env"
name="$(env_value HUMANITZ_SERVER_NAME)"; slots="$(env_value HUMANITZ_MAX_PLAYERS)"
info="$(scripts/rcon.sh info 2>&1)"
if grep -q "^Name: $name (" <<<"$info"; then pass "RCON reports the name from .env: $name"; else fail "RCON info: $info"; fi
out="$(scripts/status.sh)"; rc=$?
if [ "$rc" = 0 ] && grep -q "\"status\": \"Online\", \"players\": 0, \"max\": $slots" <<<"$out"; then pass "status: $out"; else fail "status exited $rc: $out"; fi

echo; echo "--- what is and is not reachable"
# THE REASON THIS TEMPLATE COUNTS PLAYERS OVER RCON. If HumanitZ ever starts
# answering the Steam query, this fails, and the README has to change.
qport="$(env_value HUMANITZ_SERVER_QUERY_PORT)"; qport="${qport:-27015}"
a2s="$(docker run --rm --network host python:3.13-alpine python3 -c '
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(5)
try:
    s.sendto(b"\xff\xff\xff\xff\x54Source Engine Query\x00", ("127.0.0.1", int(sys.argv[1]))); s.recvfrom(4096); print("answered")
except Exception:
    print("silent")' "$qport" 2>/dev/null)"
if [ "$a2s" = silent ]; then pass "the Steam query on $qport/udp stays silent, so RCON is the only count"; else fail "the Steam query answered: the README's reason for RCON no longer holds"; fi
if docker run --rm --network host python:3.13-alpine python3 -c '
import socket
socket.create_connection(("127.0.0.1", 8888), 3)' >/dev/null 2>&1; then
  fail "something answers on the host's port 8888: RCON is published"
else
  pass "RCON is published nowhere: nothing answers on the host's port 8888"
fi
# Two answers pass: no crontab at all, or one without LinuxGSM's update line.
# Anything else, a failed exec included, fails with what it saw: an empty
# answer must not pass as "no update scheduled".
cron="$(docker exec "$(compose ps -q humanitz-server)" crontab -l -u linuxgsm 2>&1)"; crc=$?
if grep -q "^no crontab for linuxgsm" <<<"$cron" || { [ "$crc" = 0 ] && ! grep -q "hzserver update" <<<"$cron"; }; then
  pass "LinuxGSM's hourly update is not scheduled (UPDATE_CHECK=0): $(grep -v '^#' <<<"$cron" | head -1 | cut -c1-80)"
else
  fail "linuxgsm's crontab could not be shown to lack LinuxGSM's update (exit $crc): $(tr '\n' ';' <<<"$cron") (UPDATE_CHECK=$(docker exec "$(compose ps -q humanitz-server)" printenv UPDATE_CHECK))"
fi
# Why it is off by decision and not left to chance: under no-new-privileges
# the cron cannot be installed (crontab is setgid), without it it can.
image="$(docker inspect -f '{{.Config.Image}}' "$(compose ps -q humanitz-server)")"
cron_try='echo "0 * * * * /app/hzserver update" | crontab - 2>&1; echo "exit $?"'
hardened="$(docker run --rm --security-opt no-new-privileges:true --user linuxgsm --entrypoint sh "$image" -c "$cron_try" 2>&1)"
plain="$(docker run --rm --user linuxgsm --entrypoint sh "$image" -c "$cron_try" 2>&1)"
if grep -q "Permission denied" <<<"$hardened" && grep -q "exit 1" <<<"$hardened" && grep -q "exit 0" <<<"$plain"; then
  pass "under no-new-privileges LinuxGSM's cron cannot install ($(grep -m1 "Permission denied" <<<"$hardened")), without it it can"
else
  fail "the cron install under and without no-new-privileges: [$hardened] [$plain]"
fi
out="$(scripts/refresh.sh --check 2>&1)"; rc=$?
if [ "$rc" = 0 ] && grep -q "up to date: build [0-9]" <<<"$out"; then pass "refresh --check reads both builds from LinuxGSM: ${out#* * }"; else fail "refresh --check exited $rc: $out"; fi

echo; echo "--- a ban, a backup and a restore"
scripts/rcon.sh "ban $BANNED" >/dev/null 2>&1
if vol 'grep -q "'"$BANNED"'" "$BASE/F_BannedPlayers.txt"' 2>/dev/null; then pass "RCON ban wrote the id to F_BannedPlayers.txt"; else fail "after RCON ban, F_BannedPlayers.txt does not hold the id"; fi
out="$(scripts/backup.sh 2>&1)"; rc=$?
if [ "$rc" = 0 ] && grep -q "backup OK.*the ban list; flushed by RCON save" <<<"$out"; then pass "backup: ${out#* * }"; else fail "backup exited $rc: $out"; fi
archives=("$HUMANITZ_BACKUP_DIR"/humanitz-world-*.tar.gz); archive="${archives[0]}"
compose stop -t 120 humanitz-server >/dev/null 2>&1
vol 'rm -rf "$BASE/Saved/SaveGames" "$BASE/F_BannedPlayers.txt"'
out="$(scripts/restore.sh "$archive" 2>&1)"; rc=$?
if [ "$rc" = 0 ]; then pass "restore: ${out%%;*}"; else fail "restore exited $rc: $out"; fi
mkdir -p "$WORK/extract" && tar -xzf "$archive" -C "$WORK/extract"
want="$(cd "$WORK/extract" && find Saved F_BannedPlayers.txt -type f | sort | xargs sha256sum)"
have="$(vol 'cd "$BASE" && find Saved/SaveGames F_BannedPlayers.txt -type f | sort | xargs sha256sum')"
if [ -n "$want" ] && [ "$want" = "$have" ]; then pass "every file of the archive is back at its live path, byte for byte ($(grep -c . <<<"$want") files)"; else fail "the restored files differ from the archive"; fi
compose start humanitz-server >/dev/null 2>&1
if healthy 30 && rcon_ready; then pass "the restored server starts and answers RCON"; else fail "the restored server did not come back"; fi
if vol 'test -s "$WORLD"'; then pass "after the start, the world is there"; else fail "after the start, the world file is gone: $(vol 'ls -la "$(dirname "$WORLD")" 2>&1' | tr '\n' ';')"; fi
if vol 'grep -q "'"$BANNED"'" "$BASE/F_BannedPlayers.txt"' 2>/dev/null; then
  pass "after the start, the ban is still there"
else
  fail "after the start, the ban list no longer holds the id: $(vol 'ls -la "$BASE"/F_*.txt 2>&1; head -c 300 "$BASE/F_BannedPlayers.txt" 2>&1' | tr '\n' ';')"
fi

echo; echo "--- the health check, in both directions"
cid="$(compose ps -q humanitz-server)"
check="$(docker inspect -f '{{index .Config.Healthcheck.Test 1}}' "$cid")"
if docker exec "$cid" sh -c "$check"; then pass "with the game running, the check is green"; else fail "the check is red with the game running"; fi
docker exec "$cid" sh -c 'for p in /proc/[0-9]*; do case "$(cat $p/comm 2>/dev/null)" in HumanitZServer*) kill -9 "${p##*/}";; esac; done' 2>/dev/null
sleep 3
if [ "$(docker inspect -f '{{.State.Running}}' "$cid")" = true ] && ! docker exec "$cid" sh -c "$check"; then
  pass "the game killed and the container still running: the check goes red"
else
  fail "after killing the game, the check stayed green or the container stopped"
fi

echo
echo "passed: $PASSED   failed: $FAILED"
[ "$FAILED" -eq 0 ]
