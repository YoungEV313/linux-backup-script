#!/usr/bin/env bash
# bin/prune.sh - simple retention: keep the newest KEEP_FULL_BACKUPS backup SETS, delete older ones.
#
# A SET = one full backup + the incrementals that follow it (until the next full).
# Sets are always deleted as a whole, because an incremental is useless without its full.
#
# Safety rules:
#   - the newest KEEP_FULL_BACKUPS sets are never touched
#   - when a remote server is configured, a set is kept until EVERY archive in it was delivered
#
# Usage: prune.sh [--dry-run] [--keep N]
set -uo pipefail
LOG_TAG=prune
# shellcheck source=../lib/common.sh
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

dry_run=false; keep_override=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) dry_run=true ;;
        --keep) keep_override="${2:-}"; shift ;;
        *) echo "Usage: $(basename "$0") [--dry-run] [--keep N]" >&2; exit "$EX_USAGE" ;;
    esac
    shift
done

load_config
acquire_lock
[[ -z "$keep_override" ]] || { [[ "$keep_override" =~ ^[0-9]+$ && "$keep_override" -ge 1 ]] || die "$EX_USAGE" "--keep needs a number >= 1"; KEEP_FULL_BACKUPS="$keep_override"; }

mapfile -t files < <(list_archives "$BACKUP_DIR")
fulls=()
for i in "${!files[@]}"; do [[ "$(archive_type "${files[$i]}")" == "full" ]] && fulls+=("$i"); done

if (( ${#fulls[@]} <= KEEP_FULL_BACKUPS )); then
    log INFO "RESULT status=SUCCESS prune kept_sets=${#fulls[@]} deleted_archives=0 (nothing to do, limit is $KEEP_FULL_BACKUPS)"
    exit 0
fi

cutoff="${fulls[$(( ${#fulls[@]} - KEEP_FULL_BACKUPS ))]}"   # index of the oldest full we keep
deleted=0; freed=0; skipped=0; set_members=()

flush_set() {
    (( ${#set_members[@]} )) || return 0
    local f
    if [[ -n "${REMOTE_HOST:-}" ]]; then
        for f in "${set_members[@]}"; do
            if ! was_sent "$f"; then
                log WARN "Keeping old set starting at ${set_members[0]}: $f was not delivered to the server yet"
                skipped=$((skipped + 1)); set_members=(); return 0
            fi
        done
    fi
    for f in "${set_members[@]}"; do
        freed=$(( freed + $(file_size "$BACKUP_DIR/$f") ))
        if $dry_run; then log INFO "[dry-run] would delete $f"
        else rm -f "$BACKUP_DIR/$f" "$BACKUP_DIR/$f.sha256" || die "$EX_PRUNE" "Could not delete $f"; log INFO "Deleted $f"; fi
        deleted=$((deleted + 1))
    done
    set_members=()
}

for (( i = 0; i < cutoff; i++ )); do
    [[ "$(archive_type "${files[$i]}")" == "full" ]] && flush_set
    set_members+=("${files[$i]}")
done
flush_set

log INFO "RESULT status=SUCCESS prune kept_sets=$KEEP_FULL_BACKUPS deleted_archives=$deleted freed=$(human_size "$freed") sets_skipped=$skipped$($dry_run && echo ' (dry-run)')"
