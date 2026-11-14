# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- **A comment in `scripts/rcon.py` no longer reads like a password to a secret scanner.** It named the override variable followed by the word "overrides", which a common literal-secret pattern (an rcon password name, a space, eight letters or more) takes for a value; a pre-commit scanner refused the file for someone copying it. Reworded; nothing else changed.

## [1.3.0] - 2026-11-14

### Security

- **No password in `docker compose logs`, now or after a LinuxGSM fix.** LinuxGSM's `details`, which the image runs after every start, prints the admin password it finds in the settings file. It looks for `AdminPassword`, a key HumanitZ does not use (the game's is `AdminPass`), so it prints "NOT SET" today; with that key there, the image's own entrypoint prints the value (`tests/e2e-start.sh`). `scripts/start.sh` now stays process 1 and runs the image's entrypoint behind a filter that masks the value on any line whose label says "pass", in any case, and of any `…Password=` setting.
- **CI looks for every password everywhere it could leak to.** `tests/secret-probe.sh` gives the join, admin and RCON passwords a value each and fails on any of them in `docker compose logs`, LinuxGSM's logs or the game's, a command line in the container or the host's `ps`, after the first start, while the backup runs, and after a restart; it names the place, never the value. Nothing was found, on v1.2.1 or with this release ([run 43617614774](https://github.com/heyvaldemar/humanitz-server-docker-compose/actions/runs/43617614774), [run 43618931688](https://github.com/heyvaldemar/humanitz-server-docker-compose/actions/runs/43618931688)). The CI step that wrote the passwords into `.env` no longer has them on `sed`'s command line.

- **`gameservermanagers/gameserver:hz` was rebuilt upstream**; the pin moved from `sha256:3c4737bb810d…` to `sha256:8a71842cd6bb…`. Same version, same tag, a rebuilt base image — the usual shape of a security fix in a base layer.

### Fixed

