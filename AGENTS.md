<!--
  - SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
  - SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Agent Guidelines for nextcloud-stock-customs

This file provides instructions for AI coding agents (Claude Code, GitHub Copilot, Cursor, Windsurf, and others) operating on this repository. Read it before generating any code, commits, or pull requests.

---

## General rules

- Add an `Assisted-by: AGENT_NAME:MODEL_VERSION` git trailer to every commit containing AI-assisted content.
- Use [Conventional Commits](https://www.conventionalcommits.org) for all commit messages:

  ```
  <type>(<scope>): <short description>

  [optional body]

  Assisted-by: AGENT_NAME:MODEL_VERSION
  ```

- Produce focused, scoped changes that address exactly one concern. Do not touch unrelated files or introduce incidental refactors.
- Verify all dependencies (image names, tags, package names) against the actual registries before using them. Do not use hallucinated or unverified names.
- Never add `Signed-off-by` tags to commits. Only the human contributor can certify the Developer Certificate of Origin.
- Do not open issues, submit pull requests, post review comments, or send security reports autonomously. Every contribution must be reviewed and submitted by a human.

## Repository scope

This repository is a **stock Nextcloud Docker stack** (`nextcloud:stable` behind Caddy, with PostgreSQL + Redis and optional Talk). It is NOT Nextcloud AIO:

- It deliberately uses only stock/upstream images (e.g. `nextcloud:stable`, `postgres:16-alpine`, `strukturag/nextcloud-spreed-signaling`, `eturnal/eturnal`).
- There is no AIO mastercontainer, no AIO image (`nextcloud/aio-*`), and no AIO-specific setup docs.
- Keep it that way: do not reintroduce AIO images, AIO docs, or AIO-specific patterns (e.g. `Containers/<name>` builds, `AIO_*` env vars, `nextcloud-aio-*` container names).

## Validation before submitting

- Run `docker compose config -q` after any compose change.
- When possible, validate changes against a live stack and document the commands used.
- Keep documentation in sync with the actual compose files. If you touch `compose.yaml`, update `readme.md`, `INSTALL.md`, `NETWORKING.md`, `DATABASE.md` and `.env.example` as needed.
- Standard image updates belong in `compose.yaml` and the docs as plain tag bumps - do not invent custom build pipelines.