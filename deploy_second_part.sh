#!/usr/bin/env bash

set -Eeuo pipefail

PORT=22016
MACHINE="paffenroth-23.dyn.wpi.edu"
REMOTE_USER="student-admin"

PRIVATE_KEY="${HOME}/.ssh/kelly_cs2"

REPO_URL="https://github.com/kellyheffernan/case_study_2.git"
REPO_BRANCH="main"
REMOTE_APP_DIR="/home/student-admin/case_study_2"

SERVICE_NAME="group16-recipe-chatbot"
INTERNAL_PORT=7860
EXTERNAL_PORT=8016

SSH_TARGET="${REMOTE_USER}@${MACHINE}"

# Course-VM recovery tradeoff:
# A recreated VM may present a new host key at the same hostname and port.
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

SCP_OPTIONS=(
    -P "${PORT}"
    -o BatchMode=yes
    -o IdentitiesOnly=yes
    -o ForwardAgent=no
    -o ClearAllForwardings=yes
    -o ConnectTimeout=10
    "${HOST_KEY_OPTIONS[@]}"
)

echo "Running local deployment preflight checks..."

for required_command in ssh scp curl; do
    if ! command -v "${required_command}" >/dev/null 2>&1; then
        echo "ERROR: Required local command is unavailable: ${required_command}"
        exit 1
    fi
done

if [[ ! -f "${PRIVATE_KEY}" ]]; then
    echo "ERROR: Group 16 private key not found: ${PRIVATE_KEY}"
    exit 1
fi

echo "Local deployment preflight checks passed."

echo "Verifying SSH access to the Group 16 VM..."

ssh \
    -i "${PRIVATE_KEY}" \
    "${SSH_OPTIONS[@]}" \
    "${SSH_TARGET}" \
    'set -u

     printf "SSH access verified.\n"
     printf "Remote user: %s\n" "$(whoami)"
     printf "Remote host: %s\n" "$(hostname)"

     for required_command in git python3; do
         if command -v "${required_command}" >/dev/null 2>&1; then
             printf "AVAILABLE: %s\n" "${required_command}"
         else
             printf "MISSING: %s\n" "${required_command}"
         fi
     done

     if python3 -m venv --help >/dev/null 2>&1; then
         printf "AVAILABLE: python3-venv\n"
     else
         printf "MISSING: python3-venv\n"
     fi'

echo "Remote deployment preflight completed."

echo "Deploying the application repository..."

ssh \
    -i "${PRIVATE_KEY}" \
    "${SSH_OPTIONS[@]}" \
    "${SSH_TARGET}" \
    bash -s -- "${REPO_URL}" "${REPO_BRANCH}" "${REMOTE_APP_DIR}" <<'REMOTE_SCRIPT'
set -Eeuo pipefail

REPO_URL="$1"
REPO_BRANCH="$2"
REMOTE_APP_DIR="$3"

if [[ -d "${REMOTE_APP_DIR}/.git" ]]; then
    echo "Existing Git repository found."

    CURRENT_ORIGIN=$(
        git -C "${REMOTE_APP_DIR}" remote get-url origin
    )

    if [[ "${CURRENT_ORIGIN}" != "${REPO_URL}" ]]; then
        echo "ERROR: Unexpected Git origin: ${CURRENT_ORIGIN}"
        exit 1
    fi

    echo "Updating existing repository..."

    git -C "${REMOTE_APP_DIR}" fetch --prune origin
    git -C "${REMOTE_APP_DIR}" pull --ff-only origin "${REPO_BRANCH}"

elif [[ -e "${REMOTE_APP_DIR}" ]]; then
    echo "ERROR: Deployment path exists but is not a Git repository:"
    echo "  ${REMOTE_APP_DIR}"
    exit 1
else
    echo "Cloning the application repository..."

    git clone \
        --branch "${REPO_BRANCH}" \
        --single-branch \
        "${REPO_URL}" \
        "${REMOTE_APP_DIR}"
fi

DEPLOYED_COMMIT=$(
    git -C "${REMOTE_APP_DIR}" rev-parse --short HEAD
)

echo "Repository deployment completed at commit ${DEPLOYED_COMMIT}."
REMOTE_SCRIPT

echo "Preparing the Python environment..."

ssh \
    -i "${PRIVATE_KEY}" \
    "${SSH_OPTIONS[@]}" \
    "${SSH_TARGET}" \
    bash -s -- "${REMOTE_APP_DIR}" <<'REMOTE_SCRIPT'
set -Eeuo pipefail

REMOTE_APP_DIR="$1"
VENV_DIR="${REMOTE_APP_DIR}/venv"
REQUIREMENTS_FILE="${REMOTE_APP_DIR}/requirements.txt"

if [[ ! -f "${REQUIREMENTS_FILE}" ]]; then
    echo "ERROR: requirements.txt was not found."
    exit 1
fi

if [[ ! -x "${VENV_DIR}/bin/python" ]]; then
    echo "Creating Python virtual environment..."
    python3 -m venv "${VENV_DIR}"
