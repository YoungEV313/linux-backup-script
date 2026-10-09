# Linux Backup System

Automated **full and incremental** backups with Bash and GNU `tar`, delivered **off-site over SSH**
with end-to-end SHA-256 verification, safe restore, simple retention, structured logging and a small
Python report tool.

> Backups that stay on the machine they protect are not backups. Local folders are only a staging
> area; the real copy lives on a server.

## Documentation

| Guide | Language |
|---|---|
| [Project guide (PDF, 11 pages)](docs/backup-system-guide-en.pdf) | English |
| [راهنمای پروژه (PDF، ۱۱ صفحه)](docs/backup-system-guide-fa.pdf) | فارسی |
| [SSH setup and security](docs/ssh-setup.md) | English |
| [Roadmap](docs/roadmap.md) | English |
## How it works
```
                        bin/run.sh   (the one command for cron)
                             |
   +-------------------------+--------------------------+
   v                         v                          v
 backup.sh  --ok-->  transfer.sh  --ok-->  prune.sh   -> exit 0
   |                    |                      |
   | tar (full/incr)    | 1 re-check SHA-256   | keep newest N sets,
   | gzip -t            | 2 scp -> incoming/   | never delete undelivered
   | write .sha256      | 3 server verifies    | or half-sets
   v                    v    SHA-256 -> store/ v
 exit 10 on failure   exit 20 / 21 on failure   exit 30 on failure
 (transfer skipped)   (retried next run)
```

## Layout

```
linux-backup-project/
├── bin/
│   ├── run.sh           backup -> transfer -> prune (put THIS in cron)
│   ├── backup.sh        create a full / incremental / auto backup
│   ├── transfer.sh      upload new archives over scp and have the server verify them
│   ├── restore.sh       list backups and restore into a new directory
│   └── prune.sh         retention: delete old backup sets
├── lib/common.sh        config, logging, locking, exit codes, archive helpers
├── config/backup.conf.example
├── server/backup-gate.sh    install on the SERVER: limits what the backup key may do
├── tools/report.py      list backups + verify checksums (Python 3, stdlib only)
├── tests/selftest.sh    automated end-to-end test (no server needed)
├── docs/ssh-setup.md    SSH key setup, restrictions explained, cron, troubleshooting
├── docs/roadmap.md
└── data/ backups/ state/ logs/     runtime folders
```

## Quick start

```bash
cp config/backup.conf.example config/backup.conf     # edit paths and server details
bin/backup.sh full                                    # first backup
bin/run.sh auto                                       # backup -> upload -> cleanup (weekly full, incrementals between)
bin/restore.sh --list                                 # what can I restore?
bin/restore.sh --to /tmp/restored                     # restore the latest state
python3 tools/report.py                               # verify checksums of local archives
tests/selftest.sh                                     # run the automated tests
```

Cron (one line - see [docs/ssh-setup.md](docs/ssh-setup.md) for the server side):

```cron
0 2 * * * /root/linux-backup-project/bin/run.sh auto >> /root/linux-backup-project/logs/cron.log 2>&1
```

## Commands

| Command | What it does |
|---|---|
| `backup.sh full\|incremental\|auto` | create an archive. `auto` = full if the last full is older than `FULL_EVERY_DAYS`, else incremental |
| `transfer.sh` | upload every archive not yet delivered; verified by the server before it counts as sent |
| `prune.sh [--dry-run] [--keep N]` | keep the newest `KEEP_FULL_BACKUPS` sets, delete older ones |
| `restore.sh --list` | show all backups grouped into sets |
| `restore.sh --to DEST [--backup latest\|NAME\|TIMESTAMP] [--dir DIR] [--dry-run]` | restore into `DEST` |
| `run.sh [full\|incremental\|auto]` | backup, then transfer (only if backup worked), then prune (only if transfer worked) |

## Incremental backups

`tar --listed-incremental=state/daily.snar` records every file's metadata. A **full** backup deletes
that snapshot first, so everything is archived. An **incremental** archives only what is new or
changed since the last run and records deletions. A **set** = one full backup + the incrementals
after it. The snapshot is updated on a copy and committed only after the archive is safely written,
so a failed run can never damage the chain.

