#!/usr/bin/env bash

set -Eeuo pipefail

PORT=22016
MACHINE="paffenroth-23.dyn.wpi.edu"
REMOTE_USER="student-admin"

NEW_PRIVATE_KEY="${HOME}/.ssh/kelly_cs2"
NEW_PUBLIC_KEY="${NEW_PRIVATE_KEY}.pub"

# Optional argument used when Randy's key is needed to bootstrap a reset VM.
OLD_PRIVATE_KEY="${1:-}"
OLD_PUBLIC_KEY=""

if [[ -n "${OLD_PRIVATE_KEY}" ]]; then
    OLD_PUBLIC_KEY="${OLD_PRIVATE_KEY}.pub"
fi

SSH_TARGET="${REMOTE_USER}@${MACHINE}"

SSH_OPTIONS=(
    -p "${PORT}"
    -o BatchMode=yes
    -o IdentitiesOnly=yes
    -o StrictHostKeyChecking=accept-new
    -o ConnectTimeout=10
)

SCP_OPTIONS=(
    -P "${PORT}"
    -o BatchMode=yes
    -o IdentitiesOnly=yes
    -o StrictHostKeyChecking=accept-new
    -o ConnectTimeout=10
)

if [[ ! -f "${NEW_PRIVATE_KEY}" ]]; then
    echo "ERROR: New private key not found: ${NEW_PRIVATE_KEY}"
    exit 1
fi

if [[ ! -f "${NEW_PUBLIC_KEY}" ]]; then
    echo "ERROR: New public key not found: ${NEW_PUBLIC_KEY}"
    exit 1
fi

echo "Checking whether the Group 16 key already works..."

if ssh \
    -i "${NEW_PRIVATE_KEY}" \
    "${SSH_OPTIONS[@]}" \
    "${SSH_TARGET}" \
    "printf 'GROUP16_KEY_ALREADY_ACTIVE\n'"
then
    echo "The Group 16 key already works."
    echo "Bootstrap key installation is not needed."
else
    echo "The Group 16 key does not currently work."
    echo "Bootstrap access is required."

    if [[ -z "${OLD_PRIVATE_KEY}" ]]; then
        echo "ERROR: No bootstrap key was supplied."
        echo "Run this script with Randy's private-key path:"
        echo "  $0 /path/to/student-admin_key"
        exit 1
    fi

    if [[ ! -f "${OLD_PRIVATE_KEY}" ]]; then
        echo "ERROR: Bootstrap private key not found: ${OLD_PRIVATE_KEY}"
        exit 1
    fi

    if [[ ! -f "${OLD_PUBLIC_KEY}" ]]; then
        echo "ERROR: Bootstrap public key not found: ${OLD_PUBLIC_KEY}"
        exit 1
    fi

    echo "Testing Randy's bootstrap access..."

    ssh \
        -i "${OLD_PRIVATE_KEY}" \
        "${SSH_OPTIONS[@]}" \
        "${SSH_TARGET}" \
        "printf 'BOOTSTRAP_ACCESS_CONFIRMED\n'"

    echo "Uploading the Group 16 public key..."

    scp \
        -i "${OLD_PRIVATE_KEY}" \
        "${SCP_OPTIONS[@]}" \
        "${NEW_PUBLIC_KEY}" \
        "${SSH_TARGET}:~/.ssh/kelly_cs2.pub.pending"

    echo "Appending the Group 16 key without removing existing access..."

    ssh \
        -i "${OLD_PRIVATE_KEY}" \
        "${SSH_OPTIONS[@]}" \
        "${SSH_TARGET}" \
        'set -eu

         umask 077
         mkdir -p ~/.ssh
         touch ~/.ssh/authorized_keys
         chmod 700 ~/.ssh
         chmod 600 ~/.ssh/authorized_keys

         cp ~/.ssh/authorized_keys \
            ~/.ssh/authorized_keys.before_group16_rotation

         key_type=$(awk "NR == 1 { print \$1 }" \
             ~/.ssh/kelly_cs2.pub.pending)

         key_data=$(awk "NR == 1 { print \$2 }" \
             ~/.ssh/kelly_cs2.pub.pending)

         if ! awk -v type="${key_type}" -v data="${key_data}" \
             "\$1 == type && \$2 == data { found=1 } END { exit !found }" \
             ~/.ssh/authorized_keys
         then
             cat ~/.ssh/kelly_cs2.pub.pending \
                 >> ~/.ssh/authorized_keys
         fi

         rm -f ~/.ssh/kelly_cs2.pub.pending'

    echo "Opening a fresh connection with the Group 16 key..."

    if ! ssh \
        -i "${NEW_PRIVATE_KEY}" \
        "${SSH_OPTIONS[@]}" \
        "${SSH_TARGET}" \
        "printf 'GROUP16_KEY_VERIFIED\n'"
    then
        echo "ERROR: Group 16 key verification failed."
        echo "Randy's active access has been left unchanged."
        exit 1
    fi

    echo "Group 16 key verification succeeded."
fi

# Randy's key is removed only when its exact public key was supplied.
# Randy's key is removed only when its exact public key was supplied.
if [[ -n "${OLD_PUBLIC_KEY}" && -f "${OLD_PUBLIC_KEY}" ]]; then
    if cmp -s "${NEW_PUBLIC_KEY}" "${OLD_PUBLIC_KEY}"; then
        echo "ERROR: The old and new public keys are identical."
        echo "Refusing to remove the active Group 16 key."
        exit 1
    fi

    echo "Removing Randy's key from active authorized_keys, if present..."

    scp \
        -i "${NEW_PRIVATE_KEY}" \
        "${SCP_OPTIONS[@]}" \
        "${OLD_PUBLIC_KEY}" \
        "${SSH_TARGET}:~/.ssh/randy_key.pub.pending"

    ssh \
        -i "${NEW_PRIVATE_KEY}" \
        "${SSH_OPTIONS[@]}" \
        "${SSH_TARGET}" \
        'set -eu

         old_type=$(awk "NR == 1 { print \$1 }" \
             ~/.ssh/randy_key.pub.pending)

         old_data=$(awk "NR == 1 { print \$2 }" \
             ~/.ssh/randy_key.pub.pending)

         temporary_file=$(mktemp ~/.ssh/authorized_keys.XXXXXX)

         awk -v type="${old_type}" -v data="${old_data}" \
             "!(\$1 == type && \$2 == data)" \
             ~/.ssh/authorized_keys > "${temporary_file}"

         if [[ ! -s "${temporary_file}" ]]; then
             echo "ERROR: Refusing to install an empty authorized_keys file."
             rm -f "${temporary_file}"
             exit 1
         fi

         chmod 600 "${temporary_file}"
         mv "${temporary_file}" ~/.ssh/authorized_keys
         rm -f ~/.ssh/randy_key.pub.pending'
else
    echo "No old public key was supplied."
    echo "Skipping exact old-key removal."
fi

echo "Performing final Group 16 access verification..."

ssh \
    -i "${NEW_PRIVATE_KEY}" \
    "${SSH_OPTIONS[@]}" \
    "${SSH_TARGET}" \
    "printf 'GROUP16_FINAL_ACCESS_VERIFIED\n'"

echo "SSH access is ready for automated deployment."