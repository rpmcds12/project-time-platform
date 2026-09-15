#!/usr/bin/env bash
# Stage 4: end-to-end walking-skeleton smoke test for the Pulse DEV
# environment. Run this after dev09-deploy-web-aca.sh (which itself must
# follow dev06-deploy-api-aca.sh and dev07-run-all-migrations.sh) to confirm
# the full web + API + DB path actually works over the public ACA ingress
# URLs -- not just that each piece deployed.
#
# This is the reusable checklist referenced by this stage's "Testing
# requirements" and is meant to be re-run by an operator (or /verity:ship)
# after every future deploy to this environment, not just once.
#
# Unlike every other deployment/azure/dev/dev0N-*.sh script, this one makes
# no `az` calls at all (beyond reading back recorded config) -- it only
# curls the two public HTTPS endpoints those scripts already stood up. It
# was NOT run against real infrastructure while writing it: nothing in this
# stage's provisioning has actually been applied to Azure yet (no `az
# login` has happened), so every exit code and piece of output below is
# theoretical until an operator runs the dev0N scripts for real and then
# runs this script.
#
# What "DB-backed" means here, and why: the stage spec calls for proving a
# real database round trip, not just GET /health (which has no DB
# dependency -- see dev06-deploy-api-aca.sh). Investigating
# src/backend/ProjectTime.Api/Program.cs turned up GET /api/db-health
# (around line 871): it is genuinely unauthenticated (no session/Entra check
# before it touches the database, unlike almost every other /api/* route in
# this file, which call GetProjectPulseSessionUserId(...) first and return
# 401 if there is no session), and it opens a real Npgsql connection and
# runs `SELECT current_database(), current_user, now();`, returning
# `{"status":"database_connected", ...}` on success, a 400 if DB env vars
# are missing, or a 500 Problem response if the connection/query itself
# fails. That is an honest, non-fabricated DB-backed check -- there was no
# need to fall back to the "401 vs 500 proves auth middleware/DB
# connectivity" reasoning the stage spec anticipated for the case where
# every data endpoint requires SSO, because this one genuinely doesn't.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG="${LOG_DIR}/dev10-smoke-test-${STAMP}.log"

CURL_MAX_TIME=20

declare -a RESULT_LINES=()
OVERALL_PASS=1

record_result() {
    local name="$1" passed="$2" detail="$3"
    if [ "$passed" = "1" ]; then
        RESULT_LINES+=("PASS  ${name} -- ${detail}")
    else
        RESULT_LINES+=("FAIL  ${name} -- ${detail}")
        OVERALL_PASS=0
    fi
}

# http_get URL: prints "<http_code>\n<body>" (body may be empty/truncated on
# a connection-level failure, in which case http_code is "000").
http_get() {
    local url="$1"
    local body_file
    body_file="$(mktemp)"
    local code
    code="$(curl -sS -o "$body_file" -w '%{http_code}' --max-time "$CURL_MAX_TIME" "$url" || echo "000")"
    echo "$code"
    cat "$body_file"
    rm -f "$body_file"
}

