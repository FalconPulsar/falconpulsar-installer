#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 FalconPulsar Contributors
# Stop the e2e Core and wait until it has exited (FP_E2E_STOP_CMD runs it with
# docker exec). PID 1 in the e2e container is `sleep infinity`, which never
# reaps: an exited server stays a zombie, so a bare `kill -0` would wait
# forever. State Z counts as exited.
P=$(cat /e2e/core.pid)
kill -TERM "$P" 2>/dev/null || exit 0
for _ in $(seq 1 1800); do
  st=$(awk '/^State:/{print $2}' "/proc/$P/status" 2>/dev/null)
  if [ -z "$st" ] || [ "$st" = Z ]; then
    exit 0
  fi
  sleep 0.1
done
exit 1
