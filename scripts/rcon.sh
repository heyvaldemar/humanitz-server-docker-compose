#!/bin/bash
# Talk to the HumanitZ server's RCON from the host.
#
#   scripts/rcon.sh info          name, uptime, "N connected.", season, players
#   scripts/rcon.sh players       one line per player, or "No players connected"
#   scripts/rcon.sh save          write the world now ("Game saved!")
#   scripts/rcon.sh "ban <id>"    ban a player; "kick <id>", "unban <id>" alike
#
# The client (scripts/rcon.py) runs inside the server's container, because
# RCON is published nowhere, and reads the password from the container's own
# environment, where compose put it. The host never handles it, and it appears
# in no process's argv.
#
# Exit codes: 0 answered, 1 the server is not running, 2 usage, 3 RCON
# unreachable, 4 authentication failed, 5 a command got no reply.
#   HUMANITZ_PROJECT   the compose project   (default humanitz)
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

[ "$#" -gt 0 ] || { echo "usage: scripts/rcon.sh <command> [command ...]" >&2; exit 2; }
PROJECT="${HUMANITZ_PROJECT:-humanitz}"

cid="$(docker compose -p "$PROJECT" ps -q --status running humanitz-server 2>/dev/null || true)"
[ -n "$cid" ] || { echo "the server is not running" >&2; exit 1; }

exec docker exec -i "$cid" python3 - "$@" < scripts/rcon.py
