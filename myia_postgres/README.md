# myia_postgres — MyIA customizations

Canonical home for all MyIA-specific PostgreSQL deployment tooling on myia-ai-01
(compose files, configs, operational scripts, docs). See root `CLAUDE.md` for the
agent charter and the bootstrap backlog. Refs: roo-extensions #2553 / EPIC #2191.

## Deployed state (since 2026-06-11)

| Item | Value |
|------|-------|
| Container | `postgres_production` (`docker-compose.production.yml`) |
| Image | `postgres:18-trixie` (18.4, pinned major — tracks `18/trixie/Dockerfile` of this fork) |
| Host port | **5433** (host 5432 is taken by `open-webui-postgres`); container 5432 |
| Network | default `bridge` (host address pools exhausted — no per-stack network possible) |
| Data | named volume `pg_unified_data` (resilience = dump + re-ingestion, store is a derived index) |
| DB / user | `unified_store` / `unified_store`, password in local `.env` (gitignored) |
| Schema | `001_init_unified_store.sql` applied (tables `conversations`, `messages` + GIN on `tool_calls`) |
| External | `pg.myia.io:5432` → NAT (owned by myia-po-2023) → ai-01:5433 — pending; TLS before exposure |

## Operations

```powershell
# Start / stop (data persists in the named volume)
docker compose -f docker-compose.production.yml --project-directory . up -d
docker compose -f docker-compose.production.yml --project-directory . down

# Health & logs
docker ps --filter name=postgres_production
docker logs -f postgres_production

# psql shell
docker exec -it postgres_production psql -U unified_store -d unified_store

# Apply a migration (from roo-state-manager, source of truth for the schema)
Get-Content d:\roo-extensions\mcps\internal\servers\roo-state-manager\migrations\001_init_unified_store.sql -Raw |
  docker exec -i postgres_production psql -U unified_store -d unified_store -v ON_ERROR_STOP=1
```

Client connection string (roo-state-manager on this host):
`postgresql://unified_store:<password>@localhost:5433/unified_store`

## Secrets

`.env` (here, gitignored) holds `POSTGRES_PASSWORD`. Never commit it; cross-machine
distribution goes through RooSync GDrive only. `.env.example` is the committed template.