## Restore

```bash
bin/restore.sh --list
bin/restore.sh --to /tmp/restored                              # latest state
bin/restore.sh --to /tmp/restored --backup 2026-10-08_02-00    # a point in time
bin/restore.sh --to /tmp/restored --dry-run                    # only show the plan
```

Restoring an incremental automatically restores **its full backup and every incremental before it,
in order**. Before anything is extracted, `restore.sh` checks that: the chain is complete, every
archive matches its SHA-256 and is a valid gzip, and the destination is empty (restore **never
overwrites** existing files). Extraction goes to a temporary folder that is moved to `DEST` only if
every archive extracted cleanly; otherwise it is deleted and `DEST` stays untouched.
The files appear in `DEST/<name of SOURCE_DIR>/`.

## Retention

`KEEP_FULL_BACKUPS=4` keeps the newest 4 **sets**. Whole sets are deleted - never a full without
its incrementals or the other way round. Two safety rules: the newest sets are never touched, and
when a server is configured a set is kept until **every** archive in it was verified by the server.
Try it first with `prune.sh --dry-run`.

## Checksums

```
backup.sh : tar -> gzip -t -> write .sha256 -> publish archive
transfer.sh: re-check .sha256 locally -> scp archive, then .sha256 -> server recomputes SHA-256
server    : good -> moved to store/ (never overwrites) | bad -> stays in incoming/, exit 21
```

An archive is added to `state/sent.list` only after the server confirmed it.

## Logging

One log file, `logs/backup.log`, one line per event: time, level, component and process id, then a message.
Every run writes a `START` line and exactly one `RESULT` line with the status, type, size and duration:

```
2026-10-08 09:29:46 [INFO ] [backup:2093] START type=full requested=full source=/data file=daily_2026-10-08_09-29-46_full.tar.gz
2026-10-08 09:29:46 [INFO ] [backup:2093] RESULT status=SUCCESS type=full size=198B size_bytes=198 duration=0s file=daily_2026-10-08_09-29-46_full.tar.gz
2026-10-08 09:30:21 [INFO ] [transfer:2484] RESULT status=SUCCESS stage=remote-verify file=daily_2026-10-08_09-29-46_full.tar.gz size=198B (verified by server)
2026-10-08 09:30:23 [INFO ] [prune:2619] RESULT status=SUCCESS prune kept_sets=2 deleted_archives=5 freed=863B sets_skipped=0
```

Find all failures: `grep 'status=FAILED' logs/backup.log`

## Exit codes

| Code | Meaning | Script |
|---|---|---|
| 0 | success | all |
| 2 | wrong usage | all |
| 3 | configuration error | all |
| 4 | another job is already running | all |
| 10 | backup failed (transfer is **not** started) | backup / run |
| 20 | upload failed: network, SSH or scp (retried next run) | transfer / run |
| 21 | checksum verification failed (local or on the server) | transfer / run |
| 30 | retention cleanup failed | prune / run |
| 40 | restore refused before touching anything | restore |
| 41 | extraction failed (temporary files removed) | restore |

## Security summary

SSH uses an Ed25519 key that can do **only** three things on the server: answer `ping`, upload into
`incoming/`, and ask for a checksum `verify`. It cannot open a shell, download, list, delete or
overwrite backups. Every restriction is explained for beginners in [docs/ssh-setup.md](docs/ssh-setup.md).

## Archive naming

`<name>_<YYYY-MM-DD_HH-MM-SS>_<full|incremental>.tar.gz` plus a `.sha256` file. The timestamp comes
first, so alphabetical order is also chronological order.

## Technologies

Linux, Bash, GNU tar/gzip, OpenSSH (`ssh`, `scp`, forced commands), cron, `sha256sum`, Python 3.

## Status

Phase 1 complete: creation, off-site transfer, restore, retention. See [docs/roadmap.md](docs/roadmap.md).
