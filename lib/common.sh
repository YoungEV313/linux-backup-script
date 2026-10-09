#!/usr/bin/env bash
# lib/common.sh - shared helpers: config, logging, locking, exit codes, archive listing.
# Sourced by bin/*.sh - not meant to be executed directly.

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${BACKUP_CONFIG:-$PROJECT_ROOT/config/backup.conf}"

# ---- Exit codes (a cron job / monitoring can tell WHAT failed) ----------------
EX_USAGE=2          # wrong command-line usage
EX_CONFIG=3         # missing/invalid configuration
EX_LOCK=4           # another job is already running
EX_BACKUP=10        # backup creation failed
EX_TRANSFER=20      # upload failed (network, SSH, scp)
EX_VERIFY=21        # checksum verification failed (local or on the server)
EX_PRUNE=30         # retention cleanup failed
EX_RESTORE_CHECK=40 # restore refused BEFORE touching anything (bad chain, checksum, destination)
EX_RESTORE_FAIL=41  # extraction failed (partial output was removed)

LOG_TAG="${LOG_TAG:-main}"
LOG_FILE=""

# log LEVEL MESSAGE...   (INFO | WARN | ERROR)
log() {
    local level="$1"; shift
    local line
    line="$(date '+%F %T') [$(printf '%-5s' "$level")] [$LOG_TAG:$$] $*"
    [[ -n "$LOG_FILE" ]] && echo "$line" >> "$LOG_FILE"
    if [[ "$level" == "ERROR" ]]; then echo "$line" >&2; else echo "$line"; fi
}

# die EXIT_CODE MESSAGE...
die() {
    local code="$1"; shift
    log ERROR "$*"
    exit "$code"
}

require_vars() {
    local v
    for v in "$@"; do
        [[ -n "${!v:-}" ]] || die "$EX_CONFIG" "Config variable $v is not set in $CONFIG_FILE"
    done
}

load_config() {
    [[ -f "$CONFIG_FILE" ]] || die "$EX_CONFIG" "Config not found: $CONFIG_FILE (copy config/backup.conf.example first)"

    # defaults, overridden by the config file
    EXCLUDES=()
    FULL_EVERY_DAYS=7
    KEEP_FULL_BACKUPS=4
    DELETE_AFTER_SEND=false
    REMOTE_PORT=22
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"

    require_vars SOURCE_DIR BACKUP_DIR STATE_DIR LOG_DIR BACKUP_NAME
    [[ "$BACKUP_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || die "$EX_CONFIG" "BACKUP_NAME may only contain letters, digits, . _ -"
    [[ "$FULL_EVERY_DAYS" =~ ^[0-9]+$ ]] || die "$EX_CONFIG" "FULL_EVERY_DAYS must be a number"
    [[ "$KEEP_FULL_BACKUPS" =~ ^[0-9]+$ && "$KEEP_FULL_BACKUPS" -ge 1 ]] || die "$EX_CONFIG" "KEEP_FULL_BACKUPS must be a number >= 1"

    mkdir -p "$BACKUP_DIR" "$STATE_DIR" "$LOG_DIR"
    LOG_FILE="$LOG_DIR/backup.log"
}

# One job at a time. run.sh takes the lock once and exports BACKUP_LOCK_HELD for its children.
acquire_lock() {
    [[ -n "${BACKUP_LOCK_HELD:-}" ]] && return 0
    exec 9>"$STATE_DIR/job.lock"
    flock -n 9 || die "$EX_LOCK" "Another backup job is already running"
}

human_size() { numfmt --to=iec --suffix=B "$1" 2>/dev/null || echo "${1}B"; }
file_size()  { stat -c %s "$1"; }

# Archive names: <name>_<YYYY-MM-DD_HH-MM-SS>_<full|incremental>.tar.gz
# The timestamp comes BEFORE the type, so a plain alphabetical sort is also chronological order.
ARCHIVE_SUFFIX_RE='_[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}_(full|incremental)\.tar\.gz$'

# list_archives DIR -> archive file names for BACKUP_NAME, oldest first
list_archives() {
    local f
    while IFS= read -r f; do
        [[ "$f" =~ ^${BACKUP_NAME}${ARCHIVE_SUFFIX_RE} ]] && echo "$f"
    done < <(find "$1" -maxdepth 1 -type f -name '*.tar.gz' -printf '%f\n' | sort)
}

# archive_type FILE -> "full" or "incremental"
archive_type() { [[ "$1" =~ _(full|incremental)\.tar\.gz$ ]] && echo "${BASH_REMATCH[1]}"; }

# was_sent FILE -> 0 if transfer.sh already delivered (and the server verified) this archive
was_sent() { [[ -f "$STATE_DIR/sent.list" ]] && grep -qxF "$1" "$STATE_DIR/sent.list"; }