- **A stop saves the world.** LinuxGSM stops HumanitZ with Ctrl+C, and the game does not save on its way down. Measured on v1.2.1: the stop took 11 seconds of the two-minute grace period and exit 0, with no SIGKILL, and the world file was not written ([run 43617614774](https://github.com/heyvaldemar/humanitz-server-docker-compose/actions/runs/43617614774)), so every stop, restart and update lost whatever had happened since the last autosave, up to five minutes of it. The README said the world was written on the way down; that was not measured, and it was wrong. `scripts/start.sh` now asks the game over RCON to save on Docker's SIGTERM, waits up to 30 seconds for "Game saved!", then lets LinuxGSM stop it: 10 seconds, exit 0, "Game saved!", the world file written by the stop ([run 43618931688](https://github.com/heyvaldemar/humanitz-server-docker-compose/actions/runs/43618931688)). **Until you update, run `scripts/rcon.sh save` before a stop or restart.**
- **An index pushed again over the same build is no longer reported as drift.** The daily pin check compared each pin with the digest the tag's index has now and failed on any difference, so a publisher re-pushing the index over the very same images (a platform added, an attestation rewritten) turned it red for an image nobody rebuilt, and no pin would ever move to turn it green. It now also compares the linux/amd64 build under both digests, the one CI runs and proves: the same build passes with a notice naming both digests, a new build fails as drift exactly as before, and a build that cannot be read still fails.

## [1.2.1] - 2026-11-09

### Security

- **`gameservermanagers/gameserver:hz` was rebuilt upstream**; the pin moved from `sha256:4c737517a14a…` to `sha256:3c4737bb810d…`. Same version, same tag, a rebuilt base image — the usual shape of a security fix in a base layer.

### Changed

- **Helper containers take their values by name.** The backup and restore helpers were started with `-e OWNER=…`, `-e STAMP=…`, `-e FILE=…` and `-e BASE=…`, and the tests' volume helper with `-e BASE=…` and `-e WORLD=…`. None of them is a secret, but fleet conformance now flags any value expanded into `-e NAME=` (a name says nothing about what it carries), so each is set for that one command and passed as `-e NAME`. Nothing a deployment does changes.

## [1.2.0] - 2026-11-08

### Changed

- **The health check asks the game over RCON, not its process.** It looked for `HumanitZServer` in `/proc`, which a hung or stopped game keeps. `scripts/healthcheck.py`, mounted read-only, logs in to RCON on 127.0.0.1, asks `info` and is healthy only on the game's "N connected." line; every connect and read shares an 8-second deadline, inside Docker's 10. It runs every 30 seconds instead of 20, as each check is an RCON login. It asks from inside the container, so it does not prove the game port is published on the host or open in a firewall; the README says so. `tests/e2e-game.sh` stops the game with SIGSTOP and requires it red while the old check stays green, then green again after SIGCONT.
- **The Docker Engine 29.4.2 note links GitHub's runner-image issue and its fix.** [actions/runner-images#14790](https://github.com/actions/runner-images/issues/14790) is the ubuntu-26.04 image shipping that release; [actions/runner-images#15205](https://github.com/actions/runner-images/pull/15205) moves it to 29.7.2. Documentation only.
## [1.1.6] - 2026-11-08

### Fixed

- **CI boots the game again on GitHub's ubuntu-26.04 runner.** Since 2026-11-07 `ubuntu-latest` is that image, which ships Docker Engine 29.4.2, and that release alone answers the 32-bit `socketcall` system call with ENOSYS in its default seccomp profile ([moby/moby#52506](https://github.com/moby/moby/issues/52506)). SteamCMD could not get online: "!!! Fatal Error: Steamcmd needs to be online to update.", with Steam and the network both up. On 29.4.2, and only there, CI now gives the daemon the profile Docker 29.4.3 ships (moby/profiles seccomp v0.2.3, pinned by commit and checksum) before it starts the server; anywhere else the step does nothing. Measured on every affected template's pinned image in tf2-server-docker-compose run 42496129688.

### Changed

- **The README names Docker Engine 29.4.2.** That release alone stops SteamCMD, which this image runs to install and update the game: upgrade to 29.4.3 or later, which reverted the rule, or point the daemon's `seccomp-profile` at the profile 29.4.3 ships. Ubuntu 26.04's own `docker.io` (27.5.1) never had it.
## [1.1.5] - 2026-11-07

### Security

- **`gameservermanagers/gameserver:hz` was rebuilt upstream**; the pin moved from `sha256:73922a91b5cb…` to `sha256:4c737517a14a…`. Same version, same tag, a rebuilt base image — the usual shape of a security fix in a base layer.

## [1.1.4] - 2026-11-06

### Security

- **`gameservermanagers/gameserver:hz` was rebuilt upstream**; the pin moved from `sha256:e8e620852b17…` to `sha256:73922a91b5cb…`. Same version, same tag, a rebuilt base image — the usual shape of a security fix in a base layer.

## [1.1.3] - 2026-11-02

### Fixed

- **Steam's silence is tolerated, as v1.1.0 said it would be.** `scripts/refresh.sh` took Steam to be quiet when LinuxGSM's `check-update` printed a local build without a remote one. LinuxGSM never prints that: it prints "Local build" and "Remote build" together, after it has asked Steam, and when Steam gives no build it stops at `[ FAIL ] ... Checking remote build` and exits 1, printing neither (LinuxGSM v26.4.0 in the pinned image, run with SteamCMD answering nothing). The stand-in in `tests/e2e-decisions.sh` printed the local build alone, so the tests passed while a quiet Steam failed every real run at once with "could not read both builds". The failure line is now what says Steam is quiet, and the installed build comes from the app manifest, the file LinuxGSM reads it from. The stand-in prints what LinuxGSM prints; the released script fails 4 of its checks.

### Changed

- **The v1.1.2 note was wrong about LinuxGSM.** It said LinuxGSM prints the local build before it asks Steam, so a read cut off between the two looked like Steam's silence. LinuxGSM prints both after it asks; the window between them is two consecutive lines. What v1.1.2 did is still right, for a different reason: an exec that ends with 125 or more is Docker failing or the exec killed, and nothing it printed counts, now also not as the `Checking remote build` failure. Case 7d cuts the read while LinuxGSM is asking Steam.

## [1.1.2] - 2026-11-02

### Fixed

- **Docker cutting LinuxGSM's answer off is no longer taken for Steam going quiet.** LinuxGSM's `check-update` prints the local build before it asks Steam, so an exec cut off by a restart in between (exit 137 after the first line, measured on Docker 29.7.2) left the local build read and the remote one not. That is the shape of Steam's silence, which `scripts/refresh.sh` tolerates for three hours, so a Docker failure started the silence clock and exited 0. An exec that ends with 125 or more is now Docker failing, or the exec killed: nothing it printed is counted, no silence is noted, and the run exits 1 and says so. `tests/e2e-decisions.sh` case 7d plays the cut through a wrapper around the real `docker`; the released script fails it. On the server this template comes from, a chat bot read a Docker error on stdout as part of a game's log.

## [1.1.1] - 2026-10-31

### Security

- **`gameservermanagers/gameserver:hz` was rebuilt upstream**; the pin moved from `sha256:1a13882e08cb…` to `sha256:e8e620852b17…`. Same version, same tag, a rebuilt base image — the usual shape of a security fix in a base layer.

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

[Unreleased]: https://github.com/heyvaldemar/humanitz-server-docker-compose/compare/v1.3.0...HEAD
[1.3.0]: https://github.com/heyvaldemar/humanitz-server-docker-compose/compare/v1.2.1...v1.3.0
[1.2.1]: https://github.com/heyvaldemar/humanitz-server-docker-compose/compare/v1.2.0...v1.2.1
[1.2.0]: https://github.com/heyvaldemar/humanitz-server-docker-compose/compare/v1.1.6...v1.2.0
[1.1.6]: https://github.com/heyvaldemar/humanitz-server-docker-compose/compare/v1.1.5...v1.1.6
[1.1.5]: https://github.com/heyvaldemar/humanitz-server-docker-compose/compare/v1.1.4...v1.1.5
[1.1.4]: https://github.com/heyvaldemar/humanitz-server-docker-compose/compare/v1.1.3...v1.1.4
[1.1.3]: https://github.com/heyvaldemar/humanitz-server-docker-compose/compare/v1.1.2...v1.1.3
[1.1.2]: https://github.com/heyvaldemar/humanitz-server-docker-compose/compare/v1.1.1...v1.1.2
[1.1.1]: https://github.com/heyvaldemar/humanitz-server-docker-compose/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/heyvaldemar/humanitz-server-docker-compose/compare/v1.0.3...v1.1.0
[1.0.3]: https://github.com/heyvaldemar/humanitz-server-docker-compose/compare/v1.0.2...v1.0.3
[1.0.2]: https://github.com/heyvaldemar/humanitz-server-docker-compose/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/heyvaldemar/humanitz-server-docker-compose/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/heyvaldemar/humanitz-server-docker-compose/releases/tag/v1.0.0