{
    section "DEV-10 - Pulse DEV walking-skeleton smoke test"
    echo "TIME=$(date -u -Is)"

    section "Resolving app URLs"

    API_APP_URL="$(read_config API_APP_URL)"
    [ -n "$API_APP_URL" ] \
        || fail "No API_APP_URL recorded in $DEV_CONFIG_FILE. Run dev06-deploy-api-aca.sh first."
    echo "API_APP_URL=$API_APP_URL"

    WEB_APP_URL="$(read_config WEB_APP_URL)"
    [ -n "$WEB_APP_URL" ] \
        || fail "No WEB_APP_URL recorded in $DEV_CONFIG_FILE. Run dev09-deploy-web-aca.sh first."
    echo "WEB_APP_URL=$WEB_APP_URL"

    section "Check 1: web app renders real HTML (not blank)"

    # Not just "any 200" -- the "HTMX stub" failure class the
    # stack-and-topology guide warns against is a 200 response with an
    # essentially empty document. Look for both the React mount point and
    # the app's own <title>, from src/frontend/project-time-web/index.html.
    WEB_RESPONSE="$(http_get "${WEB_APP_URL}/")"
    WEB_CODE="$(echo "$WEB_RESPONSE" | head -n1)"
    WEB_BODY="$(echo "$WEB_RESPONSE" | tail -n +2)"

    if [ "$WEB_CODE" = "200" ] \
        && echo "$WEB_BODY" | grep -qi '<html' \
        && echo "$WEB_BODY" | grep -q 'id="root"' \
        && echo "$WEB_BODY" | grep -qi '<title>Pulse</title>'; then
        record_result "web-html" 1 "HTTP $WEB_CODE, found <html>, id=\"root\", and <title>Pulse</title>"
    else
        record_result "web-html" 0 "HTTP $WEB_CODE, expected 200 with <html>/id=\"root\"/<title>Pulse</title> (got $(echo "$WEB_BODY" | head -c 200 | tr '\n' ' '))"
    fi

    section "Check 2: API /health (no DB dependency)"

    HEALTH_RESPONSE="$(http_get "${API_APP_URL}/health")"
    HEALTH_CODE="$(echo "$HEALTH_RESPONSE" | head -n1)"
    HEALTH_BODY="$(echo "$HEALTH_RESPONSE" | tail -n +2)"

    if [ "$HEALTH_CODE" = "200" ]; then
        record_result "api-health" 1 "HTTP $HEALTH_CODE, body: $(echo "$HEALTH_BODY" | head -c 200)"
    else
        record_result "api-health" 0 "HTTP $HEALTH_CODE, expected 200 (got $(echo "$HEALTH_BODY" | head -c 200 | tr '\n' ' '))"
    fi

    section "Check 3: API /api/db-health (real DB round trip, direct to API)"

    DB_RESPONSE="$(http_get "${API_APP_URL}/api/db-health")"
    DB_CODE="$(echo "$DB_RESPONSE" | head -n1)"
    DB_BODY="$(echo "$DB_RESPONSE" | tail -n +2)"

    if [ "$DB_CODE" = "200" ] && echo "$DB_BODY" | grep -q 'database_connected'; then
        record_result "api-db-health" 1 "HTTP $DB_CODE, body: $(echo "$DB_BODY" | head -c 300)"
    else
        record_result "api-db-health" 0 "HTTP $DB_CODE, expected 200 with status=database_connected (got $(echo "$DB_BODY" | head -c 300 | tr '\n' ' '))"
    fi

    section "Check 4: same DB-backed call through the web app's nginx reverse proxy"

    # This is the actual "full API + web + DB path... end-to-end over the
    # public ACA ingress URL" proof from the stage objectives: it exercises
    # the same location /api/ proxy_pass rule in
    # deployment/containers/web/default.conf.template that the real React
    # app uses for every fetch('/api/...') call, rather than only hitting
    # the API app's own ingress directly (Check 3, above).
    PROXY_RESPONSE="$(http_get "${WEB_APP_URL}/api/db-health")"
    PROXY_CODE="$(echo "$PROXY_RESPONSE" | head -n1)"
    PROXY_BODY="$(echo "$PROXY_RESPONSE" | tail -n +2)"

    if [ "$PROXY_CODE" = "200" ] && echo "$PROXY_BODY" | grep -q 'database_connected'; then
        record_result "web-proxy-db-health" 1 "HTTP $PROXY_CODE via ${WEB_APP_URL}/api/db-health, body: $(echo "$PROXY_BODY" | head -c 300)"
    else
        record_result "web-proxy-db-health" 0 "HTTP $PROXY_CODE via ${WEB_APP_URL}/api/db-health, expected 200 with status=database_connected (got $(echo "$PROXY_BODY" | head -c 300 | tr '\n' ' '))"
    fi

    section "DEV-10 summary"

    for line in "${RESULT_LINES[@]}"; do
        echo "$line"
    done

    echo
    if [ "$OVERALL_PASS" = "1" ]; then
        echo "OVERALL: PASS -- web app renders, API is healthy, and the DB round trip succeeds both directly and through the web app's reverse proxy."
    else
        echo "OVERALL: FAIL -- see FAIL lines above."
    fi
} 2>&1 | tee "$LOG"

echo
echo "Log: $LOG"

# NOTE: the block above runs as the left side of a pipe (`| tee`), which bash
# always runs in a subshell -- so $OVERALL_PASS as mutated inside that block
# never propagates back to this shell. Re-derive pass/fail from the log file
# itself instead, so this script's own exit code is trustworthy for use as a
# CI-style gate (e.g. from /verity:ship), not just a human-readable report.
! grep -q '^FAIL  ' "$LOG"
