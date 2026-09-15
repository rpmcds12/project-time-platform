# Pulse DEV Azure environment

Scripts in this directory provision the single-region, scale-to-zero DEV
environment defined in
[`docs/adr/0001-single-region-scale-to-zero-aca-topology-for-dev-environment.md`](../../../docs/adr/0001-single-region-scale-to-zero-aca-topology-for-dev-environment.md):
a resource group, an Azure Container Apps (ACA) environment, a PostgreSQL
Flexible Server (Burstable B1ms), and a Basic-tier Azure Container Registry
(ACR) — nothing else. `dev01`-`dev04` deploy no application code.

`dev05` and `dev06` (Stage 2) build on that infrastructure to get the
*existing* API container running on ACA, reachable over its managed-ingress
URL, with `GET /health` returning 200 — before the database is migrated or
the web frontend exists. See
[`stage-instructions/stage-2-build-minimal-api-container-deploy-to-aca-with-health-probe.md`](../../../stage-instructions/stage-2-build-minimal-api-container-deploy-to-aca-with-health-probe.md).

`dev08`, `dev09`, and `dev10` (Stage 4) complete the walking skeleton: build
and deploy the existing web (nginx/React) container as a second Container
App wired to the Stage 2 API app, and provide a reusable end-to-end smoke
test that proves the web + API + migrated-DB path actually works over the
public ACA ingress URLs. See
[`stage-instructions/stage-4-wire-migrated-db-deploy-web-container-walking-skeleton-smoke-te.md`](../../../stage-instructions/stage-4-wire-migrated-db-deploy-web-container-walking-skeleton-smoke-te.md).

This is a separate, new IaC surface from `deployment/azure/scripts/az01`
through `az12a*`, which build the team's two-region, production-HA topology
against the same subscription. Do not run the `az0N` scripts and the `devN`
scripts against overlapping resource groups.

Access to the target subscription is interactive `az login` per
[ADR 0002](../../../docs/adr/0002-deploy-dev-environment-to-azure-container-apps-via-interactive.md) —
there is no service principal or CI credential for this environment. That
means these scripts are meant to be run by a human at a terminal, not from
an agent or a pipeline.

## Before you run anything

1. **Confirm the budget alert is active.** Run
   `deployment/azure/scripts/az00d-create-test-subscription-budget.sh` (safe
   to re-run; it creates/updates one Azure Budget resource, no billable
   infrastructure). This is the actual enforced alert on the test
   subscription — distinct from `az00c`, which is a read-only report a human
   has to act on.
2. **Log in and select the subscription:**
   ```bash
   az login
   az account set --subscription cd32baeb-7b71-4bc0-8ea3-9f23a50903fe
   ```
   Every script in this directory re-checks this and fails loudly if the
   active subscription doesn't match, but it's worth setting explicitly
   first so you're not surprised by which tenant/account you're in.

## Running the scripts

Run these in order — `dev04` depends on the resource group from `dev01`
(all four scripts independently verify the resource group exists rather
than assuming order was followed):

```bash
bash dev01-resource-group.sh
bash dev02-container-apps-environment.sh
bash dev03-container-registry.sh
bash dev04-postgresql-flexible-server.sh
bash dev07-run-all-migrations.sh
```

Then, once `dev01`-`dev04` have all completed, build and deploy the API
container (Stage 2):

```bash
bash dev05-build-push-api-image.sh
bash dev06-deploy-api-aca.sh
```

- `dev05-build-push-api-image.sh` builds `deployment/containers/api/Dockerfile`
  with `az acr build` (no local Docker or ACR admin credentials required —
  it uses the operator's own Azure RBAC on the registry, the same approach
  `deployment/azure/scripts/az08b` uses in production) and pushes it to the
  `dev03` registry, tagged from the current git commit. It records the exact
  pushed image digest into `dev-environment.env` for `dev06` to deploy.
