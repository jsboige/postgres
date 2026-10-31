---
name: pg-sweep
description: Sweep de surveillance 12h de la lane myia-ai-01:postgres (store unifié de conversations, prod critique 9 machines) — container, DB vitals (staleness ingestion, poison floor 15k), backup du jour sur LES DEUX jambes (GDrive + USB F:), schtask, disques, endpoint pg.myia.io, inbox, puis synthèse [DONE] sur workspace-postgres et re-arm du cron. À invoquer à chaque cycle de veille (cron 12h, 07:23/19:23) ou manuellement via /pg-sweep.
---

# Sweep surveillance postgres (lane myia-ai-01:postgres)

Cadence : 12h (07:23 / 19:23). Durée typique ~3 min. Tout est en lecture, sauf les posts dashboard et le self-heal backup documenté ci-dessous. Ne JAMAIS échoer de secret (le mot de passe vient de `myia_postgres/.env`, utilisé en mémoire uniquement).

Contexte : le store est l'index unifié des conversations de TOUTE la flotte (9 machines écrivent ; ~16,5k conversations, ~7,4M messages, ~4,2 GB au 31/10/2026). Résilience = backup + ré-ingestion (décision user 2026-05-29 : pas de réplication).

## 1. Sondes locales (script canonique)

```powershell
& D:\postgres\myia_postgres\scripts\monitoring\pg_lane_sweep.ps1
```

Sorties attendues : `postgres_production | postgres:18-trixie | Up ... (healthy) | 0.0.0.0:5433->5432` · comptes non nuls · `ingest_staleness_h` faible · `ssl=on` · dump du jour présent sur les DEUX jambes · schtask Last Result = 0 · endpoints OPEN.

## 2. Jugement (seuils)

| Sonde | OK | WARN | ERROR |
|---|---|---|---|
| Container | Up (healthy) | Up (unhealthy) | Absent/Exited/Restarting |
| `ingest_staleness_h` | < 12 | 12–24 | > 24 (flotte muette = pipeline cassé) |
| `conversations` | ≥ 15 000 | 10 000–15 000 | < 10 000 → suspicion poison |
| Dump du jour (après ~04:00) | 2/2 jambes | 1/2 (dégradé) | 0/2 |
| Schtask Last Result | 0 | — | ≠ 0 |
| Log backup | finit « Backup done » | WARN de retry | « Backup INCOMPLETE » / s'arrête avant la fin |
| C: libre | > 100 GB | 50–100 GB | < 50 GB (VHDX docker_data ~663 GB sur C:) |
| F: (USB Desk SSD) | monté | absent → jambe locale morte | — |
| localhost:5433 | OPEN | — | fermé |
| pg.myia.io:5432 | OPEN | fermé (NAT/box) mais 5433 OK | les deux fermés |

`conversations` < poison floor → **[ASK] immédiat**, ne JAMAIS restaurer/dropper sans GO user explicite (chaîne complète : heure, count, dernier dump sain des deux jambes). Le poison-guard du backup (MinRows 15000) refuse déjà de sauvegarder une base écrasée.

## 3. Backup — check et self-heal

Le schtask `Postgres-Dump-Daily` (02:33/03:33 selon heure d'été, `StartWhenAvailable` → rattrape au réveil) lance `backup-pgdump.ps1` vers GDrive (`G:\Mon Drive\Backups-Cloud`) **et** USB (`F:\Backups\postgres-backups`). Retry borné 3×120 s par jambe ; une jambe en échec = exit 3 sans tuer l'autre (incident fondateur 30/10/2026 : copie GDrive morte → journée perdue, jambe unique).

**Self-heal autorisé** (dump du jour absent après ~04:00, ou log tronqué) — le script est idempotent :

```powershell
pwsh -NoProfile -File D:\postgres\myia_postgres\scripts\backup-pgdump.ps1 -LocalCopyDir 'F:\Backups\postgres-backups' -SharedPath 'G:\Mon Drive\Backups-Cloud' -MinRows 15000
```

Précédents : 12/06/2026 (SYSTEM ne voit pas G:, corrigé en principal interactif) ; 30/10/2024+10 (G: transient au réveil → retry). Si G: absent au self-heal : `-SharedPath '-'` pour au moins sécuriser la jambe USB, et inversement.

## 4. Gestes permis / interdits

- **Panne = réparation sans GO** (mandat user 28/10) : `docker start postgres_production`, `docker compose -f myia_postgres\docker-compose.production.yml up -d`, re-run backup. Prévenir sur le dashboard dans le même cycle.
- **Interdits sans GO user** : restore, drop/recreate DB ou volume, suppression de dumps, modification du schtask (une seule fenêtre UAC par lane, batchée).
- Restore = `pg_restore` d'un dump `-Fc` ; procédure de drill testée le 31/10/2026 (voir `myia_postgres/docs/`).

## 5. Inbox & dashboards

Inbox (`roosync_messages`) : vérifier les HIGH pour pertinence lane AVANT `bulk_mark_read` (mentions flotte ≠ lane). DM adressé à la lane → répondre (ACK). Le dashboard workspace (`workspace-postgres`) est le canal primaire : tout y passe ([INFO]/[WARN]/[ERROR]/[ASK]/[DONE]).

## 6. Clôture

1. Synthèse **[DONE]** sur workspace-postgres (condensation auto OK) : counts + staleness, état backup (2 jambes), disques, incidents/escalades en attente.
2. **Re-arm du cron** : `CronList` → si le cron `pg-sweep` 12h expire dans < 24 h (auto-expiration 7 j), `CronCreate` `"23 7,19 * * *"` recurring avec le prompt « Cycle surveillance Postgres 12h : invoque le skill pg-sweep, puis re-arme ce cron avant expiration ». Le cron d'une session interactive se ré-arme DANS la session, jamais via tâche planifiée Windows.
3. Escalades (règle user 14/07) : service dégradé même hors-lane → **[ERROR]/[WARN] + [ASK] + crossPost global**, router vers la lane propriétaire, ne pas remédier hors-lane.
