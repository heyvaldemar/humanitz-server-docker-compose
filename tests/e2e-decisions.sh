#!/bin/bash
# Does scripts/refresh.sh restart only an empty server that is behind, and does
# scripts/status.sh refuse to call a silent server empty?
#
# A restart drops everyone on the server, so the decisions are the whole
# script: up to date, leave it; behind with players on, wait; behind and RCON
# does not answer, wait AND exit 1, because "cannot count" read as zero is how
# a restart lands on a full server; behind and empty, restart. The status JSON
# follows the same rule: no answer is "Unknown" with players null, never
# "Online" with 0.
#
# No game download and no Steam: the "server" is a few lines of Python that
# answer RCON the way HumanitZ does (authentication answered twice, lines
# ending in CRLF, an unknown command left unanswered) with a chosen player
# count, or not at all, and a stand-in for LinuxGSM's hzserver that prints a
# chosen local and remote build, coloured as LinuxGSM colours them. Nothing
# here reaches the real restart: the cases that would go ahead run with
# --dry-run.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

PASSED=0; FAILED=0
pass() { echo "  PASS: $1"; PASSED=$((PASSED+1)); }
fail() { echo "  FAIL: $1"; FAILED=$((FAILED+1)); }

WORK="$(mktemp -d)"
PROJECTS=()
cleanup() {
  for p in ${PROJECTS[@]+"${PROJECTS[@]}"}; do docker compose -p "$p" -f "$WORK/fixture.yml" down -t 1 >/dev/null 2>&1; done
  rm -rf "$WORK"
}
trap cleanup EXIT

cat >"$WORK/fixture.yml" <<'YAML'
services:
  humanitz-server:
    image: python:3.13-alpine
    environment:
      MODE: ${MODE:-unset}
      # `-`, not `:-`: an empty value has to stay empty (a missing build).
      LOCAL: ${LOCAL-0}
      REMOTE: ${REMOTE-0}
      HUMANITZ_RCON_PASSWORD: fixture-password
    command:
      - sh
      - -c
      - |
        adduser -D -u 1000 linuxgsm 2>/dev/null
        mkdir -p /app /data/serverfiles/HumanitZServer
        printf '[Host Settings]\nMaxPlayers=16\n' > /data/serverfiles/HumanitZServer/GameServerSettings.ini
        # LinuxGSM's check-update, as it prints: coloured, with an empty
        # LOCAL or REMOTE meaning that line is missing.
        cat > /app/hzserver <<'SH'
        #!/bin/sh
        [ "$$1" = check-update ] || exit 1
        [ -n "$$LOCAL" ] && printf '* Local build: \033[31m%s\033[0m\n' "$$LOCAL"
        [ -n "$$REMOTE" ] && printf '* Remote build: \033[32m%s\033[0m\n' "$$REMOTE"
        exit 0
        SH
        chmod +x /app/hzserver
        exec python3 -c '
        import os, socket, struct
        mode = os.environ["MODE"]
        def pkt(i, t, body):
            b = body.encode() + b"\x00\x00"
            return struct.pack("<iii", len(b) + 8, i, t) + b
        def read(c):
            n = struct.unpack("<i", c.recv(4))[0]
            d = b""
            while len(d) < n:
                d += c.recv(n - len(d))
            i, t = struct.unpack("<ii", d[:8])
            return i, t, d[8:-2].decode()
        s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind(("127.0.0.1", 8888)); s.listen(8)
        n = 0
        while True:
            c, _ = s.accept()
            n += 1
            open("/tmp/connections", "w").write(str(n))
            try:
                if mode == "silent":
                    c.recv(64)
                    continue
                i, t, body = read(c)
                ok = body == "fixture-password"
                c.sendall(pkt(i, 0, ""))
                c.sendall(pkt(i if ok else -1, 2, ""))
                if not ok:
                    continue
                while True:
                    i, t, body = read(c)
                    if body == "info":
                        players = int(mode.split(":")[1])
                        c.sendall(pkt(i, 0, "Name: Fixture (Uptime: 3 minutes)\r\n%d connected.\r\nSeason: Summer\r\nPlayers:\r\n" % players))
            except Exception:
                pass
            finally:
                c.close()
        '
YAML

