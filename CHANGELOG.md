# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

_(no unreleased changes yet)_

## [1.0.0] - 2026-10-20

### Added

- **A HumanitZ dedicated server**, LinuxGSM's `gameservermanagers/gameserver:hz` pinned by digest, with the game (Steam app 2728330, native Linux branch) installed into an external volume on the first start: 1.4 GB, 78 seconds on a CI runner. Ports published under the numbers the server binds, never translated. `no-new-privileges`, a memory ceiling with no swap on top, two minutes to stop.
- **Status, player count and updates over RCON**, because HumanitZ answers no Steam query (measured on a CI runner: the query port and the game port both timed out with RCON answering). `scripts/rcon.sh` runs the client inside the container, and RCON is published on no port. `scripts/status.sh` prints one line of JSON, "Unknown" with players null when RCON does not answer, never "Online" with 0.
- **LinuxGSM's hourly update turned off** (`UPDATE_CHECK=0`). Its default restarts the server whoever is on: LinuxGSM can count players only over the Steam query, and "fails open" when it cannot. `scripts/refresh.sh` restarts only an empty server that is behind, with players counted over RCON and an unknown count treated as occupied.
- **Settings written before every start** by `scripts/start.sh`, the container's entrypoint: install on the first start, then the `[Host Settings]` from `.env` into `GameServerSettings.ini`, then the image's own entrypoint. The game keeps the file (measured on a CI runner).
- **Backups that flush the world and keep the ban list**: RCON `save` first, then `Saved/SaveGames`, `GameServerSettings.ini` and `F_BannedPlayers.txt`, written as `.partial`, read back, renamed, mode 600. `scripts/restore.sh` puts all three back at their live paths and checks every file landed.
- **Tests**: `tests/e2e-game.sh` against the real server from an empty volume (16 checks, installed and answering RCON in under two minutes on a CI runner); `tests/e2e-decisions.sh` (14 checks, against a stand-in RCON that answers in CRLF); `tests/e2e-backup-restore.sh` (16 checks). Each shown its failure: with an unknown count read as zero, the silent refresh cases go ahead (2 fail); with the ban list left out of the backup, 4 fail.
- `update.sh`, Pin Freshness, Trivy, signed release assets, Scorecard, Dependabot.

### Found while building it

- **The world file is `Save_DedicatedSave.sav` with this template's settings**, not the `Save_DedicatedSaveMP.sav` the source server writes under other settings. The first real-server run failed its post-restore check on that name; the scripts already matched any `Save_*.sav`, which is why the byte-for-byte restore itself had passed.
- **A crontab check that could pass for the wrong reason.** The first version passed on any answer without LinuxGSM's update line, an empty one from a failed `docker exec` included. Only "no crontab for linuxgsm", or a crontab read cleanly without that line, passes now.

[Unreleased]: https://github.com/heyvaldemar/humanitz-server-docker-compose/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/heyvaldemar/humanitz-server-docker-compose/releases/tag/v1.0.0
