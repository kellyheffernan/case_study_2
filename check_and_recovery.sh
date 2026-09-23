#!/usr/bin/env bash

set -Eeuo pipefail

PORT=22016
MACHINE="paffenroth-23.dyn.wpi.edu"
REMOTE_USER="student-admin"

PRIVATE_KEY="${HOME}/.ssh/kelly_cs2"

BOOTSTRAP_PRIVATE_KEY="${HOME}/.ssh/student-admin_key"
BOOTSTRAP_PUBLIC_KEY="${BOOTSTRAP_PRIVATE_KEY}.pub"

PUBLIC_URL="http://${MACHINE}:8016/"
SERVICE_NAME="group16-recipe-chatbot"

SCRIPT_DIR=$(
    cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1
    pwd
)

DEPLOY_FIRST="${SCRIPT_DIR}/deploy_first_part.sh"
DEPLOY_SECOND="${SCRIPT_DIR}/deploy_second_part.sh"

STATE_DIR="${HOME}/.local/state/group16-recovery"
LOG_FILE="${STATE_DIR}/recovery.log"

LOCK_FILE="${STATE_DIR}/recovery.lock"

SSH_TARGET="${REMOTE_USER}@${MACHINE}"

HOST_KEY_OPTIONS=(
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
)

SSH_OPTIONS=(
    -p "${PORT}"
    -o BatchMode=yes
    -o IdentitiesOnly=yes
    -o ForwardAgent=no
    -o ClearAllForwardings=yes
    -o ConnectTimeout=10
    "${HOST_KEY_OPTIONS[@]}"
)

mkdir -p "${STATE_DIR}"

log() {
    local level="$1"
    shift

    printf '%s [%s] %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S %Z')" \
        "${level}" \
        "$*" |
        tee -a "${LOG_FILE}"
}

fail() {
    log "ERROR" "$*"
    exit 1
}

if command -v flock >/dev/null 2>&1; then
    exec 9>"${LOCK_FILE}"

    if ! flock -n 9; then
        log "INFO" "Another recovery check is already running; exiting."
        exit 0
    fi
else
    log "WARNING" "flock is unavailable; overlap protection is disabled."
fi

log "INFO" "Starting Group 16 health check."

for required_command in curl ssh; do
    if ! command -v "${required_command}" >/dev/null 2>&1; then
        fail "Required command is unavailable: ${required_command}"
    fi
done

if [[ ! -f "${PRIVATE_KEY}" ]]; then
    fail "SSH private key not found: ${PRIVATE_KEY}"
fi

if [[ ! -f "${DEPLOY_SECOND}" ]]; then
    fail "Deployment script not found: ${DEPLOY_SECOND}"
fi

log "INFO" "Recovery-script preflight checks passed."

http_is_healthy() {
    curl \
        --fail \
        --silent \
        --show-error \
        --max-time 15 \
        "${PUBLIC_URL}" \
        >/dev/null 2>&1
}

if http_is_healthy; then
    log "HEALTHY" "Public application responded successfully: ${PUBLIC_URL}"
    exit 0
fi

log "WARNING" "Public application health check failed: ${PUBLIC_URL}"

ssh_is_available() {
    ssh \
        -i "${PRIVATE_KEY}" \
        "${SSH_OPTIONS[@]}" \
        "${SSH_TARGET}" \
        "true" \
        >/dev/null 2>&1
}

wait_for_http_recovery() {
    local max_attempts=36
    local wait_seconds=5
    local attempt

    for ((attempt = 1; attempt <= max_attempts; attempt++)); do
        if http_is_healthy; then
            return 0
        fi

        log \
            "INFO" \
            "Waiting for application recovery (${attempt}/${max_attempts})."

        sleep "${wait_seconds}"
    done

    return 1
}

if ! ssh_is_available; then
    log "WARNING" "Group 16 SSH failed with kelly_cs2."

    if [[ ! -f "${DEPLOY_FIRST}" ]]; then
        fail "SSH bootstrap script not found: ${DEPLOY_FIRST}"
    fi

    if [[ ! -f "${BOOTSTRAP_PRIVATE_KEY}" ]]; then
        fail "Bootstrap private key not found: ${BOOTSTRAP_PRIVATE_KEY}"
    fi

    if [[ ! -f "${BOOTSTRAP_PUBLIC_KEY}" ]]; then
        fail "Bootstrap public key not found: ${BOOTSTRAP_PUBLIC_KEY}"
    fi

    log "INFO" "Attempting safe SSH bootstrap recovery."

    if ! bash "${DEPLOY_FIRST}" "${BOOTSTRAP_PRIVATE_KEY}"; then
        fail "SSH bootstrap recovery failed."
    fi

    if ! ssh_is_available; then
        fail "kelly_cs2 still does not work after bootstrap recovery."
    fi

    log "RECOVERED" "Group 16 SSH access was restored with kelly_cs2."
fi

log "INFO" "SSH is available; requesting a systemd service restart."

if ssh \
    -i "${PRIVATE_KEY}" \
    "${SSH_OPTIONS[@]}" \
    "${SSH_TARGET}" \
    "sudo systemctl restart ${SERVICE_NAME}.service"
then
    log "INFO" "Service restart command completed."

    if wait_for_http_recovery; then
        log "RECOVERED" "Application recovered after a systemd restart."
        exit 0
    fi

    log "WARNING" "Service restart did not restore application health."
else
    log "WARNING" "The systemd restart command failed."
fi

log "INFO" "Attempting full application redeployment."

if bash "${DEPLOY_SECOND}"; then
    if http_is_healthy; then
        log "RECOVERED" "Application recovered after full redeployment."
        exit 0
    fi
fi

fail "Application remains unhealthy after restart and redeployment attempts."