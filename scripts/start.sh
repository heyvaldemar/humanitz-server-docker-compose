#!/bin/bash
# The container's entrypoint: install on the first start, write the settings
# this .env owns, then run the image's own entrypoint, its output behind a
# filter that keeps passwords out of the logs (the end of this file).
#
# WHY A WRAPPER. LinuxGSM installs the game only into an empty serverfiles
# directory, so a settings file cannot be put there before the first start; and
# HumanitZ writes no GameServerSettings.ini of its own while one is there.
# Measured on a CI runner against this image: after `auto-install` the
# directory holds only REF_GameServerSettings.ini (every key, commented); a
# GameServerSettings.ini written next to it was kept unchanged and used, slot
# count and RCON included, on the first start and after a restart.
#
# WHAT IS WRITTEN, EVERY START:
#   GameServerSettings.ini, [Host Settings]: ServerName, Password, AdminPass,
#     MaxPlayers, RCONEnabled, RConPort, RCONPass. Every other key in the file
#     is left as it is; edit those in the volume (the REF_ file explains them).
#   LinuxGSM's instance config, hzserver.cfg: the two ports and the name the
#     server announces. Rewritten whole: .env is where they live.
#
# Runs as root, as the image's entrypoint does; the files go to the image's
# user, uid 1000.
set -euo pipefail

SERVERFILES=/data/serverfiles
GAMEDIR="$SERVERFILES/HumanitZServer"
INI="$GAMEDIR/GameServerSettings.ini"
LGSM_CFG=/data/config-lgsm/hzserver/hzserver.cfg

name="${HUMANITZ_SERVER_NAME:-HumanitZ Server}"
port="${HUMANITZ_SERVER_PORT:-7777}"
qport="${HUMANITZ_SERVER_QUERY_PORT:-27015}"
slots="${HUMANITZ_MAX_PLAYERS:-16}"

# A name is pasted into a shell line by LinuxGSM and into an ini by this
# script: refuse what either would read as syntax rather than guess.
bad='["$`\\]'
if [ -z "$name" ] || [[ "$name" =~ $bad ]]; then
  echo "HUMANITZ_SERVER_NAME may not be empty or contain a double quote, a dollar sign, a backtick or a backslash" >&2
  exit 1
fi
for v in port qport slots; do
  case "${!v}" in ''|*[!0-9]*) echo "$v must be a number, got '${!v}'" >&2; exit 1 ;; esac
done
for v in HUMANITZ_ADMIN_PASSWORD HUMANITZ_RCON_PASSWORD; do
  if [ -z "${!v:-}" ]; then echo "$v is required" >&2; exit 1; fi
done

if [ -z "$(ls -A -- "$SERVERFILES" 2>/dev/null)" ]; then
  echo "start.sh: the game is not installed yet; installing it first"
  /app/entrypoint.sh auto-install
fi
if [ ! -d "$GAMEDIR" ]; then
  echo "start.sh: no $GAMEDIR after the install; nothing to configure" >&2
  exit 1
fi

# The [Host Settings] keys this .env owns, set in place; the rest of the file
# is kept. Values reach Python through the environment, never the argv.
SETTINGS_FILE="$INI" python3 - <<'PY'
import os

path = os.environ["SETTINGS_FILE"]
want = {
    "ServerName": '"%s"' % os.environ.get("HUMANITZ_SERVER_NAME", "HumanitZ Server"),
    "Password": os.environ.get("HUMANITZ_SERVER_PASSWORD", ""),
    "AdminPass": os.environ["HUMANITZ_ADMIN_PASSWORD"],
    "MaxPlayers": os.environ.get("HUMANITZ_MAX_PLAYERS", "16"),
    "RCONEnabled": "true",
    "RConPort": "8888",
    "RCONPass": os.environ["HUMANITZ_RCON_PASSWORD"],
}
lines = open(path, encoding="utf-8").read().splitlines() if os.path.exists(path) else []
if "[Host Settings]" not in (l.strip() for l in lines):
    lines = ["[Host Settings]"] + lines
out, section, done = [], None, set()
for line in lines:
    stripped = line.strip()
    if stripped.startswith("[") and stripped.endswith("]"):
        if section == "[Host Settings]":
            out += ["%s=%s" % (k, v) for k, v in want.items() if k not in done]
            done.update(want)
        section = stripped
        out.append(line)
        continue
    key = stripped.split("=", 1)[0].strip() if "=" in stripped else None
    if section == "[Host Settings]" and key in want:
        out.append("%s=%s" % (key, want[key]))
        done.add(key)
        continue
    out.append(line)
