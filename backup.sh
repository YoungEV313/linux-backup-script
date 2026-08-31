#!/bin/bash
bc="/root/linux-backup-project/data"
name="daily_backup"

log_dir="/root/linux-backup-project/logs"
mkdir -p "$log_dir"
log_file="$log_dir/backup.log"

timee=$(date +%Y-%m-%d_%H-%M-%S)
real="${name}_${timee}.tar.gz"
backup_dir="/root/linux-backup-project/backups"
mkdir -p "$backup_dir"

echo "$(date +%Y-%m-%d\ %H:%M:%S) - Backup started for '$bc' -> $real" >> "$log_file"

tar_output=$(tar -czvf "$backup_dir/$real" "$bc" 2>&1)
tar_status=$?

if [ $tar_status -eq 0 ]; then
    echo "$(date +%Y-%m-%d\ %H:%M:%S) - Backup SUCCESS: $real" >> "$log_file"
    echo "Backup succeeded: $real"
else
    rm -f "$backup_dir/$real"
    echo "$(date +%Y-%m-%d\ %H:%M:%S) - Backup FAILED: $real" >> "$log_file"
    echo "$(date +%Y-%m-%d\ %H:%M:%S) - Error details: $tar_output" >> "$log_file"
    echo "Backup failed!"
fi
