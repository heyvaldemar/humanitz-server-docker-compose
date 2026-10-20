# Security Policy

## Supported versions

| Version                                        | Status             |
|------------------------------------------------|--------------------|
| Current `main` and the latest tagged release   | :white_check_mark: |
| Older tags without a recent rebuild            | :x:                |

Fixes land on `main` and ship as a new tag; older tags are not patched in place.

## Reporting a vulnerability

Report privately by email to v@valdemar.ai. The process is described at [heyvaldemar.com/security](https://heyvaldemar.com/security/).

You can expect an acknowledgment within 7 days. This project does not operate a bounty program; researchers who submit valid, responsibly disclosed reports receive public credit in the release notes and the changelog.

Please do not open public GitHub issues for security reports.

## Supply chain trust

This repository publishes a deployment template, not a custom software distribution. The upstream image is pinned by `tag@sha256:<digest>` as an interpolation default in the compose file's `x-images` block, so a plain `git pull` delivers the exact combination this repository has tested. The Pin Freshness workflow re-resolves the pin daily and fails when it has drifted; the Deployment Verification workflow scans the pinned image, runs the decision and backup-restore tests against stand-ins, and installs and boots the real game from an empty volume on every change and every day. Either one notifies the maintainer. GitHub Actions are pinned by commit SHA.

The game itself is downloaded from Steam inside the container and is not pinned here: a server behind Steam's build cannot be joined.

## Credentials

`.env` is gitignored, and the two required passwords (admin and RCON) fail fast at deploy time when they are missing. RCON is published on no port: every script reaches it from inside the container, and the password reaches the RCON client through the container's environment, never a command line. Backup archives hold the server's settings, passwords included, and are written readable by their owner only. This repository has never tracked a credential.