- `dev06-deploy-api-aca.sh` creates (or updates) the `ca-phd-dev-api-westus3`
  Container App in the `dev02` environment: external ingress, target port
  `5080`, `min-replicas=0` per ADR 0001, and `PTP_DB_HOST`/`PTP_DB_PORT`/
  `PTP_DB_NAME`/`PTP_DB_USER`/`PTP_DB_PASSWORD` env vars pointed at the
  `dev04` PostgreSQL server (the DB password is read from
  `dev-postgres-admin-password.txt` and stored as a Container Apps secret,
  never as a plaintext env var). The schema isn't migrated yet at this
  stage — that's fine, because `GET /health` has no DB dependency. For a
  brand-new app, it bootstraps with a public placeholder image first so the
  Container App's system-assigned managed identity can exist before granting
  it `AcrPull` on the registry (Azure's documented pattern for
  system-assigned-identity image pull), then updates to the real image.
- Once `dev06` finishes, record the printed Container App URL in
  `.verity/deploy-access.md` (see the `TBD` placeholder line there) and
  confirm `curl https://<url>/health` returns HTTP 200.

Once the database is migrated (`dev07`, above) and the API app is deployed
(`dev05`/`dev06`, above), build and deploy the web container and run the
walking-skeleton smoke test (Stage 4):

```bash
bash dev08-build-push-web-image.sh
bash dev09-deploy-web-aca.sh
bash dev10-smoke-test.sh
```

- `dev08-build-push-web-image.sh` builds `deployment/containers/web/Dockerfile`
  with `az acr build` and pushes it to the `dev03` registry, tagged from the
  current git commit — the exact same pattern as `dev05`, just pointed at
  the web (nginx/React) image instead of the API image. It records the
  pushed image digest as `WEB_IMAGE` in `dev-environment.env` for `dev09` to
  deploy.
- `dev09-deploy-web-aca.sh` creates (or updates) the `ca-phd-dev-web-westus3`
  Container App in the `dev02` environment: external ingress, target port
  `8080`, `min-replicas=0` per ADR 0001 — the same bootstrap-then-update
  pattern `dev06` uses for ACR pull auth, since ACR admin is disabled. It
  needs no database credentials (the web container never talks to Postgres
  directly); instead it sets a single `API_UPSTREAM` env var to the Stage 2
  API app's URL (`API_APP_URL`, recorded by `dev06`).
  - **How the web container finds the API:** `deployment/containers/web/Dockerfile`
    sets `NGINX_ENVSUBST_FILTER="^(API_UPSTREAM|NGINX_RESOLVER)$"`, and the
    image's entrypoint runs nginx's own `docker-entrypoint.sh`, which
    `envsubst`s `${API_UPSTREAM}` into
    `deployment/containers/web/default.conf.template`'s `location /health`
    and `location /api/` `proxy_pass` rules. The React app itself only ever
    calls relative `/api/...` and `/health` paths (see
    `src/frontend/project-time-web/vite.config.js`'s dev-server proxy for
    the same pattern) — there is no build-time API base URL baked into the
    frontend bundle. So `API_UPSTREAM` is a runtime Container App env var,
    not something that requires rebuilding the web image to change.
- `dev10-smoke-test.sh` is the end-to-end walking-skeleton smoke test: it
  curls the web app's public URL and checks for real rendered HTML (not a
  blank page — looks for `<html`, `id="root"`, and `<title>Pulse</title>`),
  curls the API app's `/health` for a plain 200, curls the API app's
  `/api/db-health` directly to prove a real Postgres round trip (see below),
  and curls that same `/api/db-health` route *through* the web app's own
  nginx reverse proxy to prove the full web → API → DB path works over the
  public ACA ingress end to end. It prints a PASS/FAIL line per check plus
  an overall summary, and exits non-zero if anything failed, so it doubles
  as a checklist for `/verity:ship` to re-run after every future deploy to
  this environment.
  - **Why `/api/db-health` is the DB-backed check:** most `/api/*` routes in
    `src/backend/ProjectTime.Api/Program.cs` require a session
    (`GetProjectPulseSessionUserId`) and return 401 without one. `GET
    /api/db-health` (around Program.cs:871) is a genuine exception — no
    session check, and it opens a real `NpgsqlConnection` and runs `SELECT
    current_database(), current_user, now();`, returning
    `{"status":"database_connected", ...}` on success. That made the
    spec's fallback plan (treating a 401 as proof of DB connectivity when
    every real endpoint requires SSO) unnecessary here.

