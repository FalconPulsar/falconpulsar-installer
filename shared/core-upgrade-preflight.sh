#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-only
# Read-only compatibility guard for the WAL-identity storage transition.
# This reads 256-byte headers, never historical payloads or credentials. It is
# deliberately conservative: legacy history needs an explicit recovery choice.
set -eu
root=${1:-/data}
if [ ! -d "$root" ] || [ ! -r "$root" ]; then
  echo 'Cannot read the Core data directory.' >&2
  exit 2
fi
[ -d "$root/fractal" ] || exit 0
find "$root/fractal" -type f -name '*.fpf' -exec sh -c '
  for partition do
    size=$(head -c 256 "$partition" | wc -c)
    [ "$size" -eq 256 ] || { echo "Incomplete partition header: $partition" >&2; exit 2; }
    magic=$(dd if="$partition" bs=1 count=8 2>/dev/null)
    [ "$magic" = FPFILE01 ] || { echo "Unknown partition format: $partition" >&2; exit 2; }
    points=$(od -An -tu1 -j48 -N8 "$partition" | tr -d " 0\n")
    marker=$(dd if="$partition" bs=1 skip=248 count=4 2>/dev/null | od -An -tx1 | tr -d " \n")
    if [ -n "$points" ] && [ "$marker" != 574c5331 ]; then
      echo "Legacy partition without WAL identity: $partition" >&2
      echo "Upgrade stopped before container replacement. Recover configuration into a fresh database, or migrate a verified clean checkpoint on a copy to retain history." >&2
      exit 2
    fi
  done
' sh {} +
