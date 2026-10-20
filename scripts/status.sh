#!/bin/bash
# The server's state, as one line of JSON a monitor or a status page can read.
#
#   scripts/status.sh
#   {"status": "Online", "players": 0, "max": 16, "season": "Summer", "checked": 1792461911}
#
# WHY RCON. Monitors usually ask a game server over the Steam query (A2S).
# HumanitZ does not answer it: it advertises itself through Epic Online
# Services. Measured on a CI runner against this template's image, the query
# port and the game port both timed out with the server up and RCON answering.
# RCON is the only source of truth, and it lives inside the container, so the
# JSON is made there (scripts/rcon.py --status).
#
# UNKNOWN IS NOT ZERO. When RCON does not answer, or the server is not running,
# the status is "Unknown", players is null, and this exits 1. "Online, nobody
# playing" is a claim, and a dead probe must not be able to make it. Whoever
# reads the JSON later should treat a "checked" older than a few minutes the
# same way: a writer that has stopped is not a server with nobody on it.
#
#   HUMANITZ_PROJECT   the compose project   (default humanitz)
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
PROJECT="${HUMANITZ_PROJECT:-humanitz}"

cid="$(docker compose -p "$PROJECT" ps -q --status running humanitz-server 2>/dev/null || true)"
if [ -z "$cid" ]; then
  printf '{"status": "Unknown", "players": null, "max": null, "season": null, "checked": %s}\n' "$(date +%s)"
  exit 1
fi
exec docker exec -i "$cid" python3 - --status < scripts/rcon.py
