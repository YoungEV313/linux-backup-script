# Roadmap

## Done
- [x] Full + incremental backups (`tar --listed-incremental`), `auto` mode
- [x] SHA-256 per archive, gzip integrity test, atomic publish, single-run lock
- [x] Off-site upload over SSH (Ed25519) with a locked-down, write-only key and a server-side gate
- [x] Checksum chain: backup -> local re-check -> upload -> server re-check -> `store/`
- [x] `run.sh` pipeline (backup -> transfer -> prune), each step only after the previous one succeeded
- [x] `restore.sh` with full + incremental chain handling and pre-checks
- [x] `prune.sh` retention by backup *sets*; never deletes undelivered or half-sets
- [x] Structured logging and distinct exit codes
- [x] `tests/selftest.sh`, Python report tool

## Next
- [ ] Retention on the *server* (`store/`)
- [ ] Alerts (email/Telegram) when a run fails
- [ ] Encrypt archives before upload (`gpg` or `age`)
- [ ] Optional `rsync` transport / bandwidth limit
- [ ] Go dashboard on top of `tools/report.py --json` and `logs/backup.log`