Each script:

- Checks whether its resource already exists in the expected shape before
  creating anything, and exits cleanly (not a no-op silently pretending to
  succeed — it prints "confirmed" and re-validates the shape) if it does.
- Fails loudly (non-zero exit, an `ERROR:` line) if a resource exists in an
  *unexpected* shape (wrong location, wrong SKU, etc.) rather than papering
  over the mismatch.
- Writes a timestamped log to `$HOME/project-health-dashboard-azure/logs/`
  and records the resource names/IDs it created into
  `$HOME/project-health-dashboard-azure/config/dev-environment.env`, mirroring
  the existing `az0N` scripts' generated-files convention
  (see `deployment/azure/README.md`).

Resources created (see `.verity/deploy-access.md` for the canonical
record once this stage has actually been run):

| Resource | Name |
| --- | --- |
| Resource group | `rg-project-health-dashboard-dev-westus3` |
| ACA environment | `cae-phd-dev-westus3` |
| ACR (Basic) | `acrphddev<subscription-derived suffix>` |
| PostgreSQL Flexible Server (Burstable B1ms) | `pg-phd-dev-w3-<subscription-derived suffix>` |
| API Container App (Stage 2, `dev06`) | `ca-phd-dev-api-westus3` — public URL TBD until an operator actually runs `dev06-deploy-api-aca.sh`; record it in `.verity/deploy-access.md` once known |
| Web Container App (Stage 4, `dev09`) | `ca-phd-dev-web-westus3` — public URL TBD until an operator actually runs `dev09-deploy-web-aca.sh`; record it in `.verity/deploy-access.md` once known |

## Known limitation: the PostgreSQL firewall rule is broader than "ACA only"

`dev04-postgresql-flexible-server.sh` was asked to scope the Postgres
firewall to just the ACA environment's outbound IP(s). That turned out not
to be achievable as specified, and the script documents why in a comment
above the firewall-rule step — summarized here for whoever runs it:

- A Consumption-plan Container Apps environment **without a VNet** (which
  is what ADR 0001 calls for, to avoid NAT Gateway cost) has no fixed,
  per-environment outbound IP. Microsoft's own docs say outbound IPs "might
  change over time," and a dedicated static egress IP is only available if
  you add a workload-profile VNet + Azure NAT Gateway — the exact
  cost/complexity ADR 0001 rejected for DEV.
- The script instead creates the standard "allow all Azure services and
  resources within Azure" firewall rule (start IP = end IP = `0.0.0.0`),
  which is Microsoft's own documented pattern for this combination
  (Consumption ACA + PostgreSQL Flexible Server, no VNet). This is **not**
  the open-internet `0.0.0.0/0` range — the server still requires a valid
  password — but it is broader than "just this ACA environment": any
  Azure-hosted resource in any subscription can attempt a connection.

This is a real gap relative to the stage spec, not a shortcut taken
silently. Two ways to close it later, if it matters before this environment
handles anything sensitive:

1. Accept it as a documented DEV-only risk — ADR 0001 already accepts
   "public DB access... firewall rules must be kept tight" as a
   consequence of the no-VNet design.
2. Reopen ADR 0001 to add a workload-profile VNet + NAT Gateway, which
   reintroduces the cost/complexity that ADR explicitly avoided.

## No Key Vault in this stage

ADR 0001 scopes DEV to exactly resource group + ACA environment + Postgres
+ ACR — no Key Vault. `dev04` generates the Postgres administrator password
and stores it only in a local file:

```text
$HOME/project-health-dashboard-azure/config/dev-postgres-admin-password.txt
```

(`chmod 600`, never printed to stdout or the log). Before Stage 2/3 wire the
application up to this database, move this credential into a proper secret
store (Key Vault, or whatever this workstream ends up using) — don't leave
it as a bare file for longer than necessary.

## Verifying after you run the scripts

```bash
az resource list -g rg-project-health-dashboard-dev-westus3 --output table
```

Expect exactly four resources: the Container Apps environment, the
PostgreSQL Flexible Server, the ACR registry, and (if Azure surfaces it as
a separate resource in the list) the server's default database.

