#!/usr/bin/env bash
# Stage 4: deploy the web image built by dev08-build-push-web-image.sh as a
# second Container App in Stage 1's ACA environment, external ingress,
# target port 8080 (deployment/containers/web/Dockerfile EXPOSE 8080 /
# default.conf.template "listen 8080;"), min-replicas=0 per ADR 0001.
#
# Unlike dev06-deploy-api-aca.sh, this app needs no PTP_DB_* env vars -- the
# web container talks to the API over HTTP, never directly to Postgres. It
# is wired to Stage 2's API app via a single API_UPSTREAM env var.
#
# How the web container learns the API's URL (investigated before writing
# this script, not invented): deployment/containers/web/Dockerfile sets
# `ENV API_UPSTREAM=http://127.0.0.1:5080` and
# `NGINX_ENVSUBST_FILTER="^(API_UPSTREAM|NGINX_RESOLVER)$"`. The image's
# entrypoint (deployment/containers/web/projecttime-web-entrypoint.sh) execs
# nginx's own /docker-entrypoint.sh, which runs envsubst over
# default.conf.template using every env var matched by
# NGINX_ENVSUBST_FILTER. default.conf.template's `location /health` and
# `location /api/` blocks both `proxy_pass` to `$api_upstream`, which is set
# from `${API_UPSTREAM}`. The React app itself (see
# src/frontend/project-time-web/vite.config.js's dev proxy, and e.g.
# src/frontend/project-time-web/src/RoleWelcomeDashboard.jsx's
# `fetch('/api/...')` calls) only ever calls relative `/api/...` and
# `/health` paths -- there is no build-time API base URL baked into the
# React bundle. So this is a *runtime* nginx reverse-proxy env var, not a
# build-time one: setting the `API_UPSTREAM` Container App env var to Stage
# 2's API app URL is the correct and only mechanism, and no separate
# rebuild of the web image is needed to point it at a different API
# instance.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG="${LOG_DIR}/dev09-deploy-web-aca-${STAMP}.log"

# Same bootstrap-then-update pattern as dev06-deploy-api-aca.sh: ACR admin is
# disabled (dev03 --admin-enabled false), so a brand-new Container App must
# be created with a public placeholder image first (so its system-assigned
# managed identity exists to grant AcrPull to), then updated to the real
# private image.
BOOTSTRAP_IMAGE="mcr.microsoft.com/k8se/quickstart:latest"

validate_containerapp_json() {
    local json_file="$1"
    python3 - "$json_file" "$RG_DEV" "$ACA_ENV_NAME" "$WEB_TARGET_PORT" <<'PY'
import json
import sys
from pathlib import Path

app = json.loads(Path(sys.argv[1]).read_text())
rg_dev, aca_env_name, target_port = sys.argv[2], sys.argv[3], sys.argv[4]

props = app.get("properties") or {}
ingress = (props.get("configuration") or {}).get("ingress") or {}
scale = (props.get("template") or {}).get("scale") or {}

errors = []

env_id = str(props.get("environmentId") or "")
if not env_id.endswith(f"/{aca_env_name}"):
    errors.append(f"environmentId {env_id!r} does not reference expected ACA environment {aca_env_name!r}")

if ingress.get("external") is not True:
    errors.append(f"ingress.external is {ingress.get('external')!r}, expected true")

if str(ingress.get("targetPort") or "") != str(target_port):
    errors.append(f"ingress.targetPort is {ingress.get('targetPort')!r}, expected {target_port!r}")

min_replicas = scale.get("minReplicas")
if min_replicas not in (0, "0", None):
    errors.append(f"scale.minReplicas is {min_replicas!r}, expected 0 per ADR 0001")

if errors:
    for item in errors:
        print(f"ERROR: {item}", file=sys.stderr)
    raise SystemExit(1)

print("Existing Container App shape validation passed.")
PY
}

