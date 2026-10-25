#!/bin/bash
# Does a start go on without waiting for an npm registry that does not
# answer, against the pinned image?
#
# The image's entrypoint runs `npm install` in /app/lgsm on every start. Here
# the module LinuxGSM installs there is installed once with the registry
# reachable, then the registry's name points at a listener that accepts every
# connection and never answers, which is how it looked on the machine this
# template comes from. With the compose file's NPM_CONFIG_* settings, read
# from the compose file, the same `npm install` must finish within fifteen
# seconds. With npm's defaults it must still be waiting at ninety, or the
# settings are not what saves the start.
# shellcheck disable=SC2015   # pass and fail always exit 0, so "A && pass || fail" is if-then-else here
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

PASSED=0; FAILED=0
pass() { echo "  PASS: $1"; PASSED=$((PASSED+1)); }
fail() { echo "  FAIL: $1"; FAILED=$((FAILED+1)); }

IMAGE="$(grep -m1 -oE '\$\{HUMANITZ_SERVER_IMAGE_TAG:-.*' humanitz-server-docker-compose.yml | sed -E -e ':a' -e 's/\$\{[A-Z0-9_]+:-([^{}]*)\}/\1/' -e 'ta')"
[ -n "$IMAGE" ] || { echo "could not read the pinned image from the compose file"; exit 1; }
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

docker pull -q "$IMAGE" >/dev/null 2>&1 || { echo "cannot pull $IMAGE"; exit 1; }
echo "    $IMAGE"
echo
echo "=== npm at start, with a registry that never answers ==="
echo

# The compose file's own settings, not a copy of them.
HUMANITZ_ADMIN_PASSWORD=ci HUMANITZ_RCON_PASSWORD=ci docker compose -f humanitz-server-docker-compose.yml config --format json 2>/dev/null \
  | python3 -c 'import json,sys
env=json.load(sys.stdin)["services"]["humanitz-server"].get("environment") or {}
for k,v in sorted(env.items()):
    if k.startswith("NPM_CONFIG_"): print(f"{k}={v}")' >"$SCRATCH/npm.env"
echo "    from the compose file: $(cut -d= -f1 "$SCRATCH/npm.env" | tr '\n' ' ')"
grep -q '^NPM_CONFIG_AUDIT=false$' "$SCRATCH/npm.env" && pass "the compose file turns npm's audit off" \
  || fail "the compose file does not set NPM_CONFIG_AUDIT=false"

# What check_gamedig.sh does on a first start, then the registry goes quiet.
# `timeout` is the image's, so the measurement does not depend on the host.
cat >"$SCRATCH/npm.sh" <<'PROBE'
set -u
cd /app/lgsm && chown linuxgsm:linuxgsm /app/lgsm
gosu linuxgsm curl -sfL -o package.json https://raw.githubusercontent.com/GameServerManagers/LinuxGSM/master/package.json || { echo "first: no package.json"; exit 0; }
gosu linuxgsm env HOME=/data npm install >/dev/null 2>&1 || { echo "first: npm install failed with the registry up"; exit 0; }
echo "first: installed"
python3 -c '
import socket
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("0.0.0.0", 443)); s.listen(64); held = []
while True: held.append(s.accept()[0])' &
echo "127.0.0.1 registry.npmjs.org" >>/etc/hosts
sleep 1
args=(); while IFS= read -r kv; do args+=("$kv"); done </probe/npm.env
s=$(date +%s); timeout 60 gosu linuxgsm env HOME=/data "${args[@]}" npm install >/tmp/with.log 2>&1; rc=$?
echo "with: $rc $(( $(date +%s) - s )) $(tail -1 /tmp/with.log)"
s=$(date +%s); timeout 90 gosu linuxgsm env HOME=/data npm install >/dev/null 2>&1; rc=$?
echo "without: $rc $(( $(date +%s) - s ))"
PROBE
out="$(docker run --rm -v "$SCRATCH:/probe:ro" --entrypoint bash "$IMAGE" /probe/npm.sh 2>/dev/null)"
if ! grep -q "^first: installed" <<<"$out"; then
  fail "could not install LinuxGSM's npm module with the registry up: $(grep '^first:' <<<"$out")"
else
  read -r _ rc secs rest <<<"$(grep '^with:' <<<"$out")"
  [ "$rc" = 0 ] && [ "${secs:-99}" -le 15 ] && pass "with the compose file's settings: done in ${secs}s, registry silent ($rest)" \
    || fail "with the compose file's settings: exit ${rc:-?} after ${secs:-?}s against a silent registry"
  read -r _ rc secs <<<"$(grep '^without:' <<<"$out")"
  [ "$rc" = 124 ] && pass "with npm's defaults: still waiting at ${secs}s, so the settings are what saves the start" \
    || fail "with npm's defaults it did not wait (exit ${rc:-?} after ${secs:-?}s): the settings are not what this test says"
fi

echo
echo "passed: $PASSED   failed: $FAILED"
[ "$FAILED" -eq 0 ]
