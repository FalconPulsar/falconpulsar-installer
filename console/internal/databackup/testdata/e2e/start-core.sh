#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 FalconPulsar Contributors
# Start the e2e Core again on its data directory (FP_E2E_START_CMD runs it with
# docker exec).
cd /e2e && (nohup /build/falconpulsar-server -V -c /e2e/core/falconpulsar.toml -d /e2e/core \
  --bind 0.0.0.0 -p 7433 --ws-port 7434 --metrics-port 7435 --log-level info >> /e2e/core.log 2>&1 &
  echo $! > /e2e/core.pid)
