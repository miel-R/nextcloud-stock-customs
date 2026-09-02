<!--
SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
SPDX-License-Identifier: MIT
-->

# Contributing to nextcloud-stock-customs

This repository contains a **stock Nextcloud Docker stack** - compose files, config overrides and deployment docs built on stock/upstream images (`nextcloud:stable`, PostgreSQL, Redis, Caddy, optional Talk signaling + TURN). It is intentionally **not** Nextcloud AIO: no mastercontainer, no `nextcloud/aio-*` images, no AIO-specific patterns.

## Submitting issues

- Questions about Nextcloud itself belong on the [Nextcloud forum](https://help.nextcloud.com/).
- Report issues that are specific to this repository (compose files, config overrides, docs) here in the issue tracker.
- Security issues: report via the [Nextcloud HackerOne page](https://hackerone.com/nextcloud) following the [security policy](https://nextcloud.com/security/), not as public issues.

## Contributing changes

- Keep changes small and focused; one concern per pull request.
- Use [Conventional Commits](https://www.conventionalcommits.org): `<type>(<scope>): <short description>`.
- Add an `Assisted-by: AGENT_NAME:MODEL_VERSION` git trailer to commits that contain AI-assisted content.
- Only use stock/upstream images and pin versions (no `latest` unless already the repo convention).
- Validate compose changes with `docker compose config -q` and, where possible, against a live stack.
- Keep the docs in sync with the compose files (see `AGENTS.md` for the exact list).

## License headers

New files must carry the correct SPDX license header (AGPL-3.0-or-later for this repository). See the [Nextcloud license guide](https://github.com/nextcloud/server/blob/master/contribute/HowToApplyALicense.md) for per-language formats.