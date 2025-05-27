#!/bin/bash

LOGFILE="openrank_usage.log"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

PID=$(pgrep openrank-sdk)
if [ -n "$PID" ]; then
    # Get CPU and memory info using BSD/macOS-compatible ps
    INFO=$(ps -p "$PID" -o pid,comm,pcpu,pmem,rss,vsz | tail -n +2)
    echo "$TIMESTAMP $INFO" >> "$LOGFILE"
    echo "$INFO"
else
    echo "$TIMESTAMP Process 'openrank-sdk' not found." >> "$LOGFILE"
    echo "Process 'openrank-sdk' not found."
fi
