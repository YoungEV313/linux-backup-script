#!/usr/bin/env python3
"""tools/report.py - list backups and verify their SHA-256 checksums.

Usage: report.py [BACKUP_DIR] [--json]
Exit code is 1 if any archive is missing its checksum file or fails verification.
"""
import argparse
import hashlib
import json
import re
import sys
from datetime import datetime
from pathlib import Path

NAME_RE = re.compile(r"^(?P<name>.+)_(?P<ts>\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2})_(?P<type>full|incremental)\.tar\.gz$")


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def check(archive: Path) -> str:
    sum_file = archive.with_name(archive.name + ".sha256")
    if not sum_file.exists():
        return "NO-CHECKSUM"
    expected = sum_file.read_text().split()[0]
    return "OK" if sha256(archive) == expected else "CORRUPT"


def main() -> int:
    default_dir = Path(__file__).resolve().parent.parent / "backups"
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("backup_dir", nargs="?", type=Path, default=default_dir)
    ap.add_argument("--json", action="store_true", help="machine-readable output")
    args = ap.parse_args()

    rows = []
    for archive in sorted(args.backup_dir.glob("*.tar.gz")):
        m = NAME_RE.match(archive.name)
        rows.append({
            "file": archive.name,
            "type": m["type"] if m else "?",
            "created": datetime.strptime(m["ts"], "%Y-%m-%d_%H-%M-%S").isoformat(sep=" ") if m else "?",
            "size_bytes": archive.stat().st_size,
            "status": check(archive),
        })

    if args.json:
        print(json.dumps(rows, indent=2))
    else:
        print(f"{'TYPE':<12} {'CREATED':<19} {'SIZE':>10}  {'STATUS':<11} FILE")
        for r in rows:
            print(f"{r['type']:<12} {r['created']:<19} {r['size_bytes']:>10}  {r['status']:<11} {r['file']}")
        print(f"\n{len(rows)} archive(s) in {args.backup_dir}")

    return 0 if all(r["status"] == "OK" for r in rows) else 1


if __name__ == "__main__":
    sys.exit(main())