# start MODE LOCAL REMOTE: a stand-in of its own per case. Sets $p rather than
# printing it, so the project reaches PROJECTS and the cleanup.
start() {
  p="hz-decisions-$$-${#PROJECTS[@]}"
  PROJECTS+=("$p")
  MODE="$1" LOCAL="$2" REMOTE="$3" docker compose -p "$p" -f "$WORK/fixture.yml" up -d >/dev/null 2>&1 || { echo "cannot start the stand-in"; exit 1; }
  # Ready means the stand-in hzserver exists and RCON's port is listening
  # (8888 is 0x22B8 in /proc/net/tcp); it answers nothing until asked.
  for _ in $(seq 1 60); do
    docker compose -p "$p" -f "$WORK/fixture.yml" exec -T humanitz-server sh -c \
      'test -x /app/hzserver && grep -q ":22B8 " /proc/net/tcp' 2>/dev/null && break
    sleep 0.5
  done
}
started() { docker inspect -f '{{.Id}} {{.State.StartedAt}}' "$(docker compose -p "$1" -f "$WORK/fixture.yml" ps -q humanitz-server)"; }
connections() { docker compose -p "$1" -f "$WORK/fixture.yml" exec -T humanitz-server cat /tmp/connections 2>/dev/null || echo 0; }
# A refresh that goes ahead when it should not restarts the server and waits
# up to ten minutes for a new build. Two minutes is far more than any decision
# here takes, so past it is a failure.
refresh() {
  if command -v timeout >/dev/null 2>&1; then
    HUMANITZ_PROJECT="$p" HUMANITZ_REFRESH_RETRY_SECONDS=1 timeout 120 scripts/refresh.sh "$@"
  else
    HUMANITZ_PROJECT="$p" HUMANITZ_REFRESH_RETRY_SECONDS=1 perl -e 'alarm 120; exec @ARGV' scripts/refresh.sh "$@"
  fi
}

echo "=== the refresh, the build and the players on the server ==="
echo

# 1. Up to date: nothing to do, and RCON is not even asked.
start players:0 100 100
out="$(refresh 2>&1)"; rc=$?
if [ "$rc" = 0 ] && grep -q "up to date: build 100" <<<"$out"; then pass "up to date: says so"; else fail "up to date: exit $rc, said: $out"; fi
if [ "$(connections "$p")" = 0 ]; then pass "up to date: RCON was not even asked"; else fail "up to date: RCON was asked anyway"; fi

# 2. --check reports a server that is behind and changes nothing.
start players:0 100 101
out="$(refresh --check 2>&1)"; rc=$?
if [ "$rc" = 0 ] && grep -q "behind: running build 100, Steam ships 101" <<<"$out"; then pass "--check: reports behind"; else fail "--check: exit $rc, said: $out"; fi

# 3. Behind, with players on: wait. RCON answers in CRLF, as HumanitZ does.
start players:2 100 101; before="$(started "$p")"
out="$(refresh 2>&1)"; rc=$?
if [ "$rc" = 0 ] && grep -q "but 2 player(s) are on" <<<"$out"; then pass "behind, two players on (CRLF answer): waits"; else fail "behind, two players on: exit $rc, said: $out"; fi
if [ "$(started "$p")" = "$before" ]; then pass "behind, two players on: not restarted"; else fail "behind, two players on: restarted"; fi

# 4. THE CASE THIS FILE EXISTS FOR: behind, and RCON does not answer.
start silent 100 101; before="$(started "$p")"
out="$(refresh 2>&1)"; rc=$?
if [ "$rc" = 1 ] && grep -q "RCON did not answer three times" <<<"$out"; then pass "behind, RCON silent: waits, exit 1"; else fail "behind, RCON silent: exit $rc, said: $out"; fi
if [ "$(started "$p")" = "$before" ]; then pass "behind, RCON silent: not restarted"; else fail "behind, RCON silent: restarted"; fi
c="$(connections "$p")"
if [ "$c" = 3 ]; then pass "behind, RCON silent: asked three times"; else fail "behind, RCON silent: asked $c time(s), expected 3"; fi

# 5. Behind and empty: it would restart.
start players:0 100 101
out="$(refresh --dry-run 2>&1)"; rc=$?
if [ "$rc" = 0 ] && grep -q "would restart to update (100 -> 101): players online: 0" <<<"$out"; then pass "behind, nobody on: it would restart"; else fail "behind, nobody on: exit $rc, said: $out"; fi

# 6. --force overrides an unknown count, and says that it did.
start silent 100 101
out="$(refresh --dry-run --force 2>&1)"; rc=$?
if [ "$rc" = 0 ] && grep -q "players online: ?, forced" <<<"$out"; then pass "behind, RCON silent, --force: it would restart"; else fail "behind, RCON silent, --force: exit $rc, said: $out"; fi

