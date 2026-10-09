#!/usr/bin/env bash
# bin/restore.sh - restore a backup (full, or full + the needed incrementals) into a NEW directory.
#
# Usage:
#   restore.sh --list [--dir DIR]
#   restore.sh --to DEST [--backup latest|NAME|TIMESTAMP] [--dir DIR] [--dry-run]
#
#   --backup  which point in time: "latest" (default), an exact archive name, or a unique part
#             of its name such as 2026-10-08_02-00. Restoring an incremental automatically
#             restores the full backup and all incrementals before it, in the right order.
#   --dir     where the archives are (default BACKUP_DIR; use it for files copied back from the server)
#
# Safety: all checks happen first (chain complete, SHA-256, gzip). Extraction goes into a temporary
# folder and is moved to DEST only if every archive extracted cleanly. DEST must not contain files.
#
# Exit codes: 0 ok | 2 usage | 40 refused before touching anything | 41 extraction failed
set -uo pipefail
LOG_TAG=restore
# shellcheck source=../lib/common.sh
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

usage() { sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; }

list_only=false; dest=""; want="latest"; dir=""; dry_run=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --list) list_only=true ;;
        --to) dest="${2:-}"; shift ;;
        --backup) want="${2:-}"; shift ;;
        --dir) dir="${2:-}"; shift ;;
        --dry-run) dry_run=true ;;
        -h|--help) usage; exit 0 ;;
        *) usage; exit "$EX_USAGE" ;;
    esac
    shift
done

load_config
acquire_lock
dir="${dir:-$BACKUP_DIR}"
[[ -d "$dir" ]] || die "$EX_RESTORE_CHECK" "Backup directory not found: $dir"
mapfile -t files < <(list_archives "$dir")
(( ${#files[@]} )) || die "$EX_RESTORE_CHECK" "No archives for '$BACKUP_NAME' in $dir"

if $list_only; then
    n=0
    for f in "${files[@]}"; do
        type="$(archive_type "$f")"
        if [[ "$type" == "full" ]]; then n=$((n + 1)); echo; echo "Set $n:"; fi
        ts="${f#"${BACKUP_NAME}_"}"; ts="${ts%%_${type}.tar.gz}"
        printf '  %-11s %s  %8s  %s\n' "$type" "${ts/_/ }" "$(human_size "$(file_size "$dir/$f")")" "$f"
    done
    echo; exit 0
fi

[[ -n "$dest" ]] || { usage; exit "$EX_USAGE"; }

# ---- 1. which archive is the target? ------------------------------------------------------------
target=-1
if [[ "$want" == "latest" ]]; then
    target=$(( ${#files[@]} - 1 ))
else
    matches=()
    for i in "${!files[@]}"; do
        [[ "${files[$i]}" == "$want" || "${files[$i]}" == *"$want"* ]] && matches+=("$i")
    done
    (( ${#matches[@]} == 1 )) || die "$EX_RESTORE_CHECK" "'$want' matches ${#matches[@]} archives - use --list and give a unique name"
    target="${matches[0]}"
fi

# ---- 2. build the chain: nearest full at or before the target ... target ---------------------------
start=$target
while (( start >= 0 )) && [[ "$(archive_type "${files[$start]}")" != "full" ]]; do start=$((start - 1)); done
(( start >= 0 )) || die "$EX_RESTORE_CHECK" "No full backup exists before ${files[$target]} - the chain is broken, cannot restore"
chain=("${files[@]:start:target-start+1}")

log INFO "START restore target=${files[$target]} chain=${#chain[@]} archive(s) dest=$dest"

# ---- 3. pre-checks: nothing is written until all of them pass ------------------------------------
for f in "${chain[@]}"; do
    [[ -f "$dir/$f.sha256" ]] || die "$EX_RESTORE_CHECK" "Checksum file missing for $f - refusing to restore unverified data"
    ( cd "$dir" && sha256sum -c --status "$f.sha256" ) || die "$EX_RESTORE_CHECK" "SHA-256 mismatch: $f is corrupted"
    gzip -t "$dir/$f" 2>/dev/null || die "$EX_RESTORE_CHECK" "$f is not a valid gzip archive"
done
log INFO "All ${#chain[@]} archive(s) passed SHA-256 and gzip checks"

if [[ -e "$dest" ]]; then
    [[ -d "$dest" ]] || die "$EX_RESTORE_CHECK" "Destination exists and is not a directory: $dest"
    [[ -z "$(ls -A "$dest")" ]] || die "$EX_RESTORE_CHECK" "Destination is not empty: $dest (restore never overwrites existing files)"
fi
parent="$(dirname "$dest")"
mkdir -p "$parent" 2>/dev/null && [[ -w "$parent" ]] || die "$EX_RESTORE_CHECK" "Cannot write to $parent"

if $dry_run; then
    log INFO "[dry-run] would extract, in this order: ${chain[*]}"
    exit 0
fi

# ---- 4. extract into a temporary folder; publish only if everything worked ---------------------------
staging="$(mktemp -d "$parent/.restore-XXXXXX")" || die "$EX_RESTORE_CHECK" "Cannot create a temporary folder in $parent"
trap 'rm -rf "$staging"' EXIT

for f in "${chain[@]}"; do
    log INFO "Extracting $f"
    # --listed-incremental=/dev/null makes tar apply the deletions recorded in incremental archives
    if ! err="$(tar --extract --gzip --listed-incremental=/dev/null --file="$dir/$f" -C "$staging" 2>&1)"; then
        log ERROR "tar said: $err"
        die "$EX_RESTORE_FAIL" "RESULT status=FAILED restore: extraction of $f failed - temporary files removed, $dest untouched"
    fi
done

[[ -d "$dest" ]] && rmdir "$dest"
chmod "$(printf '%o' $(( 0777 & ~$(umask) )))" "$staging"
mv "$staging" "$dest" || die "$EX_RESTORE_FAIL" "Could not move restored data to $dest"
trap - EXIT
log INFO "RESULT status=SUCCESS restore target=${files[$target]} archives=${#chain[@]} dest=$dest"
