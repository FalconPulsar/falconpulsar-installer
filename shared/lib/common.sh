#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 FalconPulsar Contributors

# =============================================================================
# common.sh — Shared bash helpers for the FalconPulsar installers.
#
# Provides:
#   - Coloured logging (info / warn / error / success / step)
#   - die / require_cmd / on_error trap helpers
#   - confirm()           — yes/no prompt
#   - run_as_user()       — re-exec a command as another user (linux only)
#   - random_password()   — generate a strong default admin password
#   - is_root / require_root / require_not_root
#   - source_guard        — prevents double-sourcing
#
# This file is sourced by linux/install.sh, macos/install.sh and their
# uninstall counterparts. It MUST remain POSIX-bash-4-compatible (no bash 5
# features) because RHEL 9 still ships bash 4.x.
# =============================================================================

# Source guard
if [ -n "${__FP_COMMON_SH_LOADED:-}" ]; then
    return 0
fi
__FP_COMMON_SH_LOADED=1

# Strict mode (callers may relax this if needed)
set -o errexit
set -o nounset
set -o pipefail

# ── Colours ──────────────────────────────────────────────────────────────────
# Disable colours when stdout is not a TTY or when NO_COLOR is set
# (https://no-color.org/).
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    FP_C_RESET=$'\033[0m'
    FP_C_BOLD=$'\033[1m'
    FP_C_DIM=$'\033[2m'
    FP_C_RED=$'\033[31m'
    FP_C_GREEN=$'\033[32m'
    FP_C_YELLOW=$'\033[33m'
    FP_C_BLUE=$'\033[34m'
    FP_C_CYAN=$'\033[36m'
else
    FP_C_RESET=''
    FP_C_BOLD=''
    FP_C_DIM=''
    FP_C_RED=''
    FP_C_GREEN=''
    FP_C_YELLOW=''
    FP_C_BLUE=''
    FP_C_CYAN=''
fi

# ── Logging ──────────────────────────────────────────────────────────────────
# All log output goes to stderr so that scripts using stdout for data
# (e.g. echo a generated password) still work.

log_info()    { printf '%s[info]%s %s\n'    "${FP_C_BLUE}"   "${FP_C_RESET}" "$*" >&2; }
log_warn()    { printf '%s[warn]%s %s\n'    "${FP_C_YELLOW}" "${FP_C_RESET}" "$*" >&2; }
log_error()   { printf '%s[error]%s %s\n'   "${FP_C_RED}"    "${FP_C_RESET}" "$*" >&2; }
log_success() { printf '%s[ok]%s %s\n'      "${FP_C_GREEN}"  "${FP_C_RESET}" "$*" >&2; }
log_step()    { printf '\n%s==>%s %s%s%s\n' "${FP_C_CYAN}"   "${FP_C_RESET}" "${FP_C_BOLD}" "$*" "${FP_C_RESET}" >&2; }
log_debug() {
    if [ "${FP_DEBUG:-0}" = "1" ]; then
        printf '%s[debug]%s %s\n' "${FP_C_DIM}" "${FP_C_RESET}" "$*" >&2
    fi
}

# ── Error handling ───────────────────────────────────────────────────────────
die() {
    log_error "$*"
    exit 1
}

# Trap helper — install with: trap 'on_error $LINENO' ERR
on_error() {
    local line="${1:-?}"
    log_error "installer failed at line ${line} (exit $?)"
    log_error "see the lines above for details. To re-run with verbose output:"
    log_error "    FP_DEBUG=1 bash $0"
    exit 1
}

# ── Command / privilege checks ──────────────────────────────────────────────
require_cmd() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        die "required command not found: ${cmd}"
    fi
}

is_root() {
    [ "$(id -u)" -eq 0 ]
}

require_root() {
    is_root || die "this step must run as root (try: sudo bash $0)"
}

# Returns 0 if we are running inside a WSL distro. WSL exposes itself via
# two independent markers; either is sufficient.
is_wsl() {
    [ -e /proc/sys/fs/binfmt_misc/WSLInterop ] && return 0
    grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null
}

require_not_root() {
    if is_root; then
        die "do not run this as root — the installer will use sudo where needed"
    fi
}

