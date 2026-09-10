#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
OUT="${1:-cursor-usage-menubar}"
swiftc -O -framework AppKit -framework ServiceManagement -lsqlite3 \
  -o "$OUT" main.swift
echo "built: $(pwd)/$OUT"
