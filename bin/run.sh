#!/usr/bin/env bash
# bin/run.sh - the ONE command to put in cron: backup -> transfer -> prune.
#
# Each step starts only if the previous one succeeded, so there is no timing guesswork
# ("backup at 02:00, transfer at 02:30" breaks as soon as a backup takes 31 minutes).
#
# Usage: run.sh [full|incremental|auto]     (default: auto)
# Exit code = the exit code of the step that failed (see the table in README.md).
set -uo pipefail
LOG_TAG=run
BIN="$(dirname "$(readlink -f "$0")")"
# shellcheck source=../lib/common.sh
source "$BIN/../lib/common.sh"

mode="${1:-auto}"
load_config
acquire_lock
export BACKUP_LOCK_HELD=1          # children share this lock instead of fighting for it

log INFO "Pipeline started (mode: $mode)"

"$BIN/backup.sh" "$mode";  rc=$?
(( rc == 0 )) || { log ERROR "Backup failed (exit $rc) - transfer skipped"; exit "$rc"; }

"$BIN/transfer.sh";        rc=$?
(( rc == 0 )) || { log ERROR "Transfer failed (exit $rc) - backup stays local and will be retried next run"; exit "$rc"; }

"$BIN/prune.sh";           rc=$?
(( rc == 0 )) || { log ERROR "Retention cleanup failed (exit $rc)"; exit "$rc"; }

log INFO "Pipeline finished OK"