else
    echo "Existing Python virtual environment found."
fi

echo "Installing application dependencies..."

"${VENV_DIR}/bin/python" -m pip install \
    --disable-pip-version-check \
    -r "${REQUIREMENTS_FILE}"

echo "Validating required Python imports..."

"${VENV_DIR}/bin/python" -c \
    "import accelerate, gradio, huggingface_hub, transformers"

echo "Python environment is ready."
REMOTE_SCRIPT

echo "Installing the systemd application service..."

ssh \
    -i "${PRIVATE_KEY}" \
    "${SSH_OPTIONS[@]}" \
    "${SSH_TARGET}" \
    bash -s -- \
        "${SERVICE_NAME}" \
        "${REMOTE_USER}" \
        "${REMOTE_APP_DIR}" \
        "${INTERNAL_PORT}" <<'REMOTE_SCRIPT'
set -Eeuo pipefail

SERVICE_NAME="$1"
SERVICE_USER="$2"
REMOTE_APP_DIR="$3"
INTERNAL_PORT="$4"

SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
TEMP_SERVICE_FILE=$(mktemp)

cleanup() {
    rm -f "${TEMP_SERVICE_FILE}"
}

trap cleanup EXIT

if ss -ltnH "sport = :${INTERNAL_PORT}" | grep -q .; then
    if ! sudo systemctl is-active --quiet "${SERVICE_NAME}.service"; then
        echo "ERROR: Port ${INTERNAL_PORT} is already used by an unmanaged process."
        echo "Stop the manually launched application before continuing."
        exit 1
    fi
fi

cat > "${TEMP_SERVICE_FILE}" <<SERVICE_FILE_CONTENT
[Unit]
Description=Group 16 Recipe Chatbot
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}
WorkingDirectory=${REMOTE_APP_DIR}
ExecStart=${REMOTE_APP_DIR}/venv/bin/python ${REMOTE_APP_DIR}/app.py
Restart=on-failure
RestartSec=10
TimeoutStopSec=30
KillSignal=SIGINT
Environment=PYTHONUNBUFFERED=1
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SERVICE_FILE_CONTENT

sudo install \
    -o root \
    -g root \
    -m 0644 \
    "${TEMP_SERVICE_FILE}" \
    "${SERVICE_FILE}"

sudo systemctl daemon-reload
sudo systemctl enable "${SERVICE_NAME}.service"
sudo systemctl restart "${SERVICE_NAME}.service"

echo "systemd service installed and started."
REMOTE_SCRIPT

echo "Waiting for the application to become healthy..."

ssh \
    -i "${PRIVATE_KEY}" \
    "${SSH_OPTIONS[@]}" \
    "${SSH_TARGET}" \
    bash -s -- "${SERVICE_NAME}" "${INTERNAL_PORT}" <<'REMOTE_SCRIPT'
set -Eeuo pipefail

SERVICE_NAME="$1"
INTERNAL_PORT="$2"

MAX_ATTEMPTS=36
WAIT_SECONDS=5

for ((attempt = 1; attempt <= MAX_ATTEMPTS; attempt++)); do
    if curl \
        --fail \
        --silent \
        --show-error \
        --max-time 10 \
        "http://127.0.0.1:${INTERNAL_PORT}/" \
        >/dev/null 2>&1
    then
        echo "Application health check passed."
        exit 0
    fi

    echo "Health check ${attempt}/${MAX_ATTEMPTS} has not passed yet."
    sleep "${WAIT_SECONDS}"
done

echo "ERROR: Application did not become healthy in time."
echo "Recent service status:"

sudo systemctl \
    --no-pager \
    --full \
    status "${SERVICE_NAME}.service" || true

echo "Recent service logs:"

sudo journalctl \
    --no-pager \
    -u "${SERVICE_NAME}.service" \
    -n 50 || true

exit 1
REMOTE_SCRIPT

echo "Checking the external application endpoint..."

PUBLIC_URL="http://${MACHINE}:${EXTERNAL_PORT}/"
EXTERNAL_MAX_ATTEMPTS=6
EXTERNAL_WAIT_SECONDS=5

for ((attempt = 1; attempt <= EXTERNAL_MAX_ATTEMPTS; attempt++)); do
    if curl \
        --fail \
        --silent \
        --show-error \
        --max-time 10 \
        "${PUBLIC_URL}" \
        >/dev/null 2>&1
    then
        echo "External application health check passed."
        break
    fi

    if [[ "${attempt}" -eq "${EXTERNAL_MAX_ATTEMPTS}" ]]; then
        echo "ERROR: External application endpoint is unavailable:"
        echo "  ${PUBLIC_URL}"
        exit 1
    fi

    echo "External health check ${attempt}/${EXTERNAL_MAX_ATTEMPTS} failed."
    sleep "${EXTERNAL_WAIT_SECONDS}"
done

echo "Automated application deployment completed successfully."