# ── User interaction ─────────────────────────────────────────────────────────
# confirm "question" [default-yes|default-no]
# Returns 0 for yes, 1 for no. Under FP_ASSUME_YES=1 (CI / unattended) the
# prompt resolves to its stated default: default-yes → yes, default-no → no.
# Default-no marks prompts whose "yes" is destructive (delete data, remove
# a user) — unattended runs must opt into those via an explicit flag
# (e.g. uninstall --purge), never through a blanket --yes.
confirm() {
    local prompt="$1"
    local default="${2:-default-no}"
    local hint reply

    if [ "${FP_ASSUME_YES:-0}" = "1" ]; then
        if [ "$default" = "default-yes" ]; then
            log_debug "confirm: '${prompt}' → yes (FP_ASSUME_YES=1)"
            return 0
        fi
        log_debug "confirm: '${prompt}' → no (FP_ASSUME_YES=1 resolves default-no prompts to no)"
        return 1
    fi

    case "$default" in
        default-yes) hint="[Y/n]" ;;
        *)           hint="[y/N]" ;;
    esac

    printf '%s%s %s%s ' "${FP_C_BOLD}" "${prompt}" "${hint}" "${FP_C_RESET}" >&2
    read -r reply || reply=''

    if [ -z "$reply" ]; then
        [ "$default" = "default-yes" ]
        return $?
    fi

    case "$reply" in
        y|Y|yes|YES|Yes) return 0 ;;
        *)               return 1 ;;
    esac
}

# ── Privilege re-execution ───────────────────────────────────────────────────
# run_as_user <user> <cmd> [args...]
# Re-exec a command as another local user. Used to drop from root to the
# falconpulsar user when issuing `docker compose` calls.
run_as_user() {
    local target="$1"
    shift
    if [ "$(id -un)" = "$target" ]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo -u "$target" -H -- "$@"
    else
        su - "$target" -c "$(printf '%q ' "$@")"
    fi
}

# ── Password / token generation ─────────────────────────────────────────────
# random_password [length]
# Defaults to 24 characters. URL-safe base64 alphabet, avoids confusing chars.
random_password() {
    local len="${1:-24}"
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -base64 32 \
            | tr -d '/+=\n' \
            | head -c "$len"
        echo
    elif [ -r /dev/urandom ]; then
        LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom \
            | head -c "$len"
        echo
    else
        die "no random source available (need openssl or /dev/urandom)"
    fi
}

# ── Path / OS helpers ────────────────────────────────────────────────────────
script_dir() {
    # Resolve the directory of the *calling* script (not this lib).
    cd -- "$(dirname -- "${BASH_SOURCE[1]}")" && pwd
}

# Detect host OS family. Echoes one of: linux, macos, wsl, unknown.
detect_os() {
    case "$(uname -s 2>/dev/null)" in
        Linux)
            if grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then
                echo wsl
            else
                echo linux
            fi
            ;;
        Darwin)  echo macos ;;
        *)       echo unknown ;;
    esac
}

