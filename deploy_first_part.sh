# script summary: locks down access on the virtual machine by using a secure ssh key for group 16.
# deployed from my active WPI linux server account. This server contains the secure private key.
# steps: checks that my key doesn't already work. If it doesn't, it uses Randy's bootstrap key to gain access.
# then it installs my secure public key on the virtual machine.
# then it verifies my key. Only then does it remove Randy's key (to avoid bricking)
# finally, it does a connection check again with my group 16 key.

#!/usr/bin/env bash

#exit the script if there's a failure, and report the error
set -Eeuo pipefail

#my settings for the port, machine, and remote user
PORT=22016
MACHINE="paffenroth-23.dyn.wpi.edu"
REMOTE_USER="student-admin"

#paths to the private key and public key I made on the wpi linux machine i'm using to run this
#scp copies the public key on to the virtual machine.
NEW_PRIVATE_KEY="${HOME}/.ssh/kelly_cs2"
NEW_PUBLIC_KEY="${NEW_PRIVATE_KEY}.pub"

# Optional argument used when Randy's key is needed to bootstrap a reset VM.
OLD_PRIVATE_KEY="${1:-}"
OLD_PUBLIC_KEY=""

#getting path to the old public key based on the old private key if it exists
if [[ -n "${OLD_PRIVATE_KEY}" ]]; then
    OLD_PUBLIC_KEY="${OLD_PRIVATE_KEY}.pub"
fi

#combining the remote username and the machine host name for all the ssh/scp commands
SSH_TARGET="${REMOTE_USER}@${MACHINE}"

# Course-VM recovery tradeoff:
# A recreated VM may present a new SSH host key at the same hostname and port.
# This keeps the exception local to this script rather than weakening global SSH.
HOST_KEY_OPTIONS=(
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
)

#keeping connection settings consistent across SSH and SCP commands
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

#checking that the private and public keys exist
if [[ ! -f "${NEW_PRIVATE_KEY}" ]]; then
    echo "ERROR: New private key not found: ${NEW_PRIVATE_KEY}"
    exit 1
fi

if [[ ! -f "${NEW_PUBLIC_KEY}" ]]; then
    echo "ERROR: New public key not found: ${NEW_PUBLIC_KEY}"
    exit 1
fi

#checking if the key already works (if the machine was not reset)
#if it doesn't work, then this will use randy's originally provided bootstrap key first
#it then opens a new vm connection to check that his key works
#then it will upload my group 16 public key to the virtual machine from the linux machine
#then open a new connection, check that it works before continuing on

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
# making sure that my group 16 key and randy's key are not the same
#to avoid accidental removal/bricking of the virtual machine
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