#!/bin/bash
# scripts/start.sh, against the pinned image, with no game: no password in
# the log, and a stop is still LinuxGSM's.
#
# LinuxGSM's `details`, which the image runs after every start, prints the
# admin password it finds in the settings file. It looks for AdminPassword,
# a key HumanitZ does not use (the game's is AdminPass, which start.sh
# writes), so today it prints "NOT SET"; one LinuxGSM fix away it would print
# the password on every start. Here the settings file gets an AdminPassword
# line as well, a random value, the way that fix would read it:
#   the control   the image's own entrypoint prints it in `docker logs`
#   start.sh      in front of it: neither that value nor any of the three
#                 passwords from the environment in `docker logs`; the
#                 "Admin password" line reads ********; process 1 is start.sh
#   a stop        docker stop: a save is asked for over RCON first (no game
#                 here to answer it: said so), then LinuxGSM's stop runs and
#                 its last line reaches the log, exit 0, inside the grace
#                 period. tests/e2e-game.sh proves the save on the real game.
# Values reach the containers through a file (--env-file) and stdin, never
# an argument.
# shellcheck disable=SC2015   # pass and fail always exit 0, so "A && pass || fail" is if-then-else here
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

PASSED=0; FAILED=0
pass() { echo "  PASS: $1"; PASSED=$((PASSED+1)); }
fail() { echo "  FAIL: $1"; FAILED=$((FAILED+1)); }

IMAGE="$(grep -m1 -oE '\$\{HUMANITZ_SERVER_IMAGE_TAG:-.*' humanitz-server-docker-compose.yml | sed -E -e ':a' -e 's/\$\{[A-Z0-9_]+:-([^{}]*)\}/\1/' -e 'ta')"
[ -n "$IMAGE" ] || { echo "could not read the pinned image from the compose file"; exit 1; }
SCRATCH="$(mktemp -d)"
VOLUME="humanitz-starttest-$$"
C1="humanitz-starttest-bare-$$"; C2="humanitz-starttest-wrapped-$$"
cleanup() { docker rm -f "$C1" "$C2" >/dev/null 2>&1; docker volume rm -f "$VOLUME" >/dev/null 2>&1; rm -rf "$SCRATCH"; }
trap cleanup EXIT
umask 077

L="l$(openssl rand -hex 10)"   # the AdminPassword line LinuxGSM reads
{
  echo "HUMANITZ_SERVER_PASSWORD=j$(openssl rand -hex 10)"
  echo "HUMANITZ_ADMIN_PASSWORD=a$(openssl rand -hex 10)"
  echo "HUMANITZ_RCON_PASSWORD=r$(openssl rand -hex 10)"
} >"$SCRATCH/env"
{ cut -d= -f2- "$SCRATCH/env"; echo "$L"; } >"$SCRATCH/values"

# An installed layout: what start.sh checks for, and a settings file with
# LinuxGSM's key in it. Written on stdin.
installed() {
  docker volume rm -f "$VOLUME" >/dev/null 2>&1; docker volume create "$VOLUME" >/dev/null
  printf '[Host Settings]\nServerName="start test"\nAdminPassword=%s\n' "$L" \
    | docker run --rm -i -v "$VOLUME:/data" --entrypoint sh "$IMAGE" -c \
      'mkdir -p /data/serverfiles/HumanitZServer && cat >/data/serverfiles/HumanitZServer/GameServerSettings.ini && chown -R 1000:1000 /data'
}
# As the compose file runs it: no-new-privileges, the same environment,
# with (wrapped) or without (bare) start.sh in front. The image's own health
# check off: it would run LinuxGSM's monitor, which the compose file replaces.
up() {  # name, wrapped|bare
  local name=$1 how=$2
  set -- --no-healthcheck --security-opt no-new-privileges:true --env-file "$SCRATCH/env" \
    -e GAMESERVER=hzserver -e UPDATE_CHECK=0 -e NPM_CONFIG_AUDIT=false -e NPM_CONFIG_PREFER_OFFLINE=true \
    -e NPM_CONFIG_FETCH_TIMEOUT=30000 -e NPM_CONFIG_FETCH_RETRIES=1 -v "$VOLUME:/data"
  if [ "$how" = wrapped ]; then
    docker run -d --name "$name" "$@" --entrypoint /bin/bash -v "$PWD/scripts/start.sh:/opt/humanitz/start.sh:ro" \
      -v "$PWD/scripts/rcon.py:/opt/humanitz/rcon.py:ro" "$IMAGE" /opt/humanitz/start.sh >/dev/null
  else
    docker run -d --name "$name" "$@" "$IMAGE" >/dev/null
  fi
  for _ in $(seq 1 90); do docker logs "$name" 2>&1 | grep -q 'Tail log files' && return 0; sleep 2; done
  return 1
}

docker pull -q "$IMAGE" >/dev/null 2>&1 || { echo "cannot pull $IMAGE"; exit 1; }
echo "    $IMAGE"
echo
echo "=== scripts/start.sh: no password in the log, and a stop is still LinuxGSM's ==="
echo

# 1. The control: the image's own entrypoint prints the AdminPassword line.
installed
if up "$C1" bare; then
  n="$(docker logs "$C1" 2>&1 | grep -c -F "$L" || true)"
  [ "$n" -ge 1 ] && pass "the image's own entrypoint: an AdminPassword in the settings file is in its log ($n line(s), LinuxGSM's details)" \
    || fail "the image's own entrypoint did not print it; this test no longer shows what the filter is for"
else
  fail "the image's own entrypoint never reached its tail of the logs"
fi
docker rm -f "$C1" >/dev/null 2>&1

# 2. start.sh in front: masked, process 1 is the script, a stop is LinuxGSM's.
installed
if up "$C2" wrapped; then
  logs="$(docker logs "$C2" 2>&1)"
  n="$(grep -c -F -f "$SCRATCH/values" <<<"$logs" || true)"
  masked="$(grep -c -E '^Admin password: +\*{8}$' <<<"$logs" || true)"
  [ "$n" = 0 ] && [ "$masked" = 1 ] && pass "start.sh: none of the four values in the log; \"Admin password\" reads ********" \
    || fail "start.sh: a value on ${n:-?} line(s), ${masked:-0} masked admin line(s)"
  p1="$(docker exec "$C2" sh -c 'tr "\0" " " </proc/1/cmdline')"
  [[ $p1 == "/bin/bash /opt/humanitz/start.sh"* ]] && pass "process 1 is scripts/start.sh" || fail "process 1 is: $p1"
  since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  t0=$SECONDS; docker stop -t 120 "$C2" >/dev/null; secs=$((SECONDS - t0))
  code="$(docker inspect -f '{{.State.ExitCode}}' "$C2")"
  after="$(docker logs --since "$since" "$C2" 2>&1)"
  [ "$code" = 0 ] && [ "$secs" -lt 100 ] && grep -q '^start.sh: stopping: RCON save got no "Game saved"' <<<"$after" && grep -q '^Stopping hzserver' <<<"$after" && grep -q 'STOP: PASS: core_exit.sh exiting with code: 0' <<<"$after" \
    && pass "docker stop: a save asked for first (no game here to answer it), then LinuxGSM's stop, its last line in the log, exit 0, ${secs}s of 120" \
    || fail "docker stop: exit $code after ${secs}s; the log after the stop: $(tail -3 <<<"$after" | tr '\n' ' ')"
else
  fail "start.sh never reached the image's tail of the logs: $(docker logs --tail 5 "$C2" 2>&1 | tr '\n' ' ')"
fi

echo
echo "passed: $PASSED   failed: $FAILED"
[ "$FAILED" -eq 0 ]
