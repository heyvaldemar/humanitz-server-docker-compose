#!/bin/bash
# Put a HumanitZ archive from scripts/backup.sh back where the server reads it.
#
#   scripts/restore.sh backups/humanitz-world-20261020-043500.tar.gz
#
# THE PATH IS THE WHOLE JOB. The server looks for its world under
# serverfiles/HumanitZServer/Saved/SaveGames inside the volume and, finding
# none there, generates a new one without a word. A restore one directory too
# deep succeeds, reports success, and leaves players in a fresh world. On the
# machine this template comes from, a test restore of another game's world
# showed exactly that: a plain restore of the latest snapshot put the world one
# level too deep, caught before the backup was ever needed. So this extracts
# at the one anchor the backup was
# made from, then checks that every file in the archive is at its live path,
# the ban list included, and that nothing landed one level too deep.
#
# NOTHING IS OVERWRITTEN. What the volume holds now (Saved/SaveGames, the
# settings, the ban list) is moved to HumanitZServer/before-restore-<time>/
# first, so a restore of the wrong archive is undone by moving it back.
#
# The server must be stopped: it holds the world in memory and would write it
# over the restored one on its way out. The settings come back as they were at
# the backup; scripts/start.sh sets the [Host Settings] from .env again when
# the server starts.
#
#   HUMANITZ_VOLUME    the data volume      (default humanitz-server-data)
#   HUMANITZ_PROJECT   the compose project  (default humanitz)
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

ARCHIVE="${1:-}"
VOLUME="${HUMANITZ_VOLUME:-humanitz-server-data}"
PROJECT="${HUMANITZ_PROJECT:-humanitz}"
BASE=/data/serverfiles/HumanitZServer

if [ -z "$ARCHIVE" ] || [ ! -f "$ARCHIVE" ]; then
  echo "usage: scripts/restore.sh <archive from scripts/backup.sh>" >&2
  exit 2
fi
if ! docker volume inspect "$VOLUME" >/dev/null 2>&1; then
  echo "no volume $VOLUME: create it first (docker volume create $VOLUME)" >&2
  exit 1
fi

running="$(docker compose -p "$PROJECT" ps -q --status running humanitz-server 2>/dev/null || true)"
if [ -n "$running" ]; then
  echo "the server is running; stop it first, or it writes its world over the restored one on the way out:" >&2
  echo "  docker compose -f humanitz-server-docker-compose.yml -p $PROJECT stop humanitz-server" >&2
  exit 1
fi

DIR="$(cd "$(dirname "$ARCHIVE")" && pwd)"
FILE="$(basename "$ARCHIVE")"

# What the archive holds, read before anything moves. A HumanitZ archive has a
# world file under Saved/SaveGames/SaveList and nothing but Saved/SaveGames,
# the settings and the ban list.
listing="$(docker run --rm -v "$DIR":/in:ro alpine:3.20 tar -tzf "/in/$FILE" 2>/dev/null)" || {
  echo "$ARCHIVE is not a readable tar.gz; nothing changed" >&2
  exit 1
}
# shellcheck disable=SC2001  # strip a leading ./ from every line, not one
listing="$(sed 's#^\./##' <<<"$listing")"
worlds="$(grep -cE '^Saved/SaveGames/SaveList/.*/Save_[^/]*\.sav$' <<<"$listing")"
outside="$(grep -vE '^(Saved/?$|Saved/SaveGames(/|$)|GameServerSettings\.ini$|F_BannedPlayers\.txt$)' <<<"$listing" | grep -c .)"
if [ "$worlds" -lt 1 ] || [ "$outside" -gt 0 ]; then
  echo "$ARCHIVE is not a HumanitZ archive from scripts/backup.sh ($worlds world file(s), $outside entr(ies) that do not belong); nothing changed" >&2
  exit 1
fi

stamp="$(date +%Y%m%d-%H%M%S)"
docker run --rm -v "$VOLUME":/data -v "$DIR":/in:ro -e STAMP="$stamp" -e FILE="$FILE" -e BASE="$BASE" alpine:3.20 sh -euc '
  mkdir -p "$BASE/Saved"
  aside="$BASE/before-restore-$STAMP"
  mkdir -p "$aside"
  [ -e "$BASE/Saved/SaveGames" ] && mv "$BASE/Saved/SaveGames" "$aside/SaveGames"
  [ -e "$BASE/GameServerSettings.ini" ] && mv "$BASE/GameServerSettings.ini" "$aside/"
  [ -e "$BASE/F_BannedPlayers.txt" ] && mv "$BASE/F_BannedPlayers.txt" "$aside/"
  tar -xzf "/in/$FILE" -C "$BASE"
  # The server runs as the image user, uid 1000.
  chown -R 1000:1000 "$BASE/Saved/SaveGames" "$BASE/GameServerSettings.ini"
  [ -e "$BASE/F_BannedPlayers.txt" ] && chown 1000:1000 "$BASE/F_BannedPlayers.txt"
  true
' || { echo "the extract failed; what the volume held is in HumanitZServer/before-restore-$stamp" >&2; exit 1; }

# PROVE IT LANDED: every file in the archive at its live path, and nothing one
# level too deep.
files="$(grep -vE '/$' <<<"$listing")"
expected="$(grep -c . <<<"$files")"
found="$(docker run --rm -i -v "$VOLUME":/data:ro -e BASE="$BASE" alpine:3.20 \
  sh -c 'n=0; while IFS= read -r f; do if [ -f "$BASE/$f" ]; then n=$((n + 1)); else echo "not at its live path: HumanitZServer/$f" >&2; fi; done; echo "$n"' <<<"$files")"
missing=0
if [ "${found:-0}" != "$expected" ]; then
  echo "${found:-0} of $expected file(s) are at their live path" >&2
  missing=1
fi
if docker run --rm -v "$VOLUME":/data:ro -e BASE="$BASE" alpine:3.20 sh -c 'test -e "$BASE/Saved/Saved" || test -e "$BASE/Saved/SaveGames/SaveGames" || test -e /data/Saved'; then
  echo "a Saved directory landed one level too deep or at the volume's root; the server would not find the world" >&2
  missing=$((missing + 1))
fi
if [ "$missing" -gt 0 ]; then
  echo "restore FAILED its check; what the volume held is in HumanitZServer/before-restore-$stamp" >&2
  exit 1
fi
bans="no ban list in the archive"
grep -qx 'F_BannedPlayers.txt' <<<"$listing" && bans="the ban list"
echo "restored $expected file(s) from $FILE: $worlds world file(s), the settings, $bans; what the volume held is in HumanitZServer/before-restore-$stamp"
echo "start the server: docker compose -f humanitz-server-docker-compose.yml -p $PROJECT start humanitz-server"