# fp_compose_pull_with_retry <home> [attempts] [run_as_user]
#   Run `docker compose pull` up to `attempts` times with exponential-ish
#   backoff (2s, 4s, 8s). Returns 0 on any successful attempt, non-zero
#   after all retries fail. If `run_as_user` is set, re-execs via
#   `sudo -u $user -g docker -H bash -c` (Linux install path); otherwise
#   runs directly (macOS / non-system-user install).
#
# The -g docker flag sets egid to the docker group for the call's
# duration, which lets the freshly-created falconpulsar user reach
# docker.sock without an intervening logout/login. Previously we used
# `sg docker` for this, but /usr/bin/sg is missing on some minimal
# Ubuntu cloud images even with the `login` package installed.
#
# Used by install.sh and existing.sh's upgrade fast-path so a transient
# network flap doesn't abort the install and force the user to start over.
# fp_pull_docker_config
#   Print a DOCKER_CONFIG directory that is safe to pull with.
#
# ── UNCONDITIONAL, AFTER THREE FAILED ATTEMPTS AT BEING CLEVER ────────────
# This used to look for a credsStore and override only when it found one.
# That failed on the reporting machine for a reason worth writing down: the
# detection runs HERE, as root, and inspects root's view — but the pull runs
# as the SERVICE USER via `sudo -u <user> -H`, which reads THAT user's
# config. The file that breaks the pull was never the file being inspected.
# The alpha.72 log proved it the same way alpha.71's did: the "helper-free
# config" line never printed, so the detector had found nothing while the
# pull was still dying on `docker-credential-desktop.exe`.
#
# So the detection is gone. The images this installer pulls are PUBLIC — the
# registry probe two steps earlier proves it anonymously on every run — and a
# pull that needs no credentials is strictly safer with a config that offers
# none. There is exactly ONE case worth preserving: a config carrying an
# INLINE `auth` token, i.e. a real `docker login` to a private registry.
#
# Set FP_KEEP_DOCKER_CREDS=1 to opt out entirely and use the ambient config.
#
# ── WHY THIS EXISTS, AND WHY THE FIRST ATTEMPT MISSED ─────────────────────
# On Docker Desktop the config.json the CLI reads contains
#
#     { "auths": {}, "credsStore": "desktop.exe" }
#
# which is a POINTER TO THE HOST'S KEYCHAIN, not a credential. The CLI runs
# that helper for every registry call — including an anonymous pull of a
# PUBLIC image — and inside WSL that means exec'ing a Windows .exe as a Linux
# service user:
#
#     /usr/bin/docker-credential-desktop.exe: Invalid argument
#     error getting credentials - err: exit status 1
#
# An earlier attempt sanitised the config where it was COPIED from root to the
# service user. It fixed nothing, and the log proved it by printing none of
# its new lines: on the reporting machine root had NO config.json, so the
# copy — and the sanitiser guarding it — never ran at all. The offending file
# was Docker Desktop's own, written by its WSL integration somewhere the copy
# never looked.
#
# The lesson is the fix: do not chase WHERE the bad config lives. Override
# what the pull READS, at the point of use.
#
# A config carrying an INLINE `auth` token is left alone — that is a real
# login to a private registry, and dropping it to fix a lookup would trade one
# failure for a worse one.
fp_pull_docker_config() {
    [ "${FP_KEEP_DOCKER_CREDS:-0}" = "1" ] && return 0
    local candidate found=''
    # Same order the docker CLI resolves in: explicit DOCKER_CONFIG, the
    # invoking user's home, then root's (this runs under sudo).
    for candidate in "${DOCKER_CONFIG:-}" "${HOME:-}/.docker" /root/.docker; do
        [ -n "$candidate" ] || continue
        [ -f "${candidate}/config.json" ] || continue
        found="${candidate}/config.json"
        break
    done
    # An INLINE `auth` token is a real login to a private registry. Keep the
    # ambient config in that one case, and only that one.
    if [ -n "$found" ] && grep -q '"auth"[[:space:]]*:' "$found" 2>/dev/null; then
        return 0
    fi
    local dir
    dir="$(mktemp -d /tmp/fp-dockercfg.XXXXXX)" || return 0
    printf '{}\n' > "${dir}/config.json"
    # World-readable on purpose: the pull runs as the SERVICE user, who cannot
    # read a 0700 directory owned by root. A file containing `{}` has nothing
    # to protect.
    chmod 0755 "$dir"
    chmod 0644 "${dir}/config.json"
    printf '%s\n' "$dir"
}

fp_compose_pull_with_retry() {
    local home="$1"
    local attempts="${2:-3}"
    local run_as="${3:-}"
    local attempt=0
    local rc
    # Decided ONCE, outside the retry loop. Retrying an identical credential
    # failure three times is exactly what the failing logs were full of.
    local cfg_dir cfg_prefix=''
    cfg_dir="$(fp_pull_docker_config)"
    # Logged on BOTH branches, deliberately. Twice now a fix has shipped, run,
    # and been invisible in the log because it only spoke when it acted — so
    # "did it run?" and "what did it decide?" could not be told apart from a
    # user's report. A line that always prints answers both.
    if [ -n "$cfg_dir" ]; then
        cfg_prefix="DOCKER_CONFIG='${cfg_dir}' "
        log_info "pulling with a helper-free docker config (${cfg_dir}) — the images are public and a credential helper cannot run for the service user"
    else
        log_info "pulling with the ambient docker config (an inline registry login was found, or FP_KEEP_DOCKER_CREDS=1)"
    fi
    while [ "$attempt" -lt "$attempts" ]; do
        attempt=$((attempt + 1))
        # `rc=0; ( ... ) || rc=$?` keeps a failed attempt from tripping
        # errexit — callers run under `set -o errexit`, and a bare
        # subshell exiting non-zero would abort the whole script before
        # the retry loop ever gets a second attempt.
        rc=0
        if [ -n "$run_as" ]; then
            # DOCKER_CONFIG goes INSIDE the command string deliberately: sudo's
            # env_reset drops it from the environment, so exporting it in the
            # caller would never reach the pull.
            ( sudo -u "$run_as" -g docker -H bash -c "cd '${home}' && ${cfg_prefix}docker compose pull" ) || rc=$?
        else
            ( cd "$home" && env ${cfg_dir:+DOCKER_CONFIG="$cfg_dir"} docker compose pull ) || rc=$?
        fi
        if [ "$rc" = 0 ]; then
            return 0
        fi
        if [ "$attempt" -lt "$attempts" ]; then
            local delay=$((2 ** attempt))
            log_warn "docker compose pull failed (attempt $attempt/$attempts) — retrying in ${delay}s"
            sleep "$delay"
        fi
    done
    return "${rc:-1}"
}