wait_for_provisioning_succeeded() {
    local state="unknown"
    for _ in $(seq 1 60); do
        state="$(az containerapp show --resource-group "$RG_DEV" --name "$WEB_APP_NAME" --query properties.provisioningState --output tsv 2>/dev/null || true)"
        [ "${state,,}" = "succeeded" ] && break
        [ "${state,,}" = "failed" ] && fail "Container App provisioning failed: $WEB_APP_NAME"
        sleep 10
    done
    [ "${state,,}" = "succeeded" ] || fail "Container App did not reach Succeeded within the wait budget (last state: $state)"
    echo "Provisioning state: $state"
}

{
    section "DEV-09 - Pulse DEV web Container App deploy"
    echo "TIME=$(date -u -Is)"
    echo "Resource group: $RG_DEV"
    echo "ACA environment: $ACA_ENV_NAME"
    echo "Container App: $WEB_APP_NAME"
    echo "Target port: $WEB_TARGET_PORT"

    require_subscription
    echo "Subscription confirmed: $SUBSCRIPTION_ID"

    az group show --name "$RG_DEV" --output none \
        || fail "Resource group $RG_DEV does not exist. Run dev01-resource-group.sh first."

    az containerapp env show --resource-group "$RG_DEV" --name "$ACA_ENV_NAME" --output none >/dev/null 2>&1 \
        || fail "ACA environment $ACA_ENV_NAME does not exist. Run dev02-container-apps-environment.sh first."

    az acr show --resource-group "$RG_DEV" --name "$ACR_NAME" --output none >/dev/null 2>&1 \
        || fail "ACR $ACR_NAME does not exist. Run dev03-container-registry.sh first."

    section "Container Apps CLI extension"

    az config set extension.use_dynamic_install=yes_without_prompt --output none
    az extension add --name containerapp --upgrade --only-show-errors --output none
    echo "containerapp extension version: $(az extension show --name containerapp --query version --output tsv)"

    section "Resolving image to deploy"

    WEB_IMAGE="$(read_config WEB_IMAGE)"
    [ -n "$WEB_IMAGE" ] \
        || fail "No WEB_IMAGE recorded in $DEV_CONFIG_FILE. Run dev08-build-push-web-image.sh first."
    echo "WEB_IMAGE=$WEB_IMAGE"

    ACR_LOGIN_SERVER="$(read_config ACR_LOGIN_SERVER)"
    if [ -z "$ACR_LOGIN_SERVER" ]; then
        ACR_LOGIN_SERVER="$(az acr show --resource-group "$RG_DEV" --name "$ACR_NAME" --query loginServer --output tsv)"
    fi
    [ -n "$ACR_LOGIN_SERVER" ] || fail "Could not resolve login server for ACR $ACR_NAME."
    echo "ACR_LOGIN_SERVER=$ACR_LOGIN_SERVER"

    section "Resolving the API app's URL (Stage 2, dev06)"

    # dev06-deploy-api-aca.sh records API_APP_URL after its own Container App
    # reaches Succeeded. Read it back rather than re-deriving it, and fail
    # loudly if dev06 hasn't run yet -- this app is not useful without it.
    API_APP_URL="$(read_config API_APP_URL)"
    [ -n "$API_APP_URL" ] \
        || fail "No API_APP_URL recorded in $DEV_CONFIG_FILE. Run dev06-deploy-api-aca.sh first."
    echo "API_APP_URL=$API_APP_URL"

    ENV_VARS=(
        "API_UPSTREAM=${API_APP_URL}"
    )

    section "Container App"

    if az containerapp show --resource-group "$RG_DEV" --name "$WEB_APP_NAME" --output none >/dev/null 2>&1; then
        echo "Existing Container App found: $WEB_APP_NAME"

        EXISTING_JSON="$(mktemp)"
        trap 'rm -f "$EXISTING_JSON"' EXIT
        az containerapp show --resource-group "$RG_DEV" --name "$WEB_APP_NAME" --output json > "$EXISTING_JSON"
        validate_containerapp_json "$EXISTING_JSON"

        section "Refreshing environment variables"

        az containerapp update \
            --resource-group "$RG_DEV" \
            --name "$WEB_APP_NAME" \
            --replace-env-vars "${ENV_VARS[@]}" \
            --min-replicas 0 \
            --max-replicas 1 \
            --output none

        echo "Reasserted env vars and scale (min-replicas=0, max-replicas=1)."
    else
        echo "No existing Container App found; creating: $WEB_APP_NAME"

        section "Creating with a public bootstrap image"

        az containerapp create \
            --resource-group "$RG_DEV" \
            --name "$WEB_APP_NAME" \
            --environment "$ACA_ENV_NAME" \
            --image "$BOOTSTRAP_IMAGE" \
            --ingress external \
            --target-port "$WEB_TARGET_PORT" \
            --transport auto \
            --revisions-mode single \
            --min-replicas 0 \
            --max-replicas 1 \
            --cpu 0.5 \
            --memory 1.0Gi \
            --env-vars "${ENV_VARS[@]}" \
            --tags \
                "application=$PRODUCT_NAME" \
                "environment=$ENVIRONMENT" \
                "resource-function=web-container-app" \
                "architecture=single-region-scale-to-zero" \
            --only-show-errors \
            --output none

        echo "Submitted Container App with bootstrap image: $WEB_APP_NAME"
        wait_for_provisioning_succeeded
    fi

    section "Wiring the ACA system-assigned identity up to ACR pull"

    # az containerapp registry set with --identity system turns on (or
    # confirms) the system-assigned managed identity and attempts to create
    # the AcrPull role assignment for it automatically. Safe to call on every
    # run: it is a create/update operation, not a one-shot.
    az containerapp registry set \
        --resource-group "$RG_DEV" \
        --name "$WEB_APP_NAME" \
        --server "$ACR_LOGIN_SERVER" \
        --identity system \
        --output none

    echo "Registry auth confirmed: $WEB_APP_NAME -> $ACR_LOGIN_SERVER (system-assigned identity)"

    section "Deploying the built web image"

    az containerapp update \
        --resource-group "$RG_DEV" \
        --name "$WEB_APP_NAME" \
        --image "$WEB_IMAGE" \
        --output none

    wait_for_provisioning_succeeded

    WEB_FQDN="$(az containerapp show --resource-group "$RG_DEV" --name "$WEB_APP_NAME" --query properties.configuration.ingress.fqdn --output tsv)"
    [ -n "$WEB_FQDN" ] || fail "Web Container App FQDN is empty."

    record_config WEB_APP_NAME "$WEB_APP_NAME"
    record_config WEB_APP_FQDN "$WEB_FQDN"
    record_config WEB_APP_URL "https://${WEB_FQDN}"

    section "Validation"

    az containerapp show --resource-group "$RG_DEV" --name "$WEB_APP_NAME" \
        --query '{name:name,provisioningState:properties.provisioningState,fqdn:properties.configuration.ingress.fqdn,image:properties.template.containers[0].image,minReplicas:properties.template.scale.minReplicas,maxReplicas:properties.template.scale.maxReplicas}' \
        --output table

    az containerapp revision list --resource-group "$RG_DEV" --name "$WEB_APP_NAME" \
        --query "[].{Revision:name,Active:properties.active,Health:properties.healthState,Running:properties.runningState,Replicas:properties.replicas}" \
        --output table

    section "DEV-09 complete"
    echo "WEB CONTAINER APP DEPLOYED"
    echo "URL=https://${WEB_FQDN}"
    echo
    echo "Verify manually once the revision is healthy:"
    echo "  curl https://${WEB_FQDN}/"
    echo "Expected: HTTP 200 with real HTML containing <title>Pulse</title>, not a blank page."
    echo "Then run dev10-smoke-test.sh for the full end-to-end check."
    echo "Record this URL in .verity/deploy-access.md once confirmed."
} 2>&1 | tee "$LOG"

echo
echo "Log: $LOG"
echo "Config: $DEV_CONFIG_FILE"
