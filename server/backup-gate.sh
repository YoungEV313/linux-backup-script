#!/bin/bash
# server/backup-gate.sh - install on the BACKUP SERVER (not on the machine being backed up).
#
# It is the "forced command" of the backup SSH key. Whatever the client asks for, sshd runs THIS
# script instead, and this script only allows three things:
#
#   ping            -> answers "pong" (connection test)
#   scp -d -t ...   -> receive files, but ALWAYS into $INCOMING (the client's path is ignored)
#   verify <file>   -> re-check the SHA-256 of an uploaded archive; if it is good, move it
#                      from incoming/ to store/ (never overwriting a file that is already there)
#
# So a stolen key can NOT open a shell, read your backups, delete them or overwrite stored ones.
set -u

BASE="/srv/backups/myhost"          # <- change me. Must contain incoming/ and store/, owned by the backup user
INCOMING="$BASE/incoming"
STORE="$BASE/store"
GATE_LOG="$BASE/gate.log"

log()  { echo "$(date '+%F %T') [gate] $*" >> "$GATE_LOG"; }
deny() { log "DENIED: ${SSH_ORIGINAL_COMMAND:-<interactive shell>}"; echo "backup-gate: command not allowed" >&2; exit 126; }

cmd="${SSH_ORIGINAL_COMMAND:-}"
[[ -n "$cmd" ]] || deny                       # nobody gets an interactive shell

case "$cmd" in
    ping)
        echo pong
        ;;

    "scp "*)
        # accept only "scp [-d|-p|-v ...] -t <path>"; rebuild the command ourselves
        read -ra words <<< "$cmd"
        flags=(); saw_t=false
        for w in "${words[@]:1:${#words[@]}-2}"; do
            case "$w" in
                -t) saw_t=true ;;
                -d|-p|-v) flags+=("$w") ;;
                *) deny ;;
            esac
        done
        $saw_t || deny
        log "upload session opened"
        exec scp "${flags[@]}" -t -- "$INCOMING"
        ;;

    "verify "*)
        f="${cmd#verify }"
        [[ "$f" =~ ^[A-Za-z0-9._-]+\.tar\.gz$ ]] || deny      # a plain file name, no slashes
        cd "$INCOMING" || exit 3
        if [[ ! -f "$f" || ! -f "$f.sha256" ]]; then
            log "verify $f: file or checksum missing"; exit 3
        fi
        # the checksum file must be about THIS file, and the data must match it
        if [[ "$(awk '{print $2}' "$f.sha256")" != "$f" ]] || ! sha256sum -c --status "$f.sha256"; then
            log "verify $f: CHECKSUM MISMATCH"; exit 1
        fi
        if [[ -e "$STORE/$f" ]]; then
            if cmp -s "$f" "$STORE/$f"; then            # same upload repeated (e.g. a retry) - fine
                rm -f "$f" "$f.sha256"; log "verify $f: already stored (identical)"; exit 0
            fi
            log "verify $f: CONFLICT - a different file with this name is already stored"; exit 2
        fi
        mv -n "$f" "$STORE/" && mv -n "$f.sha256" "$STORE/" || exit 3   # archive first, checksum last
        log "verify $f: OK, moved to store"
        ;;

    *) deny ;;
esac
