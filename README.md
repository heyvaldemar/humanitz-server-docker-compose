# HumanitZ dedicated server using Docker Compose

[![Deployment Verification](https://github.com/heyvaldemar/humanitz-server-docker-compose/actions/workflows/deployment-verification.yml/badge.svg?branch=main)](https://github.com/heyvaldemar/humanitz-server-docker-compose/actions/workflows/deployment-verification.yml)
[![OpenSSF Best Practices](https://www.bestpractices.dev/projects/15716/badge)](https://www.bestpractices.dev/projects/15716)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

A HumanitZ dedicated server answers no Steam query, so every tool that asks "is it up, who is on" the usual way hears silence, and most of them read silence as an empty server. This template asks over RCON instead, from inside the container, and treats an answer it did not get as "unknown", never as zero: the status, the player count, the update that waits for an empty server, and the save before every backup.

It runs LinuxGSM's image, pinned by digest, with the game (Steam app 2728330, the native Linux branch) downloaded into a volume on the first start. CI installs and boots the real game from an empty volume on every change and every day.

```bash
git clone https://github.com/heyvaldemar/humanitz-server-docker-compose
cd humanitz-server-docker-compose
cp .env.example .env && $EDITOR .env          # two passwords, a server name
docker volume create humanitz-server-data     # the game and the world, see "the volume" below
docker compose -f humanitz-server-docker-compose.yml -p humanitz up -d
```

The first start downloads the game, 1.4 GB, then starts the server; on a CI runner the whole install took 78 seconds. Watch it:

```bash
docker compose -p humanitz logs -f humanitz-server
scripts/status.sh      # {"status": "Online", "players": 0, "max": 16, ...} once RCON answers
```

Players find it with the game's own words, not the host guides': JOIN, then the **IP CONNECT** box at the bottom right takes `host:port` (the game port), or **Search server name** under FILTERS finds it in the list. Guides call this "Direct Connect", a label the game never shows.

## What this file knows that a fresh one does not

**A hostname works for joining.** HumanitZ runs Unreal's stock IpNetDriver, which resolves names, so `your.hostname:7777` in IP CONNECT joins as well as the address does. On the machine this template comes from, a join by name was proven with a capture on the relay, the client's packets arriving over the internet path, and "Join succeeded" in the server log. Not every game built on Unreal does this: VEIN, which runs over Steam's socket layer, joins by IP address only.

**The mode belongs in the name.** PvP is one switch for the whole server, not a choice a player makes, so a player learns whether they can be shot only from the server's name. Put it there (`HUMANITZ_SERVER_NAME=My Server | PvP`); the `|` is safe, `scripts/start.sh` quotes the name where LinuxGSM pastes it into a shell.

**HumanitZ answers no Steam query.** It advertises itself through Epic Online Services. On a CI runner, with the server up and RCON answering, the Steam query to the query port and to the game port both timed out; on the machine this template comes from, six minutes of queries from the LAN, from a relay and from inside the container got no reply either. Monitors that speak A2S see a dead server, and anything that counts players that way counts nothing. RCON is the one source of truth, and `tests/e2e-game.sh` fails the day the query starts answering, because the reason for all of this would be gone.

**An unknown player count is not zero.** `scripts/status.sh` prints `"status": "Unknown", "players": null` and exits 1 when RCON does not answer, never `"Online"` with 0. `scripts/refresh.sh` treats an unknown count like a full server: it waits and exits 1. On the machine this template comes from, an update roll that read "cannot count" as zero had three game stacks reading as empty whatever was happening on them. A status file read later has the same trap: a writer that stopped is not a server with nobody on it, so whoever reads the JSON should treat a `checked` older than a few minutes as unknown. That status page once showed a healthy server as offline for another reason: RCON answers in CRLF, and the stray `\r` broke the JSON it was pasted into. `scripts/rcon.py` removes it once, for every caller, and the JSON is built by an encoder.

**LinuxGSM's own hourly update is off, on purpose.** With the image's default (`UPDATE_CHECK=60`) its entrypoint installs a cron job that runs `hzserver update` every hour, and an update restarts the server. LinuxGSM only holds a restart for players if `stoponlyifnoplayers` is turned on, and even then it counts them over the Steam query; when the count cannot be read, its own source says it will "Fail open (proceed as if empty)". For HumanitZ that is every time. Under this template's `no-new-privileges` that cron job would never install anyway: crontab is setgid, the hardening ignores the bit, and the install fails with "mkstemp: Permission denied" while the entrypoint carries on. Off by accident is one image change from on, so the compose file sets `UPDATE_CHECK: "0"` by decision, and updates come from `scripts/refresh.sh`, which counts over RCON. `tests/e2e-game.sh` shows the install failing under the hardening and working without it, against the pinned image.

**A start does not wait for npm's registry.** The image's entrypoint runs `npm install` on every start, and npm sends an audit request to its registry even when nothing needs installing. On the machine this template comes from, the night the registry did not answer, a server on the same LinuxGSM image waited npm's default five minutes with the game down, and a start took twenty. The compose file turns the audit off and bounds the rest (`NPM_CONFIG_*`); a start there took twenty-five seconds after that. Against a registry that accepts the connection and never answers, the same `npm install` finishes in a second with those settings and is still waiting at ninety without them.

**Settings are written before the first start, not after.** LinuxGSM installs the game only into an empty directory, so nothing can be put there beforehand, and the game writes no `GameServerSettings.ini` of its own while one is present. `scripts/start.sh`, the container's entrypoint, installs on the first start, then writes the `[Host Settings]` that `.env` owns (name, passwords, slots, RCON) and hands over to the image's entrypoint. Measured on a CI runner: a file written this way was kept unchanged and used on the first start and after a restart. Every other key is left as you set it; `REF_GameServerSettings.ini` beside it explains them all.

**RCON is published on no port.** It can ban, kick and save, and its password should not be the only thing in front of it. Every script reaches it from inside the container with `docker exec`, and the RCON client reads the password from the container's own environment, so it never appears on a command line, the host's or docker's.

**The ban list is part of the world.** `F_BannedPlayers.txt` is what RCON `ban` writes. A restore that brings back the world and not the list quietly lets every banned player back in, so `scripts/backup.sh` archives it with the world and the settings, and `scripts/restore.sh` puts it back and says so.

**The ports are published under the numbers the server binds.** The server is told both ports and advertises them itself. Map one number on the host to another in the container and players are pointed at a port nobody can reach. `HUMANITZ_SERVER_PORT` and `HUMANITZ_SERVER_QUERY_PORT` move both sides at once.

**The volume is external, so `docker compose down -v` cannot delete the world.** `down -v` is the command everyone reaches for when a stack misbehaves. On a project-managed volume it removes the world without asking. Creating the volume by hand once is the price of not losing it by accident.

**Two minutes to stop.** LinuxGSM stops the server with Ctrl+C and the world is written on the way down; Docker's default ten seconds would cut that off.

## Backups

```bash
scripts/backup.sh                     # the world, the settings and the ban list into ./backups
scripts/restore.sh backups/humanitz-world-20261020-043500.tar.gz
```

`scripts/backup.sh` asks the server to save first (RCON `save`, which writes the world the same second) and archives `Saved/SaveGames`, `GameServerSettings.ini` and `F_BannedPlayers.txt`, not the 1.4 GB of game files Steam can hand back. If the save cannot be asked for, the archive is still taken, of the last autosave, and the line says it was not flushed. The archive is written as `.partial` and renamed only once it is shown to hold a world file, and it is readable by its owner alone, because the settings hold passwords. Run it from cron; `HUMANITZ_BACKUP_DIR` says where archives go, `HUMANITZ_BACKUP_KEEP` how many stay.

`scripts/restore.sh` refuses while the server is running, refuses an archive that is not a HumanitZ world, moves what the volume holds aside to `HumanitZServer/before-restore-<time>/` instead of overwriting it, and fails if any file did not land at its live path. The settings come back as they were at the backup; the next start writes the `[Host Settings]` from `.env` again.

## Updating

**The game:** `scripts/refresh.sh`, from cron or a timer, every hour or so. It reads the installed and the remote build from LinuxGSM's `check-update` and does nothing while they match. When the server is behind, it restarts it, which makes LinuxGSM fetch the new build on start, only if RCON says nobody is on, after a backup, and then checks that the installed build is Steam's. `--check` reports without changing anything, `--dry-run` goes as far as deciding, `--force` restarts with players on or with the count unknown.

**The template:** the image pin lives in the `x-images` block at the top of the compose file, as an interpolation default, so a `git pull` delivers the version this repository has tested. The daily freshness check goes red when the `hz` tag has moved on. `./update.sh` moves to the latest release tag on purpose: it refuses to cross a major version unattended, refuses to run over local changes, and names any new required variable before anything has moved.

## Day to day

```bash
scripts/status.sh                     # one line of JSON for a monitor
scripts/rcon.sh players               # who is on
scripts/rcon.sh "ban 7656119xxxxxxxxxx"
scripts/rcon.sh save
```

## Testing

On every change and every day, in CI:

- `tests/e2e-game.sh` installs and starts the real server from an empty volume through this compose file, and then checks: the name and slot count from `.env` in RCON's answer; `scripts/status.sh` Online with 0 players; the Steam query silent; nothing answering on the host's RCON port; no LinuxGSM update cron; `refresh.sh --check` reading both builds; an RCON ban written to the ban list; a backup flushed by RCON that holds the ban list; a restore that puts every file of the archive back byte for byte, after which the server starts with the world and the ban; and the health check green with the game running and red with the game killed inside a container that keeps running.
- `tests/e2e-decisions.sh`: fourteen decisions of the refresh and the status against a stand-in that answers RCON the way HumanitZ does, in CRLF, with players, with nobody, or not at all. With "cannot count" read as zero instead, the silent cases go ahead and fail.
- `tests/e2e-npm.sh`: npm against a registry that accepts every connection and never answers, with the module LinuxGSM installs. The compose file's settings, read from the compose file, finish in seconds; npm's defaults are still waiting at ninety.
- `tests/e2e-backup-restore.sh`: a world, its settings and its ban list out and back in, by path and by byte, the archive mode 600, the refusals, and the contrast: the same archive extracted at the volume's root leaves no world where the server looks. With the ban list left out of the backup, four assertions fail.

CI also lints the shell and the workflows, scans the pinned image with Trivy, and checks daily that the pin still resolves to what upstream publishes.

## Supply chain trust

| Image | Source | Pinned |
|---|---|---|
| `gameservermanagers/gameserver:hz` | [LinuxGSM](https://github.com/GameServerManagers/docker-gameserver), MIT | tag and digest, in the compose file |
| `python:3.13-alpine`, `alpine:3.20` | Docker Official Images | by tag, for the tests and the scripts' throwaway containers |

The game itself is Steam app 2728330, branch `linuxbranch`, downloaded anonymously by SteamCMD inside the container.

---

## About the maintainer

<div align="center">

**Maintained by [Vladimir Mikhalev](https://github.com/heyvaldemar)** · Docker Captain · CNCF Ambassador · IBM Champion · AWS Community Builder

[YouTube](https://www.youtube.com/channel/UCf85kQ0u1sYTTTyKVpxrlyQ?sub_confirmation=1) · [Blog](https://heyvaldemar.com) · [LinkedIn](https://www.linkedin.com/in/heyvaldemar/)

</div>