# fp_rotate_log <path> [max_bytes] [keep]
#   Rotate the install log if it's larger than max_bytes (default 5 MiB).
#   Keeps the last N archives (default 3) as .1 .2 .3. Silent + best-effort:
#   any failure (permission, disk full) leaves the original in place.
#   Also ensures the (possibly new) log file is mode 0600 — it contains
#   admin usernames and partial error output.
fp_rotate_log() {
    local path="$1"
    local max="${2:-5242880}"   # 5 MiB
    local keep="${3:-3}"
    [ -n "$path" ] || return 0
    if [ -f "$path" ]; then
        local size
        # stat flags differ between BSD (macOS) and GNU (Linux).
        size=$(stat -f%z "$path" 2>/dev/null || stat -c%s "$path" 2>/dev/null || echo 0)
        if [ "${size:-0}" -gt "$max" ] 2>/dev/null; then
            local i=$((keep - 1))
            # Shift archives up: .N-1 -> .N, ..., .1 -> .2
            while [ "$i" -ge 1 ]; do
                if [ -f "${path}.${i}" ]; then
                    mv -f "${path}.${i}" "${path}.$((i + 1))" 2>/dev/null || true
                fi
                i=$((i - 1))
            done
            mv -f "$path" "${path}.1" 2>/dev/null || true
        fi
    fi
    if [ ! -f "$path" ]; then
        (umask 077 && : > "$path") 2>/dev/null || true
    fi
    chmod 0600 "$path" 2>/dev/null || true
}

# fp_docker <args...>
#
# Run docker wherever it can actually reach the daemon, and REMEMBER which.
#
# Root is not guaranteed to have docker access. On WSL with Docker Desktop
# integration the socket is granted to the human/service user, not to root --
# and the installer body runs as root while every real docker command goes
# through `run_as_user "$FP_USER" docker ...`.
#
# The checks did not. They called bare `docker info`, got a failure, and
# returned "nothing here":
#
#   fp_detect_phantom_containers  -> "no orphaned FalconPulsar containers"
#                                    while containers were plainly running
#   fp_port_held_by_our_stack     -> our own Core's ports looked FOREIGN,
#                                    so the port check aborted the upgrade
#
# Both failures are silent and both say the reassuring thing, which is how an
# upgrade could report "no orphans" and "port conflict" about the same
# containers in the same run.
#
# Returns non-zero when no context can reach docker, so callers keep their
# existing "docker unavailable" behaviour.
_FP_DOCKER_MODE=""
fp_docker() {
    if [ -z "${_FP_DOCKER_MODE:-}" ]; then
        if docker info >/dev/null 2>&1; then
            _FP_DOCKER_MODE="direct"
        elif [ -n "${FP_USER:-}" ] && run_as_user "$FP_USER" docker info >/dev/null 2>&1; then
            _FP_DOCKER_MODE="user"
        else
            _FP_DOCKER_MODE="none"
        fi
    fi
    case "$_FP_DOCKER_MODE" in
        direct) docker "$@" ;;
        user)   run_as_user "$FP_USER" docker "$@" ;;
        *)      return 1 ;;
    esac
}

