#!/usr/bin/env bash

#script summary: this script monitors our chatbot.
# if it sees that the chatbot has gone down (as it will when the vm is re-set)
#it determines the recovery steps necessary.
# in a full recovery: deploys the other deploy_first_part and deploy_second_part scripts
# it is important to note that i wrote a cron job to automatically launch this script
# it gets launched every 1 minute to check! this way it works even when I am asleep
# steps:
# checks if the app is responding
# if not, checks ssh access to the VM.
# if ssh access is not working, it deploys deploy_first_part to restore secure ssh access.
# if ssh access works, but the app is down, it restarts the systemd service to restart the app.
# that was originally created in the deploy_second_part script.
# if that doesn't work, it uses deploy_second_part to fully redeploy the app.
# it saves everything in a log file we can look at for troubleshooting.

set -Eeuo pipefail

#connections for group 16
PORT=22016
MACHINE="paffenroth-23.dyn.wpi.edu"
REMOTE_USER="student-admin"

#private key on my secure linux server
PRIVATE_KEY="${HOME}/.ssh/kelly_cs2"

#bootstrap keys if necessary after a full recreation
BOOTSTRAP_PRIVATE_KEY="${HOME}/.ssh/student-admin_key"
BOOTSTRAP_PUBLIC_KEY="${BOOTSTRAP_PRIVATE_KEY}.pub"

#url for checking if the app is externally working
PUBLIC_URL="http://${MACHINE}:8016/"
SERVICE_NAME="group16-recipe-chatbot"

#this scripts location
SCRIPT_DIR=$(
    cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1
    pwd
)

#other scripts locations
DEPLOY_FIRST="${SCRIPT_DIR}/deploy_first_part.sh"
DEPLOY_SECOND="${SCRIPT_DIR}/deploy_second_part.sh"

# recovery log files
STATE_DIR="${HOME}/.local/state/group16-recovery"
LOG_FILE="${STATE_DIR}/recovery.log"

LOCK_FILE="${STATE_DIR}/recovery.lock"

#ssh settings 
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

#custom logging function for troubleshooting
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

#this locks the recovery process so only one copy of this script runs at a time
# otherwise they could potentially interfere with each other. 
# this is important because I'm using a cron job to automatically launch this script every 1 minute.
# if tries to launch two instances of this at the same time, the lock file will prevent them from interfering with each other.
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

#checks the secure linux server for commands and ssh keys.
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

#function to check that the app is accessible from the url 
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

#checks if secure group 16 key is working
ssh_is_available() {
    ssh \
        -i "${PRIVATE_KEY}" \
        "${SSH_OPTIONS[@]}" \
        "${SSH_TARGET}" \
        "true" \
        >/dev/null 2>&1
}

# waits for a little bit (2 minutes) before running the full VM reset app redeployment.
# just in case there was a temporary connection problem. 
wait_for_normal_ssh() {
    local max_attempts=12
    local wait_seconds=10
    local attempt

    for ((attempt = 1; attempt <= max_attempts; attempt++)); do
        if ssh_is_available; then
            return 0
        fi

        log \
            "INFO" \
            "Normal SSH is unavailable; retrying (${attempt}/${max_attempts})."

        sleep "${wait_seconds}"
    done

    return 1
}

# gives ten minutes of buffer time to check that the recovery failed or not
wait_for_http_recovery() {
    local max_attempts=120
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

#checks if ssh unavailability is temporary or not.
# tracks whether Part 1 was required to restore SSH after a VM reset
BOOTSTRAP_RECOVERY_USED=false

# if it doesn't return, it runs the full bootstrap recovery.
if ! ssh_is_available; then
    log "WARNING" "Normal SSH is temporarily unavailable."

    if wait_for_normal_ssh; then
        log "INFO" "Normal SSH returned without bootstrap recovery."

        if wait_for_http_recovery; then
            log "RECOVERED" "Application recovered after temporary VM unavailability."
            exit 0
        fi

        log "WARNING" "SSH returned, but the application is still unhealthy."
    else
        log "WARNING" "Normal SSH did not recover within the retry period."

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
    # runs the first deploy script to restore SSH access
        if ! bash "${DEPLOY_FIRST}" "${BOOTSTRAP_PRIVATE_KEY}"; then
            fail "SSH bootstrap recovery failed."
        fi

        if ! ssh_is_available; then
            fail "kelly_cs2 still does not work after bootstrap recovery."
        fi

        log "RECOVERED" "Group 16 SSH access was restored with kelly_cs2."
        BOOTSTRAP_RECOVERY_USED=true
    fi
fi

# if Part 1 was required, assume the VM was reset and go directly
# to Part 2 instead of trying to restart a service that may no longer exist
if [[ "${BOOTSTRAP_RECOVERY_USED}" == true ]]; then
    log "INFO" "Bootstrap recovery was required; skipping systemd restart."
else
    # tries to restart the systemd service if SSH is available to avoid a full redeployment
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
fi

log "INFO" "Attempting full application redeployment."

# runs the second deploy script to fully redeploy the application
if bash "${DEPLOY_SECOND}"; then
    if http_is_healthy; then
        log "RECOVERED" "Application recovered after full redeployment."
        exit 0
    fi
fi

fail "Application remains unhealthy after restart and redeployment attempts."