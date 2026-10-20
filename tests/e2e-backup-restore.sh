#!/bin/bash
# Does a world go out through scripts/backup.sh and come back through
# scripts/restore.sh to the exact place the server reads it, with its ban list?
#
# The failures this exists for are quiet. A restore that lands one directory
# too deep succeeds, and the server, finding no world where it looks,
# generates a new one. A restore without the ban list succeeds too, and every
# player who was banned can come back. So the assertions are about paths and
# bytes, not exit codes: the world, the settings and the ban list back at
# serverfiles/HumanitZServer with the bytes they had, nothing one level too
# deep, the game files never in the archive, the archive readable by its owner
# alone (the settings hold passwords), and what was there before moved aside,
# not lost.
#
# No game download involved: a volume laid out the way the image lays it out
# (measured on a CI runner), with files of known content. tests/e2e-game.sh
# does the same round trip against the real server.
# shellcheck disable=SC2016  # the single-quoted $BASE expands inside the helper container, on purpose
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

PASSED=0; FAILED=0
pass() { echo "  PASS: $1"; PASSED=$((PASSED+1)); }
fail() { echo "  FAIL: $1"; FAILED=$((FAILED+1)); }

export HUMANITZ_VOLUME="humanitz-test-data-$$"
export HUMANITZ_PROJECT="humanitz-test-$$"
WORK="$(mktemp -d)"
export HUMANITZ_BACKUP_DIR="$WORK/backups"
BASE=/data/serverfiles/HumanitZServer
cleanup() {
  docker compose -p "$HUMANITZ_PROJECT" -f "$WORK/fixture.yml" down -t 1 >/dev/null 2>&1
  docker volume rm -f "$HUMANITZ_VOLUME" >/dev/null 2>&1
  docker run --rm -v "$WORK":/w alpine:3.20 sh -c 'rm -rf /w/* /w/.[!.]*' >/dev/null 2>&1
  rm -rf "$WORK"
}
trap cleanup EXIT

vol() { docker run --rm -v "$HUMANITZ_VOLUME":/data -e BASE="$BASE" alpine:3.20 sh -c "$1"; }
sums() { vol 'cd "$BASE" && find Saved/SaveGames GameServerSettings.ini F_BannedPlayers.txt -type f 2>/dev/null | sort | xargs sha256sum'; }

echo "=== backup and restore, by path and by byte ==="
echo

docker volume create "$HUMANITZ_VOLUME" >/dev/null

# 1. No world yet: before the first start there is nothing to archive.
vol 'mkdir -p "$BASE/Binaries/Linux" "$BASE/Content" && echo game > "$BASE/Binaries/Linux/HumanitZServer-Linux-Shipping"'
out="$(scripts/backup.sh 2>&1)"; rc=$?
if [ "$rc" = 0 ] && grep -q "no world in" <<<"$out" && [ -z "$(ls "$HUMANITZ_BACKUP_DIR" 2>/dev/null)" ]; then
  pass "no world yet: says so, exits 0, writes nothing"
else
  fail "no world yet: exit $rc, said: $out"
fi

# A world, laid out the way the game lays it out, with its rotating copy, the
# settings (a password in them) and a ban list.
vol 'D="$BASE/Saved/SaveGames/SaveList/Default/DedicatedSave"
     mkdir -p "$D/_Backup/0" "$BASE/Saved/Config/LinuxServer" "$BASE/Saved/Logs" &&
     echo world-v1 > "$D/Save_DedicatedSave.sav" &&
     echo world-v1-copy > "$D/_Backup/0/Save_DedicatedSave.sav" &&
     echo global > "$BASE/Saved/SaveGames/DedSave_ResGlobal.sav" &&
     printf "[Host Settings]\nRCONPass=fixture-secret\n" > "$BASE/GameServerSettings.ini" &&
     echo 76561190000000009 > "$BASE/F_BannedPlayers.txt" &&
     echo log > "$BASE/Saved/Logs/HumanitZServer.log" &&
     chown -R 1000:1000 "$BASE"'
sums_before="$(sums)"

# 2. The backup holds the world, the settings and the ban list, and nothing
# else; it says it was not flushed, because no server was there to ask.
out="$(scripts/backup.sh 2>&1)"; rc=$?
archives=("$HUMANITZ_BACKUP_DIR"/humanitz-world-*.tar.gz)
archive="${archives[0]}"; [ -f "$archive" ] || archive=""
if [ "$rc" = 0 ] && [ -n "$archive" ] && grep -q "backup OK" <<<"$out"; then pass "backup: wrote $(basename "$archive")"; else fail "backup: exit $rc, said: $out"; fi
if grep -q "NOT flushed" <<<"$out"; then pass "backup: says the world was not flushed, with no server to ask"; else fail "backup: did not say it was unflushed: $out"; fi
listing="$(tar -tzf "$archive" 2>/dev/null)"
if grep -qx "Saved/SaveGames/SaveList/Default/DedicatedSave/Save_DedicatedSave.sav" <<<"$listing" \
   && grep -qx "GameServerSettings.ini" <<<"$listing" && grep -qx "F_BannedPlayers.txt" <<<"$listing"; then
  pass "backup: the world, the settings and the ban list are in it"