# 7. Steam's build missing, the installed one read: tolerated, the start noted.
silent="$WORK/steam-silent"
start players:0 100 ""
out="$(HUMANITZ_REFRESH_STEAM_SILENT_FILE="$silent" refresh 2>&1)"; rc=$?
if [ "$rc" = 0 ] && grep -q "Steam did not say which build it ships (running build 100); quiet for 0 min, tolerated up to 180 min" <<<"$out" && [ -s "$silent" ]; then pass "Steam's build missing: tolerated, exit 0, the start noted"; else fail "Steam's build missing: exit $rc, said: $out"; fi

# 7a. However often it runs, the span is what counts: quiet for four hours fails.
echo "$(( $(date +%s) - 14400 ))" > "$silent"
out="$(HUMANITZ_REFRESH_STEAM_SILENT_FILE="$silent" refresh 2>&1)"; rc=$?
if [ "$rc" = 1 ] && grep -q "for 240 min, past the 180 min tolerance" <<<"$out"; then pass "Steam silent for four hours: exit 1"; else fail "Steam silent past the span: exit $rc, said: $out"; fi

# 7a2. A start in the future would keep the silence young forever: it starts now.
echo "$(( $(date +%s) + 86400 ))" > "$silent"
out="$(HUMANITZ_REFRESH_STEAM_SILENT_FILE="$silent" refresh 2>&1)"; rc=$?
if [ "$rc" = 0 ] && grep -q "quiet for 0 min" <<<"$out" && [ "$(cat "$silent")" -le "$(date +%s)" ]; then pass "a start in the future: re-anchored to now"; else fail "future start: exit $rc, said: $out"; fi

# 7a3. A silence that cannot be recorded is not tolerated.
out="$(HUMANITZ_REFRESH_STEAM_SILENT_FILE="/nonexistent-dir/silent" refresh 2>&1)"; rc=$?
if [ "$rc" = 1 ] && grep -q "cannot record when Steam went quiet" <<<"$out"; then pass "silence that cannot be recorded: exit 1"; else fail "unrecordable silence: exit $rc, said: $out"; fi

# 7b. The installed build missing is a fault here: exit 1 at once, nothing decided.
start players:0 "" 101
out="$(HUMANITZ_REFRESH_STEAM_SILENT_FILE="$silent" refresh 2>&1)"; rc=$?
if [ "$rc" = 1 ] && grep -q "could not read both builds" <<<"$out"; then pass "installed build missing: exit 1, nothing changed"; else fail "installed build missing: exit $rc, said: $out"; fi

# 7c. Steam answers again: the span starts over.
start players:0 100 100
out="$(HUMANITZ_REFRESH_STEAM_SILENT_FILE="$silent" refresh 2>&1)"; rc=$?
if [ "$rc" = 0 ] && [ ! -e "$silent" ]; then pass "Steam answers: the silence is forgotten"; else fail "Steam answers: exit $rc, file left: $([ -e "$silent" ] && echo yes), said: $out"; fi

echo
echo "=== the status, and what it says when nobody answers ==="
echo

# 8. Online: players from "N connected.", the slot count from the settings,
# and no carriage return left in the season.
start players:3 100 100
out="$(HUMANITZ_PROJECT="$p" scripts/status.sh 2>&1)"; rc=$?
if [ "$rc" = 0 ] && grep -q '"status": "Online", "players": 3, "max": 16, "season": "Summer"' <<<"$out"; then pass "status: Online, 3 of 16, season without its CR"; else fail "status online: exit $rc, said: $out"; fi

# 9. RCON silent: Unknown, players null, exit 1. Never "Online" with 0.
start silent 100 100
out="$(HUMANITZ_PROJECT="$p" scripts/status.sh 2>&1)"; rc=$?
if [ "$rc" = 1 ] && grep -q '"status": "Unknown", "players": null' <<<"$out"; then pass "status, RCON silent: Unknown, players null, exit 1"; else fail "status, RCON silent: exit $rc, said: $out"; fi

# 10. The server stopped: Unknown, from the host, exit 1.
docker compose -p "$p" -f "$WORK/fixture.yml" stop -t 1 >/dev/null 2>&1
out="$(HUMANITZ_PROJECT="$p" scripts/status.sh 2>&1)"; rc=$?
if [ "$rc" = 1 ] && grep -q '"status": "Unknown", "players": null' <<<"$out"; then pass "status, server stopped: Unknown, exit 1"; else fail "status, server stopped: exit $rc, said: $out"; fi

echo
echo "passed: $PASSED   failed: $FAILED"
[ "$FAILED" -eq 0 ]
