#!/usr/bin/env bash
# bin/backup.sh - create a FULL or INCREMENTAL compressed backup with GNU tar.
#
# Usage: backup.sh full | incremental | auto
#   full         level-0 backup of everything (starts a new chain)
#   incremental  only what changed since the previous backup
#   auto         full if the last full is older than FULL_EVERY_DAYS, else incremental
#
# Order of operations (each step only starts if the previous one succeeded):
#   tar -> gzip integrity test -> write .sha256 -> publish archive -> commit tar snapshot
set -uo pipefail
LOG_TAG=backup
# shellcheck source=../lib/common.sh
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

usage() { echo "Usage: $(basename "$0") full | incremental | auto" >&2; }
[[ $# -eq 1 ]] || { usage; exit "$EX_USAGE"; }
mode="$1"
case "$mode" in full|incremental|auto) ;; *) usage; exit "$EX_USAGE" ;; esac

load_config
acquire_lock

SNAR="$STATE_DIR/$BACKUP_NAME.snar"          # tar's incremental "snapshot" metadata
STAMP="$STATE_DIR/$BACKUP_NAME.full_stamp"   # when the last full backup was made

choose_type() {
    case "$1" in
        full) echo full ;;
        incremental) [[ -f "$SNAR" ]] && echo incremental || echo full ;;
        auto)
            if [[ ! -f "$SNAR" || ! -f "$STAMP" ]]; then echo full; return; fi
            local age_days=$(( ( $(date +%s) - $(stat -c %Y "$STAMP") ) / 86400 ))
            (( age_days >= FULL_EVERY_DAYS )) && echo full || echo incremental ;;
    esac
}

type="$(choose_type "$mode")"
ts="$(date +%F_%H-%M-%S)"
file="${BACKUP_NAME}_${ts}_${type}.tar.gz"
out="$BACKUP_DIR/$file"
tmp="$out.partial"
work_snar="$SNAR.work"
start_seconds=$SECONDS

fail_backup() {   # fail_backup REASON
    rm -f "$tmp" "$out.sha256.tmp" "$work_snar"
    log ERROR "RESULT status=FAILED type=$type duration=$((SECONDS - start_seconds))s file=$file reason=\"$1\""
    exit "$EX_BACKUP"
}

log INFO "START type=$type requested=$mode source=$SOURCE_DIR file=$file"
[[ "$mode" == "incremental" && "$type" == "full" ]] && log WARN "No previous full backup found - running a FULL backup instead"

[[ -d "$SOURCE_DIR" && -r "$SOURCE_DIR" ]] || fail_backup "source directory missing or unreadable"
[[ ! -e "$out" ]] || fail_backup "archive already exists (two runs in the same second?)"

# Work on a copy of the snapshot so a failed run never corrupts the incremental chain.
if [[ "$type" == "full" ]]; then rm -f "$work_snar"; else cp "$SNAR" "$work_snar"; fi

exclude_args=()
for pattern in "${EXCLUDES[@]}"; do exclude_args+=(--exclude="$pattern"); done

tar_err="$(tar --create --gzip \
        --listed-incremental="$work_snar" \
        "${exclude_args[@]}" \
        --file="$tmp" \
        -C "$(dirname "$SOURCE_DIR")" "$(basename "$SOURCE_DIR")" 2>&1 >/dev/null)"
rc=$?

# tar exit codes: 0 = ok, 1 = some file changed while being read (archive still usable), 2+ = fatal
if (( rc >= 2 )); then
    log ERROR "tar said: $tar_err"
    fail_backup "tar exited with code $rc"
fi
(( rc == 1 )) && log WARN "tar reported: $tar_err (archive kept)"

gzip -t "$tmp" 2>/dev/null || fail_backup "archive failed the gzip integrity test"

# Checksum is written BEFORE the archive is published, so a published archive always has one.
hash="$(sha256sum "$tmp" | cut -d' ' -f1)"
printf '%s  %s\n' "$hash" "$file" > "$out.sha256.tmp" || fail_backup "cannot write checksum"
mv "$out.sha256.tmp" "$out.sha256"
mv "$tmp" "$out"
mv "$work_snar" "$SNAR"                       # commit the snapshot last
[[ "$type" == "full" ]] && touch "$STAMP"

bytes="$(file_size "$out")"
log INFO "RESULT status=SUCCESS type=$type size=$(human_size "$bytes") size_bytes=$bytes duration=$((SECONDS - start_seconds))s file=$file"
