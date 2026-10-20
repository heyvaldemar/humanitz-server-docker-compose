#!/bin/bash
# Archive the HumanitZ world, its settings and its ban list.
#
# WHAT IS ARCHIVED, from serverfiles/HumanitZServer inside the volume:
#   Saved/SaveGames          the world (SaveList/.../Save_<name>.sav) and the
#                            game's own rotating _Backup copies
#   GameServerSettings.ini   the server's rules. Its passwords come back too,
#                            so the archive is written readable by its owner
#                            only, and scripts/start.sh sets the [Host Settings]
#                            from .env again on the next start anyway.
#   F_BannedPlayers.txt      the ban list that RCON `ban` writes. A restore
#                            without it quietly lets every banned player back in.
# Not the 1.4 GB of game files beside them: SteamCMD downloads those again.
# The archive holds paths relative to HumanitZServer/, and scripts/restore.sh
# extracts it at exactly that place. A restore that lands one directory too
# deep finds no world, and the server generates a new one.
#
# FLUSHED FIRST. HumanitZ has RCON, and `save` writes the world on demand
# ("Game saved!", the save file rewritten the same second, measured on a CI
# runner). If the save cannot be asked for (server stopped, mid-restart), the
# archive is still taken, of the last autosave (every 300 seconds by default),
# and the line says so rather than skipping the night.
#
# A BACKUP KILLED HALFWAY MUST NOT KEEP THE NAME A FINISHED ONE HAS. The
# archive is written as <name>.partial and renamed only once tar has succeeded
# AND the archive is shown to hold a world file: tar's exit code says it ran,
# not that it kept a world.
#
# NO WORLD YET IS NOT A FAILURE; NO WORLD ANY MORE IS. Before the first start
# there is nothing to archive, and this says so and exits 0. Once this script
# has archived a world, the same absence means the world is gone or is no
# longer where this looks, and it fails.
#
# Usage: scripts/backup.sh
#   HUMANITZ_BACKUP_DIR   where archives go       (default ./backups)
#   HUMANITZ_BACKUP_KEEP  how many to keep        (default 14)
#   HUMANITZ_VOLUME       the data volume         (default humanitz-server-data)
#   HUMANITZ_PROJECT      the compose project     (default humanitz)
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

BACKUP_DIR="${HUMANITZ_BACKUP_DIR:-./backups}"
KEEP="${HUMANITZ_BACKUP_KEEP:-14}"
VOLUME="${HUMANITZ_VOLUME:-humanitz-server-data}"
PROJECT="${HUMANITZ_PROJECT:-humanitz}"
BASE=/data/serverfiles/HumanitZServer
WORLD_FILE='^Saved/SaveGames/SaveList/.*/Save_[^/]*\.sav$'

if ! docker volume inspect "$VOLUME" >/dev/null 2>&1; then
  echo "$(date '+%F %T') no volume $VOLUME: nothing to back up" >&2
  exit 1
fi

# `test` answers 1 for "not there". Anything else is docker failing to ask,
# and reading that as "no world yet" would be a probe that lies by staying
# quiet.
docker run --rm -v "$VOLUME":/data:ro alpine:3.20 test -d "$BASE/Saved/SaveGames"
rc=$?
if [ "$rc" -gt 1 ]; then
  echo "$(date '+%F %T') could not look inside $VOLUME (docker exited $rc); nothing archived" >&2
  exit 1
fi
if [ "$rc" = 1 ]; then
  last="$(find "$BACKUP_DIR" -maxdepth 1 -name 'humanitz-world-*.tar.gz' 2>/dev/null | sort | tail -1)"
  if [ -n "$last" ]; then
    echo "$(date '+%F %T') FAILED: no world in $VOLUME (Saved/SaveGames does not exist), and $(basename "$last") holds one: the world this server had is gone, or is no longer where this script looks" >&2
    exit 1
  fi
  echo "$(date '+%F %T') no world in $VOLUME yet (Saved/SaveGames does not exist): nothing to back up. HumanitZ writes one on its first start."
  exit 0
fi

# timeout(1) is GNU coreutils: on a host without it (macOS) the save is asked
# for without a limit rather than not at all.
limit() { if command -v timeout >/dev/null 2>&1; then timeout "$@"; else shift; "$@"; fi; }
flushed="flushed by RCON save"
if ! HUMANITZ_PROJECT="$PROJECT" limit 30 scripts/rcon.sh save 2>/dev/null | grep -q 'Game saved'; then
  flushed="NOT flushed (RCON save did not answer): the archive is of the last autosave"
fi

umask 077
mkdir -p "$BACKUP_DIR"
BACKUP_FILE="$BACKUP_DIR/humanitz-world-$(date +%Y%m%d-%H%M%S).tar.gz"
OUT="$(cd "$BACKUP_DIR" && pwd)"
NAME="$(basename "$BACKUP_FILE")"

# Written as .partial, by root (the settings file is the game user's, mode
# 600), then handed to the user running this, mode 600; renamed only if tar
# succeeded and the archive holds a world file.
if docker run --rm -v "$VOLUME":/data:ro -v "$OUT":/out -e OWNER="$(id -u):$(id -g)" alpine:3.20 sh -c \
     'cd "$1" || exit 1
      set -- "$2" Saved/SaveGames GameServerSettings.ini
      [ -f F_BannedPlayers.txt ] && set -- "$@" F_BannedPlayers.txt
      name="$1"; shift
      tar -czf "/out/$name.partial" "$@" && chown "$OWNER" "/out/$name.partial" && chmod 600 "/out/$name.partial"' \
     archive "$BASE" "$NAME"; then
  worlds="$(docker run --rm -v "$OUT":/out:ro alpine:3.20 tar -tzf "/out/$NAME.partial" 2>/dev/null | grep -cE "$WORLD_FILE")"
  if [ "${worlds:-0}" -lt 1 ]; then
    mv "${BACKUP_FILE}.partial" "${BACKUP_FILE}.failed" 2>/dev/null
    echo "$(date '+%F %T') FAILED: the archive holds no world file (Saved/SaveGames/SaveList/.../Save_*.sav), so it is not a backup of a world; see ${BACKUP_FILE}.failed" >&2
    exit 1
  fi
  bans="no ban list yet"
  docker run --rm -v "$OUT":/out:ro alpine:3.20 tar -tzf "/out/$NAME.partial" 2>/dev/null | grep -qx 'F_BannedPlayers.txt' && bans="the ban list"
  mv "${BACKUP_FILE}.partial" "$BACKUP_FILE"
  echo "$(date '+%F %T') backup OK: $BACKUP_FILE ($(du -h "$BACKUP_FILE" | cut -f1); $worlds world file(s), the settings, $bans; $flushed)"
else
  mv "${BACKUP_FILE}.partial" "${BACKUP_FILE}.failed" 2>/dev/null
  echo "$(date '+%F %T') backup FAILED: tar did not complete; see ${BACKUP_FILE}.failed" >&2
  exit 1
fi

# Retention: the newest KEEP finished archives stay. .partial and .failed
# files are never counted and never kept.
# shellcheck disable=SC2012  # the names are this script's own, fixed pattern; no user input reaches them
ls -1t "$BACKUP_DIR"/humanitz-world-*.tar.gz 2>/dev/null | tail -n +"$((KEEP + 1))" | while IFS= read -r old; do
  rm -f -- "$old"
done
find "$BACKUP_DIR" -name 'humanitz-world-*.tar.gz.partial' -mmin +60 -delete 2>/dev/null
exit 0
