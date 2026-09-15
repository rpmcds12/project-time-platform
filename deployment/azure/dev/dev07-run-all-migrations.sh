#!/usr/bin/env bash
# DEV-07: apply every database/migrations/*.sql file to Stage 1's DEV
# PostgreSQL Flexible Server, in filename order, idempotently.
#
# There is no unified migration runner anywhere else in this repo -
# migrations are otherwise applied one at a time via bespoke scripts under
# deployment/rocky-linux/ (apply-initial-schema.sh, apply-migration-NNN.sh).
# This script is new tooling for the DEV Azure environment; it does not
# replace or modify those Rocky Linux scripts or the migration files
# themselves.
#
# Run this after dev04-postgresql-flexible-server.sh and before any
# application deploy - see README.md in this directory.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
MIGRATIONS_DIR="${REPO_ROOT}/database/migrations"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG="${LOG_DIR}/dev07-run-all-migrations-${STAMP}.log"

# psql_runner: run psql against the DEV Postgres instance using the same
# PTP_DB_HOST/PORT/NAME/USER/PASSWORD env-var shape the application itself
# reads (src/backend/ProjectTime.Api/Program.cs, DatabaseConfig.FromEnvironment
# call site around line 2055-2072), even though this script talks to
# Postgres directly rather than through the app. PTP_DB_* are exported once
# below, after connection details are loaded from the DEV config file.
psql_runner() {
    PGPASSWORD="$PTP_DB_PASSWORD" psql \
        --no-psqlrc \
        -h "$PTP_DB_HOST" \
        -p "$PTP_DB_PORT" \
        -U "$PTP_DB_USER" \
        -d "$PTP_DB_NAME" \
        "$@"
}

# migration_is_applied MIGRATION_ID: mirrors the idempotency check in
# deployment/rocky-linux/apply-initial-schema.sh - treat "schema_migrations
# does not exist yet" (a completely fresh database) the same as "not
# applied", and otherwise look for a matching row.
migration_is_applied() {
    local id="$1"
    local result
    result="$(psql_runner -At -c "SELECT CASE WHEN to_regclass('public.schema_migrations') IS NULL THEN 'no' WHEN EXISTS (SELECT 1 FROM schema_migrations WHERE migration_id = '${id}') THEN 'yes' ELSE 'no' END;")"
    [ "$result" = "yes" ]
}

