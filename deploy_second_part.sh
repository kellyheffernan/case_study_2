#script summary: this script verifies, installs, and deploys the gradio app to the VM from the Linux server.
# steps: connects securely through ssh with my new key (not randy's bootstrap key)
# clones my github repo if necessary
# then it create our python virtual environment and installs the requirements
# it then create a systemd service for the gradio app to automatically restart it when needed.
# then it double checks that the app is working on the vm internally
# it also checks externally through the external port to make sure others can access the app.

#!/usr/bin/env bash

# setting up our ssh settings, using my own key now as this script runs after the first deploy script.
set -Eeuo pipefail

# settings specific for group 16 vm
PORT=22016
MACHINE="paffenroth-23.dyn.wpi.edu"
REMOTE_USER="student-admin"

# this stays secure on our linux server account
PRIVATE_KEY="${HOME}/.ssh/kelly_cs2"

#this is where my gradio app code and the other code lives on github
REPO_URL="https://github.com/kellyheffernan/case_study_2.git"
REPO_BRANCH="main"
#directory where the repository is cloned onto our vm
REMOTE_APP_DIR="/home/student-admin/case_study_2"

# gradio runs on the internal port, and the external port is for others to access the app
SERVICE_NAME="group16-recipe-chatbot"
INTERNAL_PORT=7860
EXTERNAL_PORT=8016

# this makes it easier to run the ssh commands
SSH_TARGET="${REMOTE_USER}@${MACHINE}"

# Course-VM recovery tradeoff:
# A recreated VM may present a new host key at the same hostname and port.
# this is why we set stricthostkeychecking to no.
HOST_KEY_OPTIONS=(
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
)

# keeping consistent settings in our ssh and scp commands
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

#this checks that deployment commands are available on the wpi linux server first
# before making any changes to the VM.
echo "Running local deployment preflight checks..."

for required_command in ssh scp curl; do
    if ! command -v "${required_command}" >/dev/null 2>&1; then
        echo "ERROR: Required local command is unavailable: ${required_command}"
        exit 1
    fi
done

#double checks that the private key is actually on the linux server as a verifications step.
if [[ ! -f "${PRIVATE_KEY}" ]]; then
    echo "ERROR: Group 16 private key not found: ${PRIVATE_KEY}"
    exit 1
fi

echo "Local deployment preflight checks passed."

#double checking group 16 ssh key works to connect to the VM
# also reports if the VM has git and python installed.
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
     done'

echo "Remote deployment preflight completed."

# now we check if the application repository needs to be cloned or updated on the VM
# if the VM has been fully re-created, then it will need to be cloned from the repository.
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

#displays in the terminal the commit that was deployed to the VM
DEPLOYED_COMMIT=$(
    git -C "${REMOTE_APP_DIR}" rev-parse --short HEAD
)

echo "Repository deployment completed at commit ${DEPLOYED_COMMIT}."
REMOTE_SCRIPT

# create a python environmen for the app, installs packages from the requirements
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

# make sure the VM has the package needed to create Python virtual environments
echo "Ensuring Python virtual environment support is installed..."
sudo apt install -qq -y python3-venv

# a full redeployment gets a fresh virtual environment
echo "Creating a fresh Python virtual environment..."
rm -rf "${VENV_DIR}"
python3 -m venv "${VENV_DIR}"

echo "Installing application dependencies..."

"${VENV_DIR}/bin/python" -m pip install \
    --disable-pip-version-check \
    -r "${REQUIREMENTS_FILE}"

echo "Validating required Python imports..."

"${VENV_DIR}/bin/python" -c \
    "import accelerate, gradio, huggingface_hub, transformers"

echo "Python environment is ready."
REMOTE_SCRIPT

#this installs the recipe app as a systemd service
# this is easier because systemd will run app.py instead of me having to manually start it.
#it will also restart the app automatically if there is a crash
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

# directory where the systemd serviec file will be stored
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
# temporary file where webuild the systemd configuration first
#thought it would be safer to build it in a temp file first
TEMP_SERVICE_FILE=$(mktemp)

# this deletes the temp file after the systemd service is installed
cleanup() {
    rm -f "${TEMP_SERVICE_FILE}"
}

trap cleanup EXIT

# just checking in case i accidentally ran app.py in my own terminal and forgot to stop it.
if ss -ltnH "sport = :${INTERNAL_PORT}" | grep -q .; then
    if ! sudo systemctl is-active --quiet "${SERVICE_NAME}.service"; then
        echo "ERROR: Port ${INTERNAL_PORT} is already used by an unmanaged process."
        echo "Stop the manually launched application before continuing."
        exit 1
    fi
fi

#this create the systemd file to run our app.
# it tells the vm the command to use to run app.py and the settings we should run it with

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

# install the temporary systemd service file to its official location (as the final file)
sudo install \
    -o root \
    -g root \
    -m 0644 \
    "${TEMP_SERVICE_FILE}" \
    "${SERVICE_FILE}"

# this tells the vm to install the systemd service we just made
# then it tells systemd to reload, enable, and restart the service to run the app.

sudo systemctl daemon-reload
sudo systemctl enable "${SERVICE_NAME}.service"
sudo systemctl restart "${SERVICE_NAME}.service"

echo "systemd service installed and started."
REMOTE_SCRIPT

#checks that the app is working, but waits fora few minutes in case the installs take a while
echo "Waiting for the application to become healthy..."

ssh \
    -i "${PRIVATE_KEY}" \
    "${SSH_OPTIONS[@]}" \
    "${SSH_TARGET}" \
    bash -s -- "${SERVICE_NAME}" "${INTERNAL_PORT}" <<'REMOTE_SCRIPT'
set -Eeuo pipefail

SERVICE_NAME="$1"
INTERNAL_PORT="$2"

MAX_ATTEMPTS=120
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

#prints error logs if the app never works

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

# final verificaitons that the app is accessible from the external port to other users
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