#!/bin/bash
# Wrapper so cron runs check_metrics.py with the right env and working directory.
cd "$(dirname "$0")" || exit 1

set -a
source ./monitor.env
set +a

/usr/bin/python3 check_metrics.py >> ../actions-runner/monitor_run.log 2>&1