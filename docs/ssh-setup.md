# SSH setup for off-site backups (and why it is locked down)

`bin/transfer.sh` copies every archive to a backup server with `scp`, authenticated by an
**Ed25519 SSH key** (no password, so cron can use it).

Because that key has no passphrase, **anyone who steals the key file can use it**. So we do not
try to make theft impossible - we make a stolen key *almost useless*. This is called the
**principle of least privilege**: give a key only the permissions the job needs, nothing more.

| What the backup job needs | What it does NOT need (so we forbid it) |
|---|---|
| send new backup files | open a shell / run commands on the server |
| ask the server "is this file intact?" | read, list or download old backups |
| | delete or overwrite stored backups |
| | forward ports, use X11, use an SSH agent |

How it works: on the server, the key is tied to a small script, `server/backup-gate.sh`.
Whatever the client asks for, `sshd` runs **only that script**, and the script allows exactly three requests:

```
ping             -> answers "pong"                       (is the server reachable?)
scp -d -t ...    -> receive files into incoming/ only    (the path the client sends is ignored)
verify <file>    -> server re-computes SHA-256; if OK, moves the file incoming/ -> store/
```

Uploaded files first land in `incoming/` ("quarantine"). They reach `store/` only after the server
verified the checksum, and a file already in `store/` is never overwritten. So even a thief with
the key cannot damage the backups you already have.

---

## 1. On the server: dedicated user and folders

```bash
sudo adduser --disabled-password --gecos "" bkpuser        # not "backup": that name already exists on Debian/Kali
sudo mkdir -p /srv/backups/myhost/incoming /srv/backups/myhost/store
sudo chown -R bkpuser:bkpuser /srv/backups/myhost
```

*Why a separate user?* If this account is abused, the attacker is a nobody who owns only one folder - not `root`, not your own account.

## 2. On the server: install the gate script

```bash
sudo install -o root -g root -m 755 server/backup-gate.sh /usr/local/bin/backup-gate.sh
sudo nano /usr/local/bin/backup-gate.sh       # set BASE="/srv/backups/myhost"
```

*Why owned by root?* The `bkpuser` account must not be able to edit the script that restricts it.

## 3. On the client (machine being backed up): create the key

```bash
ssh-keygen -t ed25519 -f ~/.ssh/backup_ed25519 -C "backup@$(hostname)" -N ""
chmod 600 ~/.ssh/backup_ed25519
```

`-N ""` means no passphrase (needed for unattended cron). `chmod 600` means only your user can read it.

## 4. On the server: authorize the key WITH restrictions

Put **one line** in `/home/bkpuser/.ssh/authorized_keys` (paste your `backup_ed25519.pub` at the end):

```
restrict,command="/usr/local/bin/backup-gate.sh",from="203.0.113.10" ssh-ed25519 AAAA...your-public-key... backup@client
```

| Option | Meaning, in plain words |
|---|---|
| `restrict` | switches OFF everything extra: no terminal, no port forwarding, no X11, no agent forwarding |
| `command="..."` | whatever the client types, run THIS script instead (a shell is impossible) |
| `from="203.0.113.10"` | the key only works when connecting from your client's IP (optional - remove it if your IP changes) |

```bash
sudo mkdir -p /home/bkpuser/.ssh && sudo nano /home/bkpuser/.ssh/authorized_keys
sudo chown -R bkpuser:bkpuser /home/bkpuser/.ssh
sudo chmod 700 /home/bkpuser/.ssh && sudo chmod 600 /home/bkpuser/.ssh/authorized_keys
```

## 5. On the client: trust the server and test

`transfer.sh` uses `StrictHostKeyChecking=yes`, which refuses unknown servers (protection against
someone impersonating your server). Connect once by hand and check the fingerprint:

```bash
ssh -i ~/.ssh/backup_ed25519 bkpuser@SERVER_IP ping        # first time: type "yes" after checking the fingerprint
```

Expected results (this proves the restrictions work):

```bash
ssh -i ~/.ssh/backup_ed25519 bkpuser@SERVER_IP ping        # -> pong
ssh -i ~/.ssh/backup_ed25519 bkpuser@SERVER_IP ls /        # -> backup-gate: command not allowed
ssh -i ~/.ssh/backup_ed25519 bkpuser@SERVER_IP             # -> backup-gate: command not allowed (no shell)
```

Denied attempts are written to `/srv/backups/myhost/gate.log` on the server.

## 6. Configure and automate

In `config/backup.conf` set `REMOTE_USER`, `REMOTE_HOST`, `REMOTE_PORT`, `SSH_KEY`. Then **one** cron line does everything:

```cron
0 2 * * * /root/linux-backup-project/bin/run.sh auto >> /root/linux-backup-project/logs/cron.log 2>&1
```

`run.sh` runs backup -> transfer -> prune, and starts each step only if the previous one succeeded.
There is no "transfer at 02:30" guess that breaks when a backup takes longer than 30 minutes.

---

## Why `scp -O`?

Newer `scp` versions silently use the SFTP protocol, which a forced command cannot filter simply.
`scp -O` uses the classic protocol, where the server runs `scp -t <dir>` - a command the gate can
check and rebuild itself. `transfer.sh` adds `-O` automatically when your `scp` supports it.

## Restoring from the server

The backup key is **write-only on purpose**, so it cannot download anything. To restore, log in to
the server as *yourself* (admin) and copy the archives from `store/`:

```bash
scp -r you@SERVER_IP:/srv/backups/myhost/store ./from-server
bin/restore.sh --dir ./from-server --to /tmp/restored
```

## Honest limits (what this does NOT protect against)

- **Backups are not encrypted** on the server. Whoever has admin access to the server can read them.
- **Old backups on the server are never deleted automatically** (local retention only, for now).
- If the *client* is fully compromised, an attacker can still upload junk into `incoming/`
  (it never reaches `store/` without a valid checksum, but it could fill the disk).
- Keep a second copy somewhere else for important data (the "3-2-1 rule").

## Troubleshooting

| Symptom | Check |
|---|---|
| `Permission denied (publickey)` | `SSH_KEY` path; `authorized_keys` line is ONE line; permissions 700/600; user is not locked |
| `Host key verification failed` | run the manual `ssh ... ping` once (step 5) |
| `backup-gate is not installed` | step 2 and the `command=` path in `authorized_keys` |
| Works by hand, fails in cron | use absolute paths; run cron as the same user that owns the key |
| `verify` fails with code 2 | a *different* file with that name is already in `store/` - investigate before deleting anything |
