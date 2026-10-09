#!/usr/bin/env bash
# bin/transfer.sh - upload new backups to the server (scp over SSH) and have the server verify them.
#
# For every archive that was not delivered yet (oldest first):
#   1. re-check its SHA-256 locally        (is the file still intact?)
#   2. scp archive, then its .sha256       (checksum last = "upload complete" marker)
#   3. ssh "verify <file>"                 (the server re-computes the SHA-256 itself)
# Only after step 3 succeeds is the archive written to state/sent.list.
#
# Exit codes: 0 ok | 3 config | 20 network/SSH/scp failure | 21 checksum verification failed
set -uo pipefail
LOG_TAG=transfer
# shellcheck source=../lib/common.sh
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

load_config
require_vars REMOTE_USER REMOTE_HOST SSH_KEY
acquire_lock
[[ -r "$SSH_KEY" ]] || die "$EX_CONFIG" "SSH key not readable: $SSH_KEY"

SENT_LIST="$STATE_DIR/sent.list"
touch "$SENT_LIST"
target="$REMOTE_USER@$REMOTE_HOST"

ssh_opts=(-i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=yes
          -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=4)
# The server key is restricted to the legacy scp protocol (scp -t), so force it with -O when supported.
scp_flags=()
scp_usage="$(scp 2>&1 || true)"          # "usage: scp [-346ABCOpqRrsTv] ..." - an O in that list means -O exists
scp_usage="${scp_usage%%$'\n'*}"
if [[ "$scp_usage" =~ ^usage:\ scp\ \[-[0-9A-Za-z]*O ]]; then scp_flags+=(-O); fi

START=$SECONDS
log INFO "START transfer to $target"
if ! reply="$(ssh "${ssh_opts[@]}" -p "$REMOTE_PORT" "$target" ping 2>&1)" || [[ "$reply" != *pong* ]]; then
    log ERROR "RESULT status=FAILED stage=connect reason=\"cannot reach $target or backup-gate is not installed: ${reply//$'\n'/ }\""
    exit "$EX_TRANSFER"
fi

sent=0; code=0
while IFS= read -r file; do
    was_sent "$file" && continue
    path="$BACKUP_DIR/$file"
    bytes="$(file_size "$path")"

    if [[ ! -f "$path.sha256" ]] || ! ( cd "$BACKUP_DIR" && sha256sum -c --status "$file.sha256" ); then
        log ERROR "RESULT status=FAILED stage=local-checksum file=$file reason=\"checksum file missing or does not match\""
        code=$EX_VERIFY; break
    fi

    log INFO "Uploading $file ($(human_size "$bytes"))"
    if ! scp "${scp_flags[@]}" "${ssh_opts[@]}" -P "$REMOTE_PORT" -q "$path" "$path.sha256" "$target:incoming/"; then
        log ERROR "RESULT status=FAILED stage=upload file=$file reason=\"scp failed (will retry on next run)\""
        code=$EX_TRANSFER; break
    fi

    # -n: ssh must not read stdin, or it would swallow the rest of the file list this loop is reading
    ssh -n "${ssh_opts[@]}" -p "$REMOTE_PORT" "$target" "verify $file" >/dev/null 2>&1
    vrc=$?
    if (( vrc == 255 )); then
        log ERROR "RESULT status=FAILED stage=remote-verify file=$file reason=\"SSH connection lost during verification\""
        code=$EX_TRANSFER; break
    elif (( vrc != 0 )); then
        log ERROR "RESULT status=FAILED stage=remote-verify file=$file reason=\"server checksum verification failed (code $vrc)\""
        code=$EX_VERIFY; break
    fi

    echo "$file" >> "$SENT_LIST"
    sent=$((sent + 1))
    log INFO "RESULT status=SUCCESS stage=remote-verify file=$file size=$(human_size "$bytes") (verified by server)"
    if [[ "$DELETE_AFTER_SEND" == "true" ]]; then
        rm -f "$path" "$path.sha256"
        log INFO "Removed local copy: $file"
    fi
done < <(list_archives "$BACKUP_DIR")

if (( code == 0 )); then
    log INFO "RESULT status=SUCCESS transfer_summary uploaded=$sent duration=$((SECONDS - START))s"
else
    log ERROR "RESULT status=FAILED transfer_summary uploaded=$sent exit_code=$code duration=$((SECONDS - START))s"
fi
exit "$code"
