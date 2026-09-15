#!/usr/bin/env bash
# Stage 2: deploy the API image built by dev05-build-push-api-image.sh as a
# Container App in Stage 1's ACA environment, external ingress, target port
# 5080 (deployment/containers/api/Dockerfile), min-replicas=0 per ADR 0001,
# pointed at Stage 1's PostgreSQL server via PTP_DB_* env vars even though
# the schema is not migrated yet -- GET /health has no DB dependency
# (src/backend/ProjectTime.Api/Program.cs:281-286).
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG="${LOG_DIR}/dev06-deploy-api-aca-${STAMP}.log"

DB_PASSWORD_SECRET_NAME="ptp-db-password"
# Public, unauthenticated placeholder used only for the very first revision
# of a brand-new Container App. Azure's own documented pattern for wiring a
# system-assigned managed identity up to ACR pull is create-with-public-image,
# then grant the identity, then update to the private image -- the identity's
# principal ID (and therefore the AcrPull role assignment) does not exist
# until the app resource itself has been created, so a private image cannot
# be pulled on the very first create call.
# (learn.microsoft.com/azure/container-apps/managed-identity-image-pull)
BOOTSTRAP_IMAGE="mcr.microsoft.com/k8se/quickstart:latest"

validate_containerapp_json() {
    local json_file="$1"
    python3 - "$json_file" "$RG_DEV" "$ACA_ENV_NAME" "$API_TARGET_PORT" <<'PY'
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
        state="$(az containerapp show --resource-group "$RG_DEV" --name "$API_APP_NAME" --query properties.provisioningState --output tsv 2>/dev/null || true)"
        [ "${state,,}" = "succeeded" ] && break
        [ "${state,,}" = "failed" ] && fail "Container App provisioning failed: $API_APP_NAME"
        sleep 10
    done
    [ "${state,,}" = "succeeded" ] || fail "Container App did not reach Succeeded within the wait budget (last state: $state)"
    echo "Provisioning state: $state"
}