if section == "[Host Settings]":
    out += ["%s=%s" % (k, v) for k, v in want.items() if k not in done]
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    f.write("\n".join(out) + "\n")
os.replace(tmp, path)
PY

mkdir -p "$(dirname "$LGSM_CFG")"
cat >"$LGSM_CFG" <<EOF
# Written by scripts/start.sh on every start, from .env. Edit .env, not this.
port="$port"
queryport="$qport"
servername="$name"
# Quoted, because LinuxGSM pastes this line into a shell: unquoted, a space in
# the name would split it.
startparameters="-log -port=\${port} -queryport=\${queryport} -steamservername=\"\${servername}\""
stats="off"
EOF
chown 1000:1000 "$INI" "$LGSM_CFG"
chmod 600 "$INI"
echo "start.sh: settings written: \"$name\", $slots slots, ports $port/udp and $qport/udp, RCON inside the container only"

# THE IMAGE'S ENTRYPOINT RUNS AS A CHILD OF THIS SCRIPT, which stays process
# 1, so that what it prints passes a filter on its way to `docker compose
# logs`. LinuxGSM's `details`, which the image runs after every start, prints
# the passwords it finds in the settings file in clear ("Admin password:").
# Today it looks for a key HumanitZ does not use (AdminPassword; the game's is
# AdminPass) and prints "NOT SET"; one LinuxGSM fix away, it would print the
# admin password on every start. On a line whose label says "pass", in any
# case, the value is masked, and so is the value of any setting whose name
# says it; an empty value and "NOT SET" stay as they are.
#
# A STOP SAVES THE WORLD FIRST. LinuxGSM stops HumanitZ with Ctrl+C, and the
# game does not save on its way down: measured in CI, a stop took 11 seconds
# and exit 0, and the world file was not written (its time the same before
# and after the stop, run 43617612417), so whatever happened since the last
# autosave (300 seconds by default) was lost on every stop, restart and
# update. On Docker's SIGTERM (or INT) this asks the game to save over RCON,
# from inside the container with the password from its own environment
# (scripts/rcon.py, mounted read-only), and waits up to 30 seconds for the
# game's "Game saved"; then it hands the signal to the image's entrypoint,
# which runs `hzserver stop` as it always has. When that is done, the image's
# tail of the log files, which nothing else ends, is stopped (the kernel kills
# everything left in a container the moment process 1 exits), the filter is
# given the last lines, and this exits with the entrypoint's status.
set +e
filter() {
  exec sed -u -E \
    -e '/^[^:=]*pass[^:=]*:[[:space:]]*(NOT SET)?[[:space:]]*$/Ib' \
    -e 's/^([^:=]*pass[^:=]*:[[:space:]]*)[^[:space:]].*$/\1********/I' \
    -e 's/(pass[a-z_]*[[:space:]]*=[[:space:]]*"?)[^[:space:]"?&]+/\1********/Ig'
}
exec 4> >(filter)
fpid=$!
# Its own process: bash starts a background job with INT and QUIT ignored,
# and the image's handler for them needs them back.
( trap - INT QUIT; exec /bin/bash /app/entrypoint.sh "$@" ) >&4 2>&1 4>&- &
child=$!
exec 4>&-
saved=0
# shellcheck disable=SC2329   # run by the traps below
save_then() {  # signal: save the world once, then hand the signal on
  local reply
  if [ "$saved" = 0 ]; then
    saved=1
    reply=$(timeout 30 python3 /opt/humanitz/rcon.py save 2>&1 | tr -d '\r' | grep -m1 'Game saved')
    if [ -n "$reply" ]; then
      echo "start.sh: stopping: the game answered \"$reply\" to RCON save; LinuxGSM stops it now"
    else
      echo "start.sh: stopping: RCON save got no \"Game saved\" within 30 seconds (still starting, or hung); the world is as of the last autosave"
    fi
  fi
  kill -"$1" "$child" 2>/dev/null
}
trap 'save_then TERM' TERM
trap 'save_then INT' INT
trap 'kill -QUIT "$child" 2>/dev/null' QUIT
while kill -0 "$child" 2>/dev/null; do wait "$child"; done
wait "$child"; rc=$?
# What still holds the filter's pipe: the image's tail of the log files and
# the shell that waits for it. The server itself is stopped by now.
for p in /proc/[0-9]*; do
  p=${p#/proc/}
  [ "$p" = "$$" ] || [ "$p" = "$fpid" ] || kill -KILL "$p" 2>/dev/null
done
for _ in $(seq 1 50); do kill -0 "$fpid" 2>/dev/null || break; sleep 0.1; done
exit "$rc"
