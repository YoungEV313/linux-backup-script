# Linux Backup Project

A practical Linux administration project focused on creating and automating compressed backups using Bash.

## About

This project was created as a hands-on Linux learning project to practice Bash scripting, file management, archiving, compression, logging, error handling, and task automation.

The project contains a Bash script that creates compressed backups of a specified directory, records the result in a log file, and handles failed backup operations.

## Project Structure

```text
linux-backup-project/
│
├── backup.sh
│   └── Main Bash script for creating backups
│
├── data/
│   └── Directory containing test data
│
├── backups/
│   └── Generated backup files
│
└── logs/
    └── Backup operation logs
```

## Main Features

* Automated directory backup
* `tar` archive creation
* `gzip` compression
* Automatic date and time-based filenames
* Backup logging
* Error detection and logging
* Removal of incomplete backups
* Non-interactive execution
* Suitable for scheduling with `cron`

## Technologies

* Linux
* Bash
* tar
* gzip
* cron

## Purpose

The main purpose of this project is to gain practical experience with Linux system administration and Bash scripting by building a small but functional backup system from scratch.

## Status

Completed as a Linux administration practice project.
