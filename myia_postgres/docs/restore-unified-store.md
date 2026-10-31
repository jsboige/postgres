# Restore procedure — unified_store (ai-01)

Validated by a live drill on **2026-10-31** (scratch container, prod untouched):
`pg_restore` of the GDrive daily dump exited 0 in **71.7 s**, restoring
**16 495 conversations / 7 407 030 messages / 9 tables** — matching the
poison-guard count logged at dump time to the row. Recipe below is the drill,
verbatim.

> Never restore into prod without an explicit user GO (skill pg-sweep §4).
> The store is a derived index: re-ingestion is the alternative recovery path
> (decision 2026-05-29). A restore is for point-in-time recovery of the index.

## Dump sources (both legs, newest first)

- GDrive offsite: `G:\Mon Drive\Backups-Cloud\postgres-backups\myia-ai-01\unified_store\<yyyy-MM-dd>\unified_store-<yyyyMMdd>.dump`
- USB local: `F:\Backups\postgres-backups\myia-ai-01\unified_store\<yyyy-MM-dd>\...` (leg added 2026-10-31)

Dumps are `pg_dump -Fc` (custom format, compressed, parallel-restore capable).

## Recipe (drill 2026-10-31, ~90 s end-to-end on ai-01)

```powershell
# 1. Hydrate the dump (GDrive is online-capable; ~14 s warm, minutes cold)
Copy-Item 'G:\Mon Drive\Backups-Cloud\postgres-backups\myia-ai-01\unified_store\2026-10-31\unified_store-20261031.dump' $env:TEMP\drill.dump -Force

# 2. Scratch container (no port needed; same image family as prod)
docker run -d --name pg-restore-drill -e POSTGRES_PASSWORD=drillpw postgres:18-trixie
# ...wait for: docker exec pg-restore-drill pg_isready -U postgres

# 3. Restore
docker cp $env:TEMP\drill.dump pg-restore-drill:/tmp/drill.dump
docker exec pg-restore-drill createdb -U postgres unified_store
docker exec pg-restore-drill pg_restore -U postgres -d unified_store -j 4 --no-owner /tmp/drill.dump

# 4. Verify against the backup log's poison-guard line (rows at dump time)
docker exec pg-restore-drill psql -U postgres -d unified_store -t -A -c "SELECT count(*) FROM conversations;"

# 5. Teardown
docker rm -f pg-restore-drill
```

## Restoring into PROD (`postgres_production`) — requires user GO

1. Stop writers first (fleet-side: `UNIFIED_STORE_DUAL_WRITE=0` or stop the MCP
   processes) — a restore under live dual-write re-diverges immediately.
2. `docker exec postgres_production dropdb -U unified_store-postgres...` — see
   `.env` for the superuser; then `createdb` + `pg_restore` as above, in-place.
3. The poison-guard floor (MinRows 15000) protects the NEXT backup from
   backing up a half-restored DB.
