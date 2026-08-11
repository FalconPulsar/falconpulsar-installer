#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 FalconPulsar Contributors
#
# Asserts the installer wizard's navigation rules against the REAL
# InstallerState.swift — no GUI, no clicking, runs anywhere Swift does.
#
# It exists because a race shipped: the "Existing Installation Detected" page
# was skipped whenever detection had not answered yet, so an operator faster
# than a `du` over a 34GB stack directory was routed into a fresh install.
# The harness is compiled rather than mocked so it cannot drift from the file
# it is guarding.
set -euo pipefail
cd "$(dirname "$0")/.."
out="$(mktemp -d)/statecheck"
swiftc -o "$out" \
    FalconPulsarInstaller/InstallerState.swift \
    FalconPulsarInstaller/ShellRunner.swift \
    statecheck/main.swift
"$out"
