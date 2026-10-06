#!/usr/bin/env bash
# =============================================================================
# test_recovery.sh: resilience tests for the group 16 VM auto-recovery system
#
# WHERE TO RUN: on the WPI Linux server, in the same folder as
#   check_and_recovery.sh, deploy_first_part.sh, deploy_second_part.sh.
#   (Needs the private keys and recovery.log that live there.)
#
# HOW IT WORKS: each test injects ONE fault into the VM, then waits for the
#   real recovery system (cron running check_and_recovery.sh) to fix it. This
#   script never repairs anything itself; it only breaks things, watches, and
#   records. It prints how long recovery took and the new recovery.log lines.
#
# USAGE: mkdir -p results
#        ./test_recovery.sh 2 2>&1 | tee results/test2_$(date +%F_%H%M).txt
#   Tests: 1 2 3 4 5 6 7 8a 8b 8c. Run ONE at a time and wait for it to finish.
#   Run the long ones (3, 4, 6, 8*) inside tmux.
# =============================================================================
set -u

# ---- connection settings for the VM ----
VM_USER="student-admin"
VM_HOST="paffenroth-23.dyn.wpi.edu"
VM_PORT=22016
KEY="${HOME}/.ssh/kelly_cs2" # group 16 key (normal access)
BOOTSTRAP_KEY="$HOME/.ssh/student-admin_key" # original bootstrap key
LOG="$PWD/recovery.log" # written by check_and_recovery.sh

# ---- VM-side names from the top of check_and_recovery.sh ----
APP_URL="http://${VM_HOST}:8016/" # Gradio URL used by the health check
SERVICE="group16-recipe-chatbot" # systemd unit name for the app
APP_DIR="/home/student-admin" # where the repo is cloned on the VM
VENV_DIR="$APP_DIR/venv" # python virtual environment
UNIT="/etc/systemd/system/$SERVICE.service" # the service file

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes)
vm()  { ssh "${SSH_OPTS[@]}" -i "$KEY" -p "$VM_PORT" "$VM_USER@$VM_HOST" "$@"; }            # run on VM with group 16 key
vmb() { ssh "${SSH_OPTS[@]}" -i "$BOOTSTRAP_KEY" -p "$VM_PORT" "$VM_USER@$VM_HOST" "$@"; }  # run on VM with bootstrap key
healthy() { curl -fsS -o /dev/null --max-time 5 "$APP_URL"; }                               # is the app answering?

# Poll the app until it responds. Prints seconds taken (= recovery time) or
# FAIL if it never comes back within the timeout ($1, in seconds).
wait_healthy() {
  local t0=$SECONDS
  sleep 5
  until healthy; do
    (( SECONDS - t0 > $1 )) && { echo "RESULT: FAIL, not healthy after $1s"; return 1; }
    sleep 10
  done
  echo "RESULT: healthy after $((SECONDS - t0))s"
}

# Remember where recovery.log ends now, so finish() can show only new lines.
begin()  { MARK=$(wc -l < "$LOG"); date '+START %F %T'; }
finish() { echo "--- new recovery.log lines ---"; tail -n +$((MARK+1)) "$LOG"; date '+END %F %T'; }

# Safety checks before ANY fault is injected: app is up, SSH works, and the
# VM's authorized_keys is backed up (cp -n = never overwrite an existing backup).
precheck() {
  healthy || { echo "App not healthy; fix before testing"; exit 1; }
  vm true || { echo "SSH with group 16 key failed; abort"; exit 1; }
  vm "cp -n ~/.ssh/authorized_keys ~/.ssh/authorized_keys.bak"
}

# -----------------------------------------------------------------------------
# TEST 1: Healthy baseline (control)
#   Injects: nothing. Waits 90s so cron runs at least once.
#   Expected: recovery.log shows only "healthy" entries, no restart or deploy.
#   Pass if: no recovery actions were taken on a healthy system.
# -----------------------------------------------------------------------------
t1() { sleep 90; }

# -----------------------------------------------------------------------------
# TEST 2: App down, VM and SSH fine
#   Injects: stops the app's systemd service (stop is not auto-restarted by
#            systemd, so recovery must come from our script).
#   Expected: check_and_recovery.sh restarts the service; app healthy again
#            within the 10-minute window. No deploy scripts should run.
#   Pass if: healthy again and log shows a restart but no deploy_*.sh runs.
# -----------------------------------------------------------------------------
t2() { vm "sudo systemctl stop $SERVICE"; wait_healthy 900; }

# -----------------------------------------------------------------------------
# TEST 3: Service restart cannot fix it
#   Injects: stops the service AND renames the venv, so the unit's ExecStart
#            points at a python that no longer exists and restart fails.
#   Expected: restart fails -> script falls back to deploy_second_part.sh,
#            which removes any old venv, rebuilds it, and restarts the app.
#   Pass if: healthy again and log shows restart attempt, then second deploy.
#   Cleanup: deletes the leftover renamed venv (venv.bak).
# -----------------------------------------------------------------------------
t3() {
  vm "sudo systemctl stop $SERVICE && mv $VENV_DIR ${VENV_DIR}.bak"
  wait_healthy 1500
  vm "rm -rf ${VENV_DIR}.bak"
}