else
  fail "backup: the archive holds: $(tr '\n' ' ' <<<"$listing")"
fi
if grep -q "Binaries\|Content\|Saved/Logs\|Saved/Config" <<<"$listing"; then fail "backup: game files or logs went into the archive"; else pass "backup: the game files and the logs did not"; fi
mode="$(stat -c %a "$archive" 2>/dev/null || stat -f %Lp "$archive")"
if [ "$mode" = 600 ]; then pass "backup: the archive is readable by its owner alone (600), the settings hold passwords"; else fail "backup: the archive's mode is $mode"; fi

# 3. THE CASE THIS FILE EXISTS FOR. The world is lost, a fresh one is in its
# place, and the ban list is gone; the restore must bring all of it back to
# the exact path, byte for byte.
vol 'rm -rf "$BASE/Saved/SaveGames" "$BASE/F_BannedPlayers.txt" &&
     mkdir -p "$BASE/Saved/SaveGames/SaveList/Default/DedicatedSave" &&
     echo fresh-world > "$BASE/Saved/SaveGames/SaveList/Default/DedicatedSave/Save_DedicatedSave.sav"'
out="$(scripts/restore.sh "$archive" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && grep -q "the ban list" <<<"$out"; then pass "restore: exit 0, the ban list named"; else fail "restore: exit $rc, said: $out"; fi
if [ "$(sums)" = "$sums_before" ]; then
  pass "restore: the world, the settings and the ban list are back at their live paths with the bytes they had"
else
  fail "restore: what is at HumanitZServer differs from what was backed up"
fi
if vol 'test -e "$BASE/Saved/Saved" || test -e "$BASE/Saved/SaveGames/SaveGames" || test -e /data/Saved'; then
  fail "restore: something landed one level too deep or at the volume's root"
else
  pass "restore: nothing landed one level too deep"
fi
if vol 'cat "$BASE"/before-restore-*/SaveGames/SaveList/Default/DedicatedSave/Save_DedicatedSave.sav' 2>/dev/null | grep -qx fresh-world; then
  pass "restore: the world that was there is kept aside, not lost"
else
  fail "restore: the world that was there before is gone"
fi
if [ "$(vol 'stat -c %u "$BASE/F_BannedPlayers.txt"')" = 1000 ] && [ "$(vol 'stat -c %u "$BASE/Saved/SaveGames/SaveList/Default/DedicatedSave/Save_DedicatedSave.sav"')" = 1000 ]; then
  pass "restore: the files belong to the server's user, uid 1000"
else
  fail "restore: the files do not belong to uid 1000"
fi

# 4. The naive restore, for contrast: the archive extracted at the volume's
# root. It "works", and the server would find no world.
naive="$(docker run --rm -v "$(cd "$(dirname "$archive")" && pwd)":/in:ro alpine:3.20 sh -c "mkdir -p /v/serverfiles/HumanitZServer && tar -xzf /in/$(basename "$archive") -C /v && test -f /v/serverfiles/HumanitZServer/Saved/SaveGames/SaveList/Default/DedicatedSave/Save_DedicatedSave.sav && echo found || echo missing")"
if [ "$naive" = missing ]; then
  pass "contrast: the same archive extracted at the volume's root leaves no world where the server looks"
else
  fail "contrast: a root extract put the world in place, so this test proves less than it says"
fi

# 5. Refusals, each leaving the world untouched.
sums_now="$(sums)"
mkdir -p "$WORK/junk/other" && echo x > "$WORK/junk/other/file"
tar -czf "$WORK/junk.tar.gz" -C "$WORK/junk" other
out="$(scripts/restore.sh "$WORK/junk.tar.gz" 2>&1)"; rc=$?
if [ "$rc" = 1 ] && grep -q "is not a HumanitZ archive" <<<"$out"; then pass "refuses an archive that is not a world"; else fail "a non-world archive: exit $rc, said: $out"; fi

cat >"$WORK/fixture.yml" <<'YAML'
services:
  humanitz-server:
    image: alpine:3.20
    command: ["sleep", "600"]
YAML
docker compose -p "$HUMANITZ_PROJECT" -f "$WORK/fixture.yml" up -d >/dev/null 2>&1
out="$(scripts/restore.sh "$archive" 2>&1)"; rc=$?
if [ "$rc" = 1 ] && grep -q "the server is running" <<<"$out"; then pass "refuses while the server is running"; else fail "a running server: exit $rc, said: $out"; fi
docker compose -p "$HUMANITZ_PROJECT" -f "$WORK/fixture.yml" down -t 1 >/dev/null 2>&1
if [ "$(sums)" = "$sums_now" ]; then
  pass "the refusals left the world untouched"
else
  fail "a refusal changed the world"
fi

# 6. A world backed up before and gone now is not "no world yet".
vol 'rm -rf "$BASE/Saved/SaveGames"'
out="$(scripts/backup.sh 2>&1)"; rc=$?
if [ "$rc" = 1 ] && grep -q "FAILED: no world in .* holds one" <<<"$out"; then
  pass "a world archived before and gone now: fails, and names the archive that had it"
else
  fail "a lost world: exit $rc, said: $out"
fi

echo
echo "passed: $PASSED   failed: $FAILED"
[ "$FAILED" -eq 0 ]