{
    section "DEV-06 - Pulse DEV API Container App deploy"
    echo "TIME=$(date -u -Is)"
    echo "Resource group: $RG_DEV"
    echo "ACA environment: $ACA_ENV_NAME"
    echo "Container App: $API_APP_NAME"
    echo "Target port: $API_TARGET_PORT"

    require_subscription
    echo "Subscription confirmed: $SUBSCRIPTION_ID"

    az group show --name "$RG_DEV" --output none \
        || fail "Resource group $RG_DEV does not exist. Run dev01-resource-group.sh first."

    az containerapp env show --resource-group "$RG_DEV" --name "$ACA_ENV_NAME" --output none >/dev/null 2>&1 \
        || fail "ACA environment $ACA_ENV_NAME does not exist. Run dev02-container-apps-environment.sh first."

    az acr show --resource-group "$RG_DEV" --name "$ACR_NAME" --output none >/dev/null 2>&1 \
        || fail "ACR $ACR_NAME does not exist. Run dev03-container-registry.sh first."

    az postgres flexible-server show --resource-group "$RG_DEV" --name "$POSTGRES_SERVER" --output none >/dev/null 2>&1 \
        || fail "PostgreSQL server $POSTGRES_SERVER does not exist. Run dev04-postgresql-flexible-server.sh first."

    [ -f "$DEV_POSTGRES_PASSWORD_FILE" ] \
        || fail "PostgreSQL admin password file not found at $DEV_POSTGRES_PASSWORD_FILE. Run dev04-postgresql-flexible-server.sh first."

    section "Container Apps CLI extension"

    az config set extension.use_dynamic_install=yes_without_prompt --output none
    az extension add --name containerapp --upgrade --only-show-errors --output none
    echo "containerapp extension version: $(az extension show --name containerapp --query version --output tsv)"

    section "Resolving image to deploy"

    API_IMAGE="$(read_config API_IMAGE)"
    [ -n "$API_IMAGE" ] \
        || fail "No API_IMAGE recorded in $DEV_CONFIG_FILE. Run dev05-build-push-api-image.sh first."
    echo "API_IMAGE=$API_IMAGE"

    ACR_LOGIN_SERVER="$(read_config ACR_LOGIN_SERVER)"
    if [ -z "$ACR_LOGIN_SERVER" ]; then
        ACR_LOGIN_SERVER="$(az acr show --resource-group "$RG_DEV" --name "$ACR_NAME" --query loginServer --output tsv)"
    fi
    [ -n "$ACR_LOGIN_SERVER" ] || fail "Could not resolve login server for ACR $ACR_NAME."
    echo "ACR_LOGIN_SERVER=$ACR_LOGIN_SERVER"

    section "Resolving PostgreSQL coordinates"

    POSTGRES_FQDN="$(az postgres flexible-server show --resource-group "$RG_DEV" --name "$POSTGRES_SERVER" --query fullyQualifiedDomainName --output tsv)"
    [ -n "$POSTGRES_FQDN" ] || fail "Could not resolve fully qualified domain name for PostgreSQL server $POSTGRES_SERVER."
    echo "POSTGRES_FQDN=$POSTGRES_FQDN"
    echo "POSTGRES_DATABASE=$POSTGRES_DATABASE"
    echo "POSTGRES_ADMIN_USER=$POSTGRES_ADMIN_USER"
    echo "POSTGRES_PORT=$POSTGRES_PORT"
    echo "NOTE: schema is not migrated yet (Stage 3). GET /health has no DB"
    echo "dependency (Program.cs:281-286), so the app can boot and serve that"
    echo "route regardless of DB readiness."

    POSTGRES_PASSWORD="$(cat "$DEV_POSTGRES_PASSWORD_FILE")"

    ENV_VARS=(
        "ASPNETCORE_HTTP_PORTS=${API_TARGET_PORT}"
        "PTP_DB_HOST=${POSTGRES_FQDN}"
        "PTP_DB_PORT=${POSTGRES_PORT}"
        "PTP_DB_NAME=${POSTGRES_DATABASE}"
        "PTP_DB_USER=${POSTGRES_ADMIN_USER}"
        "PTP_DB_PASSWORD=secretref:${DB_PASSWORD_SECRET_NAME}"
    )

    section "Container App"

    if az containerapp show --resource-group "$RG_DEV" --name "$API_APP_NAME" --output none >/dev/null 2>&1; then
        echo "Existing Container App found: $API_APP_NAME"

        EXISTING_JSON="$(mktemp)"
        trap 'rm -f "$EXISTING_JSON"' EXIT
        az containerapp show --resource-group "$RG_DEV" --name "$API_APP_NAME" --output json > "$EXISTING_JSON"
        validate_containerapp_json "$EXISTING_JSON"

        section "Refreshing secret and environment variables"

        az containerapp secret set \
            --resource-group "$RG_DEV" \
            --name "$API_APP_NAME" \
            --secrets "${DB_PASSWORD_SECRET_NAME}=${POSTGRES_PASSWORD}" \
            --output none

        unset POSTGRES_PASSWORD

        az containerapp update \
            --resource-group "$RG_DEV" \
            --name "$API_APP_NAME" \
            --replace-env-vars "${ENV_VARS[@]}" \
            --min-replicas 0 \
            --max-replicas 1 \
            --output none

        echo "Reasserted env vars and scale (min-replicas=0, max-replicas=1)."
    else
        echo "No existing Container App found; creating: $API_APP_NAME"

        section "Creating with a public bootstrap image"

        az containerapp create \
            --resource-group "$RG_DEV" \
            --name "$API_APP_NAME" \
            --environment "$ACA_ENV_NAME" \
            --image "$BOOTSTRAP_IMAGE" \
            --ingress external \
            --target-port "$API_TARGET_PORT" \
            --transport auto \
            --revisions-mode single \
            --min-replicas 0 \
            --max-replicas 1 \
            --cpu 0.5 \
            --memory 1.0Gi \
            --secrets "${DB_PASSWORD_SECRET_NAME}=${POSTGRES_PASSWORD}" \
            --env-vars "${ENV_VARS[@]}" \
            --tags \
                "application=$PRODUCT_NAME" \
                "environment=$ENVIRONMENT" \
                "resource-function=api-container-app" \
                "architecture=single-region-scale-to-zero" \
            --only-show-errors \
            --output none

        unset POSTGRES_PASSWORD

        echo "Submitted Container App with bootstrap image: $API_APP_NAME"
        wait_for_provisioning_succeeded
    fi

    section "Wiring the ACA system-assigned identity up to ACR pull"

    # az containerapp registry set with --identity system turns on (or
    # confirms) the system-assigned managed identity and attempts to create
    # the AcrPull role assignment for it automatically. Safe to call on every
    # run: it is a create/update operation, not a one-shot.
    az containerapp registry set \
        --resource-group "$RG_DEV" \
        --name "$API_APP_NAME" \
        --server "$ACR_LOGIN_SERVER" \
        --identity system \
        --output none

    echo "Registry auth confirmed: $API_APP_NAME -> $ACR_LOGIN_SERVER (system-assigned identity)"

    section "Deploying the built API image"

    az containerapp update \
        --resource-group "$RG_DEV" \
        --name "$API_APP_NAME" \
        --image "$API_IMAGE" \
        --output none

    wait_for_provisioning_succeeded

    API_FQDN="$(az containerapp show --resource-group "$RG_DEV" --name "$API_APP_NAME" --query properties.configuration.ingress.fqdn --output tsv)"
    [ -n "$API_FQDN" ] || fail "API Container App FQDN is empty."

    record_config API_APP_NAME "$API_APP_NAME"
    record_config API_APP_FQDN "$API_FQDN"
    record_config API_APP_URL "https://${API_FQDN}"

    section "Validation"

    az containerapp show --resource-group "$RG_DEV" --name "$API_APP_NAME" \
        --query '{name:name,provisioningState:properties.provisioningState,fqdn:properties.configuration.ingress.fqdn,image:properties.template.containers[0].image,minReplicas:properties.template.scale.minReplicas,maxReplicas:properties.template.scale.maxReplicas}' \
        --output table

    az containerapp revision list --resource-group "$RG_DEV" --name "$API_APP_NAME" \
        --query "[].{Revision:name,Active:properties.active,Health:properties.healthState,Running:properties.runningState,Replicas:properties.replicas}" \
        --output table

    section "DEV-06 complete"
    echo "API CONTAINER APP DEPLOYED"
    echo "URL=https://${API_FQDN}"
    echo
    echo "Verify manually once the revision is healthy:"
    echo "  curl https://${API_FQDN}/health"
    echo "Expected: HTTP 200 with a JSON body like {\"status\":\"healthy\",...}."
    echo "Record this URL in .verity/deploy-access.md once confirmed."
} 2>&1 | tee "$LOG"

echo
echo "Log: $LOG"
echo "Config: $DEV_CONFIG_FILE"