# -----------------------------------------------------------------------------
# TEST 4: Full VM wipe (the main scenario)  [RISKIEST: read this]
#   Why the key swap: deploy_first_part.sh deletes the bootstrap key from the
#   VM once the group 16 key works. If we removed only the group 16 key we
#   would lock ourselves out, so we first put the bootstrap key back and
#   verify it works BEFORE removing anything.
#   Injects: (1) re-add bootstrap key, (2) verify it, (3) via the bootstrap
#            key, stop the service, delete unit file and repo, and remove the
#            group 16 key from authorized_keys.
#   Expected: SSH with group 16 key fails ~2 min -> deploy_first_part.sh
#            (bootstrap, install group 16 key) -> deploy_second_part.sh
#            (clone, venv, requirements, systemd) -> app healthy.
#   Pass if: healthy again and log shows first then second deploy script.
#   Aborts safely (nothing removed) if the bootstrap key doesn't work or the
#   group 16 key can't be read.
# -----------------------------------------------------------------------------
t4() {
  vm "echo '$(ssh-keygen -y -f "$BOOTSTRAP_KEY")' >> ~/.ssh/authorized_keys"
  vmb true || { echo "ABORT: bootstrap key doesn't work; nothing was removed"; return 1; }
  local G16; G16=$(ssh-keygen -y -f "$KEY" | awk '{print $2}')
  [[ -n $G16 ]] || { echo "ABORT: couldn't read group 16 key"; return 1; }
  vmb "sudo systemctl stop $SERVICE; sudo rm -f $UNIT; sudo systemctl daemon-reload; rm -rf ${APP_DIR:?};
       grep -vF '$G16' ~/.ssh/authorized_keys > /tmp/ak.new;
       [ -s /tmp/ak.new ] && cat /tmp/ak.new > ~/.ssh/authorized_keys; rm -f /tmp/ak.new"
  vm true 2>/dev/null && echo "WARN: group 16 key still works, wipe incomplete"
  wait_healthy 1800
}

# -----------------------------------------------------------------------------
# TEST 5: Transient SSH outage shorter than the 2-minute tolerance
#   Injects: stops the app (otherwise the script sees a healthy app and exits
#            before ever checking SSH), then blocks the SSH port with a
#            firewall rule that removes ITSELF after 90s (can't strand you).
#   Expected: script retries SSH, it comes back before 2 min, so it takes the
#            service-restart path. deploy_first_part.sh must NOT run.
#   Pass if: healthy again and log shows NO bootstrap/first-deploy run.
# -----------------------------------------------------------------------------
t5() {
  vm "sudo systemctl stop $SERVICE"
  vm "sudo -n setsid sh -c 'iptables -I INPUT -p tcp --dport $VM_PORT -j DROP; sleep 90; iptables -D INPUT -p tcp --dport $VM_PORT -j DROP' </dev/null >/dev/null 2>&1 &"
  wait_healthy 1200
}

# -----------------------------------------------------------------------------
# TEST 6: Unrecoverable failure (negative test)
#   Injects: stops the service and adds an uninstallable package to
#            requirements.txt, so both restart and redeploy must fail.
#   Expected: restart fails, deploy_second_part.sh fails at pip install,
#            and the script logs a failure after its final 10-minute wait.
#   Pass if: the failure is logged (not silent) and nothing loops destructively.
#   Cleanup: after 25 min, restores requirements.txt via git so cron can
#            recover the app, then waits for healthy.
# -----------------------------------------------------------------------------
t6() {
  vm "sudo systemctl stop $SERVICE; echo 'nonexistent-pkg-xyz==0.0.0' >> $APP_DIR/requirements.txt"
  sleep 1500
  vm "git -C $APP_DIR checkout -- requirements.txt"
  wait_healthy 1500
}

# -----------------------------------------------------------------------------
# TEST 7: Concurrency / flock
#   Injects: stops the app, starts one recovery run, then starts a second
#            while the first still holds the lock.
#   Expected: the second instance exits immediately (lock held) and the first
#            completes the recovery.
#   Pass if: second instance returns quickly; log shows one recovery, not two.
# -----------------------------------------------------------------------------
t7() {
  vm "sudo systemctl stop $SERVICE"
  ./check_and_recovery.sh & sleep 3
  ./check_and_recovery.sh; echo "second instance exit code: $?"
  wait
}

# -----------------------------------------------------------------------------
# TEST 8: Partial failure states (is each deploy step idempotent / self-healing?)
#   8a: venv missing   (service stopped, venv deleted)
#   8b: unit file missing (service stopped, unit deleted, daemon reloaded)
#   8c: repo missing   (service stopped, whole app dir deleted)
#   Expected (all): restart fails -> deploy_second_part.sh rebuilds whatever is
#            missing -> app healthy.
#   Pass if: healthy again with no manual intervention in each case.
# -----------------------------------------------------------------------------
t8a() { vm "sudo systemctl stop $SERVICE && rm -rf $VENV_DIR"; wait_healthy 1500; }
t8b() { vm "sudo systemctl stop $SERVICE && sudo rm -f $UNIT && sudo systemctl daemon-reload"; wait_healthy 1500; }
t8c() { vm "sudo systemctl stop $SERVICE && rm -rf ${APP_DIR:?}"; wait_healthy 1500; }

# ---- dispatcher: runs precheck, the chosen test, then prints the log lines ----
case "${1:-}" in
  1|2|3|4|5|6|7|8a|8b|8c) precheck; begin; "t$1"; finish ;;
  *) echo "usage: $0 <1|2|3|4|5|6|7|8a|8b|8c>"; exit 1 ;;
esac