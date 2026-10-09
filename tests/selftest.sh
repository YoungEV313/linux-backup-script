#!/usr/bin/env bash
# tests/selftest.sh - end-to-end self-test of backup / restore / prune / run (no SSH server needed).
# Everything happens in a temporary directory; your real data and config are never touched.
# Usage: tests/selftest.sh        (takes ~15 seconds because archive names have 1-second resolution)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/data"
cat > "$T/backup.conf" <<CONF
PROJECT_ROOT="$T"
SOURCE_DIR="$T/data"; BACKUP_DIR="$T/backups"; STATE_DIR="$T/state"; LOG_DIR="$T/logs"
BACKUP_NAME="test"; KEEP_FULL_BACKUPS=2; EXCLUDES=("*.tmp")
REMOTE_USER="nobody"; REMOTE_HOST="127.0.0.1"; REMOTE_PORT=1; SSH_KEY="$T/key"
CONF
touch "$T/key"; chmod 600 "$T/key"
export BACKUP_CONFIG="$T/backup.conf"
B="$ROOT/bin"; pass=0; fail=0

check() {  # check "description" expected_exit actual_exit
    if [[ "$2" == "$3" ]]; then echo "  PASS  $1"; pass=$((pass+1)); else echo "  FAIL  $1 (expected exit $2, got $3)"; fail=$((fail+1)); fi
}
quiet() { "$@" >/dev/null 2>&1; }

echo "1. full + incremental chain, restore must reproduce the latest state (including deletions)"
echo one > "$T/data/a.txt"; echo two > "$T/data/b.txt"; echo junk > "$T/data/x.tmp"
quiet "$B/backup.sh" full; check "full backup" 0 $?; sleep 1
echo changed >> "$T/data/a.txt"; echo new > "$T/data/c.txt"; rm "$T/data/b.txt"
quiet "$B/backup.sh" incremental; check "incremental backup" 0 $?; sleep 1
quiet "$B/restore.sh" --to "$T/r1"; check "restore latest" 0 $?
diff -r "$T/data" "$T/r1/data" -x '*.tmp' >/dev/null; check "restored data equals current data" 0 $?
[[ ! -e "$T/r1/data/x.tmp" ]]; check "excluded *.tmp file is not in the backup" 0 $?

echo "2. point-in-time restore (only the full backup)"
full_name="$(ls "$T/backups" | grep '_full.tar.gz$' | head -1)"
quiet "$B/restore.sh" --to "$T/r2" --backup "$full_name"; check "restore the full backup only" 0 $?
[[ -f "$T/r2/data/b.txt" && ! -f "$T/r2/data/c.txt" ]]; check "state matches the moment of the full backup" 0 $?

echo "3. safety checks"
mkdir "$T/busy"; echo keep > "$T/busy/file"
quiet "$B/restore.sh" --to "$T/busy"; check "refuses a non-empty destination" 40 $?
[[ "$(cat "$T/busy/file")" == keep ]]; check "destination left untouched" 0 $?
cp -r "$T/backups" "$T/backups.good"
echo garbage >> "$T/backups/$full_name"
quiet "$B/restore.sh" --to "$T/r3"; check "refuses a corrupted archive (SHA-256)" 40 $?
[[ ! -e "$T/r3" ]]; check "nothing was created for the refused restore" 0 $?
rm -rf "$T/backups"; cp -r "$T/backups.good" "$T/backups"
rm "$T/backups/$full_name" "$T/backups/$full_name.sha256"
quiet "$B/restore.sh" --to "$T/r4"; check "refuses a broken chain (full backup missing)" 40 $?
rm -rf "$T/backups"; cp -r "$T/backups.good" "$T/backups"

echo "4. retention keeps the newest 2 sets and never splits a set"
for round in 2 3 4; do
    echo "round $round" >> "$T/data/a.txt"; sleep 1; quiet "$B/backup.sh" full; sleep 1
    echo "inc $round" >> "$T/data/a.txt"; quiet "$B/backup.sh" incremental
done
before=$(ls "$T/backups"/*.tar.gz | wc -l)
quiet "$B/prune.sh" --dry-run; check "dry-run exit code" 0 $?
quiet "$B/prune.sh"; check "prune with undelivered archives exit code" 0 $?
[[ "$(ls "$T/backups"/*.tar.gz | wc -l)" == "$before" ]]; check "nothing deleted while archives are not yet on the server" 0 $?
ls "$T/backups" | grep '\.tar\.gz$' > "$T/state/sent.list"        # pretend the server has everything
quiet "$B/prune.sh" --dry-run; [[ "$(ls "$T/backups"/*.tar.gz | wc -l)" == "$before" ]]; check "dry-run deletes nothing" 0 $?
quiet "$B/prune.sh"; check "prune exit code" 0 $?
after=$(ls "$T/backups"/*.tar.gz | wc -l); fulls=$(ls "$T/backups" | grep -c '_full.tar.gz$')
[[ "$before" == 8 && "$after" == 4 && "$fulls" == 2 ]]; check "kept exactly 2 sets (4 archives), deleted whole old sets" 0 $?
first="$(ls "$T/backups" | grep '\.tar\.gz$' | head -1)"
[[ "$first" == *_full.tar.gz ]]; check "oldest remaining archive is a full backup" 0 $?
quiet "$B/restore.sh" --to "$T/r5"; check "restore still works after prune" 0 $?

echo "5. pipeline: transfer must not run if backup fails; failures return the right exit code"
mv "$T/data" "$T/data.off"
quiet "$B/run.sh" auto; check "backup failure -> exit 10" 10 $?
grep -q "transfer skipped" "$T/logs/backup.log"; check "transfer was skipped and logged" 0 $?
mv "$T/data.off" "$T/data"; sleep 1
quiet "$B/run.sh" auto; check "unreachable server -> exit 20" 20 $?
grep -q "stage=connect" "$T/logs/backup.log"; check "transfer failure is logged" 0 $?

echo; echo "Result: $pass passed, $fail failed"
(( fail == 0 ))
