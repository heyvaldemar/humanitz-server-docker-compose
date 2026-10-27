# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

_(no unreleased changes yet)_

## [1.1.0] - 2026-10-27

### Changed

- **`scripts/refresh.sh` tolerates Steam's silence for three hours, not for a number of runs.** When Steam did not say which build it ships, the script exited 1 on every run. On the machine this template comes from, Steam stopped answering SteamCMD's build query for about five hours while nothing on the host was wrong; its monitoring tolerated "three failures in a row", written for one caller every three hours, and a second caller landed three strikes in 67 minutes and reported the host down. The script now notes when Steam went quiet in `.humanitz-refresh-steam-silent` and exits 0 until it has been quiet for `HUMANITZ_REFRESH_STEAM_TOLERANCE` seconds (10800), however often it runs in between, then exits 1; the first answer from Steam starts the span over. An installed build that cannot be read still exits 1 at once. A start time in the future is re-anchored to now, a silence that cannot be recorded is not tolerated, and a symlink in place of the file is refused. `tests/e2e-decisions.sh` shows the four cases.

## [1.0.3] - 2026-10-25

### Fixed

- **A start no longer waits for npm's registry.** The image's entrypoint runs `npm install` on every start, and npm sends its audit request to the registry even when nothing needs installing. On the machine this template comes from, the night the registry did not answer, a server on the same LinuxGSM image waited npm's default five minutes, and a start took twenty. The compose file now sets `NPM_CONFIG_AUDIT=false` and bounds the rest (`NPM_CONFIG_*`: no fund or update notice, cached metadata first, thirty seconds, one retry). Against a registry that accepts every connection and never answers, `npm install` finishes in a second with these settings and is still waiting at ninety without them; `tests/e2e-npm.sh` measures both on every run.

## [1.0.2] - 2026-10-24

### Security

- **`gameservermanagers/gameserver:hz` was rebuilt upstream**; the pin moved from `sha256:ba7448ed53a6…` to `sha256:1a13882e08cb…`. Same version, same tag, a rebuilt base image — the usual shape of a security fix in a base layer.

## [1.0.1] - 2026-10-20

### Fixed

- **The README says why LinuxGSM's hourly update was never running, as well as why it is off.** Under this template's `no-new-privileges` the image's entrypoint cannot install that cron job at all: crontab is setgid, the hardening ignores the bit, and the install fails with "mkstemp: Permission denied" while the entrypoint carries on. v1.0.0 described only the restart it would cause. `UPDATE_CHECK: "0"` keeps it off by decision, the day either side changes. `tests/e2e-game.sh` now shows the install failing under the hardening and working without it, against the pinned image (17 checks).

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

[Unreleased]: https://github.com/heyvaldemar/humanitz-server-docker-compose/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/heyvaldemar/humanitz-server-docker-compose/compare/v1.0.3...v1.1.0
[1.0.3]: https://github.com/heyvaldemar/humanitz-server-docker-compose/compare/v1.0.2...v1.0.3
[1.0.2]: https://github.com/heyvaldemar/humanitz-server-docker-compose/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/heyvaldemar/humanitz-server-docker-compose/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/heyvaldemar/humanitz-server-docker-compose/releases/tag/v1.0.0
