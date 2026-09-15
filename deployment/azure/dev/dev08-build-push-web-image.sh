#!/usr/bin/env bash
# Stage 4: build the web (nginx/React) container image and push it to Stage
# 1's ACR (deployment/azure/dev/dev03-container-registry.sh). Mirrors
# dev05-build-push-api-image.sh exactly, pointed at
# deployment/containers/web/Dockerfile instead of the API Dockerfile. Uses
# `az acr build` (ACR Tasks) rather than local `docker build`/`docker push`:
# the build runs inside the registry's own build service using the
# operator's Azure RBAC on the registry, so it works even though dev03
# created the ACR with --admin-enabled false (matches the pattern already
# used in production by deployment/azure/scripts/az08b-build-and-deploy-west-application.sh).
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
DOCKERFILE_RELATIVE="deployment/containers/web/Dockerfile"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG="${LOG_DIR}/dev08-build-push-web-image-${STAMP}.log"

{
    section "DEV-08 - Pulse DEV web image build & push"
    echo "TIME=$(date -u -Is)"
    echo "Resource group: $RG_DEV"
    echo "Registry: $ACR_NAME"
    echo "Repository: $WEB_REPOSITORY"
    echo "Repo root: $REPO_ROOT"
    echo "Dockerfile: $DOCKERFILE_RELATIVE"

    require_subscription
    echo "Subscription confirmed: $SUBSCRIPTION_ID"

    az group show --name "$RG_DEV" --output none \
        || fail "Resource group $RG_DEV does not exist. Run dev01-resource-group.sh first."

    az acr show --resource-group "$RG_DEV" --name "$ACR_NAME" --output none >/dev/null 2>&1 \
        || fail "ACR $ACR_NAME does not exist. Run dev03-container-registry.sh first."

    [ -f "${REPO_ROOT}/${DOCKERFILE_RELATIVE}" ] \
        || fail "Dockerfile not found at ${REPO_ROOT}/${DOCKERFILE_RELATIVE}"

    section "Resolving image tag from git state"

    # Tags are derived from the git commit so a pushed image can always be
    # traced back to exact source, matching the traceability az08b gets from
    # its EXPECTED_SOURCE_COMMIT lock -- without requiring this repeatable
    # DEV script to pin to one specific commit the way that one-time
    # production cutover script does.
    GIT_SHA="$(git -C "$REPO_ROOT" rev-parse --short=12 HEAD 2>/dev/null || true)"
    [ -n "$GIT_SHA" ] \
        || fail "Could not resolve a git commit SHA in $REPO_ROOT. This script tags images from git state and requires a git checkout."

    DIRTY_SUFFIX=""
    if [ -n "$(git -C "$REPO_ROOT" status --porcelain --untracked-files=no 2>/dev/null || true)" ]; then
        DIRTY_SUFFIX="-dirty"
        echo "NOTE: working tree has uncommitted changes; tagging with a -dirty suffix so this build is never mistaken for a clean-commit build."
    fi

    IMAGE_TAG="${GIT_SHA}${DIRTY_SUFFIX}"
    echo "Image tag: $IMAGE_TAG"

    section "Building and pushing via az acr build"

    az acr build \
        --registry "$ACR_NAME" \
        --resource-group "$RG_DEV" \
        --file "$DOCKERFILE_RELATIVE" \
        --image "${WEB_REPOSITORY}:${IMAGE_TAG}" \
        --image "${WEB_REPOSITORY}:dev-latest" \
        --only-show-errors \
        "$REPO_ROOT"

    echo "ACR_BUILD=passed"

    ACR_LOGIN_SERVER="$(az acr show --resource-group "$RG_DEV" --name "$ACR_NAME" --query loginServer --output tsv)"
    IMAGE_DIGEST="$(az acr repository show --name "$ACR_NAME" --image "${WEB_REPOSITORY}:${IMAGE_TAG}" --query digest --output tsv)"

    [ -n "$ACR_LOGIN_SERVER" ] || fail "Could not resolve login server for ACR $ACR_NAME."
    [ -n "$IMAGE_DIGEST" ] || fail "Could not resolve pushed image digest for ${WEB_REPOSITORY}:${IMAGE_TAG}."

    # Deploy scripts pin to this digest rather than a mutable tag, so a later
    # `dev09` run always deploys exactly what this run built and verified,
    # even if `dev-latest` moves again before dev09 runs.
    WEB_IMAGE="${ACR_LOGIN_SERVER}/${WEB_REPOSITORY}@${IMAGE_DIGEST}"

    echo "ACR_LOGIN_SERVER=$ACR_LOGIN_SERVER"
    echo "WEB_IMAGE=$WEB_IMAGE"

    record_config ACR_LOGIN_SERVER "$ACR_LOGIN_SERVER"
    record_config WEB_IMAGE_REPOSITORY "$WEB_REPOSITORY"
    record_config WEB_IMAGE_TAG "$IMAGE_TAG"
    record_config WEB_IMAGE_DIGEST "$IMAGE_DIGEST"
    record_config WEB_IMAGE "$WEB_IMAGE"

    section "Validation"

    az acr repository show --name "$ACR_NAME" --image "${WEB_REPOSITORY}:${IMAGE_TAG}" \
        --query '{image:name,digest:digest,createdTime:createdTime}' \
        --output table

    section "DEV-08 complete"
    echo "WEB IMAGE BUILT AND PUSHED"
} 2>&1 | tee "$LOG"

echo
echo "Log: $LOG"
echo "Config: $DEV_CONFIG_FILE"