**Confirm idempotency:** re-run all four scripts a second time. Every one
should print "confirmed"/"existing ... confirmed" lines and exit 0 without
creating or changing anything. If a re-run tries to create a resource that
already exists, or errors out instead of confirming, that's a bug — file it
rather than working around it.

**Check spend:** once resources exist, run
`deployment/azure/scripts/az00c-test-subscription-cost-check.sh` to confirm
actual/forecast spend is tracking toward the ~$30-45/mo target from ADR
0001, not the $150/$180/$195/$200 warning/critical/emergency/ceiling
thresholds.

## DEV-07: applying database migrations

`dev07-run-all-migrations.sh` is the next step after `dev04`, and must run
before any application deploy. There is no other unified migration runner in
this repo - migrations are otherwise applied one at a time via bespoke
scripts under `deployment/rocky-linux/` (`apply-initial-schema.sh`,
`apply-migration-NNN.sh`); `dev07` is new tooling that applies every
`database/migrations/*.sql` file in filename order against Stage 1's DEV
Postgres server in one run.

Prerequisites:

- `dev04-postgresql-flexible-server.sh` has already run (dev07 reads
  `POSTGRES_FQDN`/`POSTGRES_DATABASE`/`POSTGRES_ADMIN_USER`/`POSTGRES_PORT`
  back out of `$HOME/project-health-dashboard-azure/config/dev-environment.env`
  and the admin password out of
  `$HOME/project-health-dashboard-azure/config/dev-postgres-admin-password.txt`
  rather than re-deriving connection info).
- A `psql` client on `PATH` (macOS: `brew install libpq` and add it to
  `PATH`, since Homebrew's `libpq` is keg-only).

```bash
bash dev07-run-all-migrations.sh
```

What it does:

- Connects with the same `PTP_DB_HOST`/`PTP_DB_PORT`/`PTP_DB_NAME`/
  `PTP_DB_USER`/`PTP_DB_PASSWORD` env-var shape the application itself reads
  (`src/backend/ProjectTime.Api/Program.cs`), for consistency, even though
  this script talks to Postgres directly rather than through the app.
- Iterates `database/migrations/*.sql` in filename order and checks the
  `schema_migrations` table before applying each one, mirroring the
  idempotency pattern in `apply-initial-schema.sh` - already-applied
  migrations are skipped, so re-running the script is safe.
- Records a `schema_migrations` row for every migration it applies, even for
  the migration files that don't already insert their own row (a meaningful
  minority of files under `database/migrations/` - confirmed while writing
  this script - never reference `schema_migrations` at all). Doing this in
  the runner rather than relying on each file to self-register keeps
  tracking authoritative and makes re-runs a true no-op for every migration,
  not just the ones whose own SQL happens to insert a row.
- Fails loudly (non-zero exit, an `ERROR:` line) and stops on the first
  failing migration rather than continuing past it.
- Writes a timestamped log to `$HOME/project-health-dashboard-azure/logs/`.

**Verify success:** the script's own validation step compares
`SELECT COUNT(*) FROM schema_migrations` against the number of
`database/migrations/*.sql` files and fails if they don't match, but you can
re-check by hand:

```bash
ls database/migrations/*.sql | wc -l
psql -h <POSTGRES_FQDN> -p 5432 -U <POSTGRES_ADMIN_USER> -d <POSTGRES_DATABASE> \
  -c "SELECT COUNT(*) FROM schema_migrations;"
```

The two counts should match exactly. As a spot check, confirm a handful of
expected tables exist, e.g. Module 025's `module025_sow_gsd_engagements`
(added by `database/migrations/099_module025_sow_gsd_workspace.sql`).

This script has not been run against a live database as part of writing it -
Stage 1's Postgres instance had not been provisioned yet when this was
written, and running it is a manual operator step after this change is
reviewed and merged.

## Tearing down

There is no `dev-teardown.sh` yet. To remove everything from this stage:

```bash
az group delete --name rg-project-health-dashboard-dev-westus3 --yes
```

That also removes the ACA environment, ACR, and Postgres server in one
call. It does **not** remove `az00d`'s budget resource (which is
subscription-scoped and worth keeping regardless) or the local files under
`$HOME/project-health-dashboard-azure/`.