# fp_repair_bind_sources <home>
#
# Undo what Docker does to MISSING bind-mount sources, before anything mounts
# them again.
#
# When `docker compose up` meets a bind mount whose SOURCE does not exist, it
# creates the source — always as a ROOT-OWNED DIRECTORY, regardless of what
# the destination is. One behaviour, two failures:
#
#   ai-engine crash-looping on
#       Error: EACCES: permission denied, mkdir '/data/db'
#     because ${FP_ENGINE_DATA_DIR} was created root:root while the container
#     runs as ${FP_UID}:${FP_GID}.
#
#   every service failing to start on
#       dst=/config/auth-policy.json ... not a directory: Are you trying to
#       mount a directory onto a file (or vice-versa)?
#     because auth-policy.json is mounted AS A FILE (compose.yml:372) but did
#     not exist, so Docker made a directory of that name.
#
# It only takes one `compose up` before the installer writes those paths: a
# tray "Start Stack", an `fp update --apply`, or an install that died early.
# And it is self-perpetuating — `install -d` is perfectly happy with an
# existing directory, so re-running never repaired it.
#
# Lives here rather than in linux/install.sh because BOTH paths need it and
# only one of them used to have it: the upgrade fast-path pulls and runs
# `compose up -d` then `exit 0`s long before the installer's data-dir block.
# An upgrade over a broken stack would otherwise have stayed broken.
#
# Reads FP_USER, FP_DATA_DIR, FP_GATEWAY_DATA_DIR, FP_ENGINE_DATA_DIR,
# FP_COPILOT_DATA_DIR and FP_GATEWAY_CONFIG from the environment; each is
# skipped when unset. Best-effort throughout: never abort an install for it.
fp_repair_bind_sources() {
    local home="${1:-$FP_HOME}"
    [ -n "$home" ] || return 0

    local d f owner="${FP_USER:-}"

    # Directory sources: replace a non-directory, then RE-ASSERT ownership.
    # `install -d` does not chown an existing directory, which is exactly why
    # Docker's root:root survived every re-install.
    for d in "${FP_DATA_DIR:-}" \
             "${FP_GATEWAY_DATA_DIR:-}" \
             "${FP_ENGINE_DATA_DIR:-}" \
             "${FP_COPILOT_DATA_DIR:-}"; do
        [ -n "$d" ] || continue
        if [ -e "$d" ] && [ ! -d "$d" ]; then
            log_warn "bind source ${d} is not a directory — replacing it"
            rm -f "$d" 2>/dev/null || true
        fi
        [ -d "$d" ] || mkdir -p "$d" 2>/dev/null || true
        if [ -n "$owner" ] && [ -d "$d" ]; then
            chown -R "${owner}:${owner}" "$d" 2>/dev/null || true
            chmod 0750 "$d" 2>/dev/null || true
        fi
    done

    # File sources: a Docker-made DIRECTORY of that name has to go before the
    # file can be written. ONLY a directory is removed — an operator's
    # hand-edited gateway.yaml is a file and is left exactly alone.
    for f in "${home}/nginx.conf" \
             "${FP_GATEWAY_CONFIG:-${home}/gateway.yaml}" \
             "${home}/auth-policy.json"; do
        if [ -d "$f" ]; then
            log_warn "$(basename "$f") exists as a DIRECTORY (Docker created it for a missing bind mount) — removing"
            rm -rf "$f" 2>/dev/null || true
        fi
    done

    # auth-policy.json must EXIST, not merely "not be a directory".
    #
    # Removing the directory was not enough and the log proved it: the repair
    # ran, found nothing to remove (the file was simply ABSENT), and the very
    # next `compose up` had Docker invent the directory again. Same mount
    # error, same failed upgrade.
    #
    # The reason it is absent is structural. The upgrade fast-path REFRESHES
    # compose.yml — and the current compose.yml mounts auth-policy.json — but
    # nothing on that path ever wrote the file. fp_write_auth_policy lives in
    # the full installer, hundreds of lines after the fast-path exits. So any
    # stack created before auth-policy.json existed could never upgrade: it
    # got a compose.yml demanding a file its own installer never made.
    #
    # Carry the recorded auth settings forward from the stack's .env so an
    # SSO-configured install is not silently reset to local-only.
    if [ ! -f "${home}/auth-policy.json" ] \
       && command -v fp_write_auth_policy >/dev/null 2>&1; then
        local _m _p
        if [ -f "${home}/.env" ]; then
            _m="$(sed -n 's/^FP_AUTH_MODE=//p' "${home}/.env" | tail -n1 | tr -d '\r')"
            _p="$(sed -n 's/^FP_SSO_PROVIDER=//p' "${home}/.env" | tail -n1 | tr -d '\r')"
            # Exported, not just assigned: fp_write_auth_policy reads them
            # from the environment, and it lives in prompts.sh — shellcheck
            # cannot see across files, so a bare assignment reads as dead.
            if [ -n "${_m:-}" ]; then export FP_AUTH_MODE="$_m"; fi
            if [ -n "${_p:-}" ]; then export FP_SSO_PROVIDER="$_p"; fi
        fi
        log_warn "auth-policy.json is missing — writing it (compose mounts it as a file; Docker would create a directory)"
        fp_write_auth_policy "${home}/auth-policy.json"
    fi
}
