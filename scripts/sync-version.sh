#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 FalconPulsar Contributors

# sync-version.sh — propagate VERSION (repo root) into every hardcoded site.
#
# Source of truth:  ${REPO}/VERSION   (single line, e.g. "0.1.0")
#
# Idempotent: re-running with no version change is a no-op (no files touched).
# Portable:   uses POSIX `sed -E` + temp-file rewrite (works on BSD & GNU sed).
#
# Usage:
#   scripts/sync-version.sh             # rewrite all sites to match VERSION
#   scripts/sync-version.sh --check     # exit 1 if any site is out of sync
#                                       # (suitable for CI)
set -euo pipefail

# Resolve repo root from script location (handles symlinks via cd -P).
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "${SCRIPT_DIR}/.." && pwd)"

VERSION_FILE="${REPO_ROOT}/VERSION"
if [[ ! -f "${VERSION_FILE}" ]]; then
  echo "ERROR: ${VERSION_FILE} not found" >&2
  exit 2
fi

VERSION="$(tr -d '[:space:]' < "${VERSION_FILE}")"
if [[ -z "${VERSION}" ]]; then
  echo "ERROR: ${VERSION_FILE} is empty" >&2
  exit 2
fi
# Loose semver sanity check (must start with digit, contain dots).
if ! [[ "${VERSION}" =~ ^[0-9]+\.[0-9]+ ]]; then
  echo "ERROR: ${VERSION_FILE} content '${VERSION}' is not a semver" >&2
  exit 2
fi

CHECK_ONLY=0
if [[ "${1:-}" == "--check" ]]; then
  CHECK_ONLY=1
fi

# Each site: FILE | EXTENDED_REGEX | REPLACEMENT
# The regex captures everything except the version number (so the same regex
# matches whatever version is currently in the file). Replacement uses the
# target ${VERSION}. Patterns intentionally surround the version with enough
# context that they only match the intended hardcoded site.
SITES=(
  # Go: var Version = "X.Y.Z"   (was `const` until we added build-time
  # ldflags injection -- Go's `-ldflags -X` can override a `var` but
  # not a `const`, so the keyword had to change. The [a-z]+ character
  # class matches either keyword without using grouped alternation
  # (which BSD sed -E rejects with "parentheses not balanced").
  "console/internal/cli/cli.go|([a-z]+ Version = \")[^\"]+(\")|\\1${VERSION}\\2"

  # Go: "falconpulsar_version": "X.Y.Z",
  "console/internal/configbackup/backup.go|(\"falconpulsar_version\": +\")[^\"]+(\")|\\1${VERSION}\\2"

  # Inno Setup: #define MyAppVersion     "X.Y.Z"
  "windows/installer.iss|(#define +MyAppVersion +\")[^\"]+(\")|\\1${VERSION}\\2"
)
# The macOS menu-bar app (AppDelegate.swift + ConfigBackup.swift) and the
# Windows tray app (TrayApp.cs + ConfigBackup.cs) are NOT listed: they read
# their version at runtime from build-time stamping (CFBundleShortVersionString
# / assembly version), so there is no hardcoded literal to rewrite.

drift=0
changed=()
unchanged=()

for entry in "${SITES[@]}"; do
  IFS='|' read -r relpath regex replacement <<< "${entry}"
  abs="${REPO_ROOT}/${relpath}"

  if [[ ! -f "${abs}" ]]; then
    echo "ERROR: missing file ${abs}" >&2
    exit 2
  fi

  # A site whose pattern matches nothing leaves the file byte-identical —
  # indistinguishable from "already in sync". Fail loudly instead, so a
  # refactor that removes a hardcoded literal surfaces as a stale SITES
  # entry rather than a silent no-op.
  if ! grep -Eq "${regex}" "${abs}"; then
    echo "ERROR: pattern for ${relpath} matched nothing — stale SITES entry?" >&2
    exit 2
  fi

  tmp="$(mktemp)"
  # shellcheck disable=SC2016
  sed -E -e "s~${regex}~${replacement}~g" "${abs}" > "${tmp}"

  if cmp -s "${abs}" "${tmp}"; then
    rm -f "${tmp}"
    unchanged+=("${relpath}")
    continue
  fi

  # Verify the regex actually matched something — if the diff is non-empty but
  # the new file doesn't contain the target version, the pattern is wrong.
  if ! grep -q -F "${VERSION}" "${tmp}"; then
    echo "ERROR: regex for ${relpath} did not produce ${VERSION}" >&2
    rm -f "${tmp}"
    exit 2
  fi

  if [[ "${CHECK_ONLY}" -eq 1 ]]; then
    rm -f "${tmp}"
    drift=1
    echo "DRIFT: ${relpath} would be updated to ${VERSION}"
  else
    mv "${tmp}" "${abs}"
    changed+=("${relpath}")
    echo "updated  ${relpath}  → ${VERSION}"
  fi
done

if [[ "${CHECK_ONLY}" -eq 1 ]]; then
  if [[ "${drift}" -eq 1 ]]; then
    echo
    echo "Version drift detected. Run scripts/sync-version.sh to fix." >&2
    exit 1
  fi
  echo "All version sites match VERSION (${VERSION})."
  exit 0
fi

if [[ "${#changed[@]}" -eq 0 ]]; then
  echo "All ${#unchanged[@]} sites already at ${VERSION} — nothing to do."
else
  echo
  echo "Synced ${#changed[@]} file(s) to ${VERSION}; ${#unchanged[@]} already matched."
fi