{
    section "DEV-07 - Pulse DEV database migrations"
    echo "TIME=$(date -u -Is)"
    echo "Migrations directory: $MIGRATIONS_DIR"

    command -v psql >/dev/null 2>&1 \
        || fail "psql is required but was not found on PATH. Install the PostgreSQL client (e.g. 'brew install libpq' on macOS and add it to PATH) and re-run."

    require_subscription
    echo "Subscription confirmed: $SUBSCRIPTION_ID"

    section "Confirming Stage 1 Postgres server exists"

    az postgres flexible-server show --resource-group "$RG_DEV" --name "$POSTGRES_SERVER" --output none >/dev/null 2>&1 \
        || fail "PostgreSQL server $POSTGRES_SERVER does not exist in $RG_DEV. Run dev04-postgresql-flexible-server.sh first."
    echo "Confirmed server exists: $POSTGRES_SERVER"

    section "Loading connection details"

    [ -f "$DEV_CONFIG_FILE" ] \
        || fail "$DEV_CONFIG_FILE does not exist. Run dev04-postgresql-flexible-server.sh first."

    # dev04 records POSTGRES_FQDN/POSTGRES_DATABASE/POSTGRES_ADMIN_USER/
    # POSTGRES_PORT into this file via record_config - read them back rather
    # than re-deriving connection info, per this stage's constraints.
    # shellcheck disable=SC1090
    source "$DEV_CONFIG_FILE"

    : "${POSTGRES_FQDN:?POSTGRES_FQDN missing from $DEV_CONFIG_FILE - re-run dev04-postgresql-flexible-server.sh}"
    : "${POSTGRES_DATABASE:?POSTGRES_DATABASE missing from $DEV_CONFIG_FILE - re-run dev04-postgresql-flexible-server.sh}"
    : "${POSTGRES_ADMIN_USER:?POSTGRES_ADMIN_USER missing from $DEV_CONFIG_FILE - re-run dev04-postgresql-flexible-server.sh}"
    : "${POSTGRES_PORT:?POSTGRES_PORT missing from $DEV_CONFIG_FILE - re-run dev04-postgresql-flexible-server.sh}"

    [ -f "$DEV_POSTGRES_PASSWORD_FILE" ] \
        || fail "$DEV_POSTGRES_PASSWORD_FILE does not exist. Run dev04-postgresql-flexible-server.sh first."

    export PTP_DB_HOST="$POSTGRES_FQDN"
    export PTP_DB_PORT="$POSTGRES_PORT"
    export PTP_DB_NAME="$POSTGRES_DATABASE"
    export PTP_DB_USER="$POSTGRES_ADMIN_USER"
    export PTP_DB_PASSWORD
    PTP_DB_PASSWORD="$(cat "$DEV_POSTGRES_PASSWORD_FILE")"

    echo "Host: $PTP_DB_HOST"
    echo "Port: $PTP_DB_PORT"
    echo "Database: $PTP_DB_NAME"
    echo "User: $PTP_DB_USER"
    echo "Password: (loaded from $DEV_POSTGRES_PASSWORD_FILE, not printed)"

    section "Locating migration files"

    [ -d "$MIGRATIONS_DIR" ] || fail "Migrations directory not found: $MIGRATIONS_DIR"

    shopt -s nullglob
    MIGRATION_FILES=("${MIGRATIONS_DIR}"/*.sql)
    shopt -u nullglob

    [ "${#MIGRATION_FILES[@]}" -gt 0 ] || fail "No .sql migration files found in $MIGRATIONS_DIR"

    # Sort in plain byte order (LC_ALL=C) regardless of the operator's
    # locale, so filename order is deterministic and matches the
    # zero-padded numeric/lettered naming convention already in use (e.g.
    # 001_..., 002_..., ..., 019h_..., 019m-aa-..., ..., 099_...). Note:
    # database/migrations/040_scoped_role_policy_versions.sql itself uses
    # psql's \ir to include the sibling 040_scoped_role_policy_versions/
    # directory's files - psql resolves \ir relative to the including
    # file's own path, so applying 040_scoped_role_policy_versions.sql with
    # -f below is sufficient; the directory's files are not iterated
    # separately (they are not picked up by the *.sql glob because the
    # directory itself does not end in .sql).
    # (Deliberately avoids GNU-only `sort -z`/`-print0`-style null-delimited
    # sorting - migration filenames never contain newlines, and this needs
    # to work with both GNU sort (Linux CI-shaped hosts) and BSD sort
    # (macOS, where an operator is expected to run this per README.md).)
    mapfile -t MIGRATION_FILES < <(printf '%s\n' "${MIGRATION_FILES[@]}" | LC_ALL=C sort)

    echo "Found ${#MIGRATION_FILES[@]} migration file(s)"

    section "Applying migrations"

    APPLIED_COUNT=0
    SKIPPED_COUNT=0

    for MIGRATION_FILE in "${MIGRATION_FILES[@]}"; do
        BASE_NAME="$(basename "$MIGRATION_FILE")"
        MIGRATION_ID="${BASE_NAME%.sql}"

        if migration_is_applied "$MIGRATION_ID"; then
            echo "SKIP  $MIGRATION_ID (already recorded in schema_migrations)"
            SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
            continue
        fi

        echo "APPLY $MIGRATION_ID ($MIGRATION_FILE)"
        psql_runner -v ON_ERROR_STOP=1 -f "$MIGRATION_FILE"

        # Not every file under database/migrations/ inserts its own
        # schema_migrations row (confirmed by grepping the migration set
        # while writing this script: most do, via an
        # "INSERT INTO schema_migrations (...) ON CONFLICT (migration_id) DO
        # NOTHING" at the end of the file, mirroring 001_initial_schema.sql -
        # but a meaningful minority, including 099_module025_sow_gsd_workspace.sql,
        # do not reference schema_migrations at all). Record it here
        # unconditionally so tracking is authoritative for every migration
        # regardless of whether the file itself self-registers, and so a
        # second run of this script is a true no-op (not just non-erroring)
        # for every migration. ON CONFLICT DO NOTHING makes this a harmless
        # no-op for files that already recorded themselves.
        psql_runner -v ON_ERROR_STOP=1 -c \
            "INSERT INTO schema_migrations (migration_id, description) VALUES ('${MIGRATION_ID}', 'Recorded by deployment/azure/dev/dev07-run-all-migrations.sh') ON CONFLICT (migration_id) DO NOTHING;"

        APPLIED_COUNT=$((APPLIED_COUNT + 1))
    done

    echo "Applied: $APPLIED_COUNT"
    echo "Already applied (skipped): $SKIPPED_COUNT"

    section "Validation"

    SCHEMA_MIGRATIONS_ROWS="$(psql_runner -At -c "SELECT COUNT(*) FROM schema_migrations;")"
    echo "schema_migrations row count: $SCHEMA_MIGRATIONS_ROWS"
    echo "Migration files found:      ${#MIGRATION_FILES[@]}"

    [ "$SCHEMA_MIGRATIONS_ROWS" = "${#MIGRATION_FILES[@]}" ] \
        || fail "schema_migrations row count ($SCHEMA_MIGRATIONS_ROWS) does not match migration file count (${#MIGRATION_FILES[@]}). Investigate before treating the DEV database as fully migrated."

    section "DEV-07 complete"
    echo "ALL MIGRATIONS APPLIED"
} 2>&1 | tee "$LOG"

echo
echo "Log: $LOG"
