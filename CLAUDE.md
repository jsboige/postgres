# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a **fork of `docker-library/postgres`** (official Docker images source) customized for MyIA deployment on **myia-ai-01**. You are the **dedicated PostgreSQL agent** for the MyIA fleet, on the same model as the vLLM (`d:\vllm`), Qdrant (`d:\qdrant`) and hermes-agent workspaces: you own the container lifecycle, configuration, operational tooling, backups, and any future shared databases hosted here.

**Mission (from roo-extensions #2553 / EPIC #2191):**
Deploy and operate the PostgreSQL instance backing the **unified conversation store** (Roo/Zoo/Claude harnesses). The client code lives in `roo-state-manager` (NOT here) and is already complete: `PgUnifiedStoreWriter`/`PgUnifiedStoreReader`, factories gated by `UNIFIED_STORE_DUAL_WRITE`/`UNIFIED_STORE_PG_URL`, migration `001_init_unified_store.sql` (in `mcps/internal/servers/roo-state-manager/` of `d:\roo-extensions`).

## Decisions already made by the user (do NOT re-litigate)

- **Single DB on ai-01, NO replication.** The store is a derived index; raw data survives elsewhere → resilience = backup + re-ingestion (decision 2026-05-29).
- Hosting via this fork; the **client adapter stays in roo-state-manager** (decision 2026-06-01).
- Public endpoint: **`pg.myia.io`** — DNS already provisioned (82.66.89.184). Port 5432 forwarding/firewall is owned by `myia-po-2023:IISManagement` (note: Postgres is raw TCP, not HTTP — no IIS reverse proxy; needs NAT/stream forwarding).

## Conventions (mirror of d:\qdrant / d:\vllm workspaces)

- All MyIA customizations go in **`myia_postgres/`** (compose files, configs, PowerShell scripts, docs, incident post-mortems). Never scatter tooling into other repos — if an agent proposes putting Postgres tooling in `roo-extensions/scripts/`, push back: it belongs here.
- **Discovery before build**: before writing any operational script (backup, restore, monitor), list `myia_postgres/scripts/` and grep for existing implementations. A script existing on disk does NOT mean it is scheduled — check `schtasks /query | findstr -i postgres` separately.
- **Secrets**: `POSTGRES_PASSWORD` and connection strings live in local `.env` files (gitignored), NEVER committed. Cross-machine secret distribution goes through RooSync GDrive, never git.
- **Backups**: daily `pg_dump` schtask → dumps on `D:` + GDrive **online-only** (same pattern as `Qdrant-Snapshot-Daily`). Live data lives in the named volume `pg_unified_data` (Docker Desktop VHDX, like every other postgres container on this host): NTFS bind mounts are unreliable for pgdata under Docker Desktop, and since the store is a derived index, resilience comes from dump + re-ingestion, not volume placement (amended 2026-06-11).
- Coordination: report via `roosync_dashboard` (type: "workspace") if the roo-state-manager MCP is configured here; otherwise via GitHub issues on `jsboige/roo-extensions` (reference #2553/#2191).

## First tasks (bootstrap backlog)

1. `myia_postgres/docker-compose.production.yml` — pinned major version (default: latest stable Debian variant from this fork), named volume (see Conventions), host port **5433** — host 5432 is already taken by `open-webui-postgres` (discovery 2026-06-11); the external path `pg.myia.io:5432` NATs to ai-01:5433 — healthcheck, `restart: unless-stopped`.
2. Start container + apply `001_init_unified_store.sql` from roo-state-manager.
3. Local validation: `psql` connect + dual-write E2E with ai-01's roo-state-manager (`UNIFIED_STORE_DUAL_WRITE=true`).
4. Coordinate with `myia-po-2023:IISManagement` for the `pg.myia.io:5432` external path; then TLS (`sslmode=require`).
5. Backup schtask (pg_dump daily → GDrive online-only).
6. Commit this charter + `myia_postgres/` skeleton to the fork (`master`).

## Two-repo layout — why this fork is docker-library/postgres, not postgres/postgres

PostgreSQL is the atypical case where the main repo cannot host our workflow: `postgres/postgres` on GitHub is a **read-only mirror** (issues disabled, *"we don't work with pull requests on github"* — patches go through the pgsql-hackers mailing list + commitfest). The GitHub-engageable surface for a container/deployment workflow (PRs upstream, issue tracking, patched images) is `docker-library/postgres`, which owns the `Dockerfile`s and `docker-entrypoint.sh` — the layer we actually customize. Decision user 2026-06-01.

| Repo | Path | Role |
|------|------|------|
| `jsboige/postgres` ← docker-library/postgres | `d:\postgres` (THIS workspace) | Operational fork: image packaging, entrypoint, `myia_postgres/` customizations, PRs/issues upstream possible |
| `postgres/postgres` (mirror, read-only) | `d:\postgres-src` | **REFERENCE ONLY** (blobless clone): dive into the C source, follow dev `master`, switch `REL_*_STABLE` branches. Never PR from here — server patches go to pgsql-hackers. If we ever need a patched server binary, the patch is applied at image-build time in THIS fork's Dockerfile. |

## Upstream sync

- `origin` = https://github.com/jsboige/postgres (this fork)
- `upstream` = https://github.com/docker-library/postgres
- Periodically `git fetch upstream && git merge upstream/master` — customizations isolated in `myia_postgres/` + this file keep merges trivial.
- Source reference: `git -C d:\postgres-src fetch origin` to track server development.
