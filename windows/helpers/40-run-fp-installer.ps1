# =============================================================================
# 40-run-fp-installer.ps1 -- Run the bundled bash installer inside WSL.
#
# This is where Windows hands off to the Linux installer. We:
#
#   1. Resolve the WSL mount path of the install dir (C:\Program Files\
#      FalconPulsar -> /mnt/c/Program Files/FalconPulsar)
#   2. Copy the linux/ + shared/ trees from the Windows-side install dir
#      into /opt/falconpulsar-installer inside the distro (the live /mnt/c
#      mount has 9p performance issues and the bash installer creates
#      symlinks + 0600 files that don't survive on the NTFS layer)
#   3. Verify Docker Hub credentials are present in the distro (the bash
#      installer's check_dockerhub_login will catch this too, but we want
#      to fail fast with a clearer error if not)
#   4. Invoke /opt/falconpulsar-installer/linux/install.sh with --mode
#      docker --yes, passing the admin credentials via a temp env file
#      (NOT the command line -- argv is visible in /proc/<pid>/cmdline to
#      anyone on the machine)
# =============================================================================

[CmdletBinding()]
param(
    # Mandatory removed so a missing-arg crash is catchable by our trap +
    # surfaced via Write-FpLogLine instead of PowerShell's interactive
    # prompt that hangs/fails silently inside Inno Setup's SW_HIDE shell.
    [string] $Distro = '',
    [string] $InstallDir = '',
    [string] $AdminUser = '',
    [string] $AdminPass = '',
    [string] $Registry = 'falconpulsar',
    [string] $RegistryUser = '',
    [string] $RegistryPass = '',
    [switch] $RegistrySkip,
    # 'true' = HTTPS at front door (default, recommended).
    # 'false' = HTTP-only deployment; cookies emit without Secure flag.
    [string] $CookieSecure = 'true',
    # 'true' = install the optional AI Engine (agent runtime -- one extra
    # container via the compose 'engine' profile). Wired from the
    # 'aiengine' [Tasks] checkbox in installer.iss; default unchecked.
    # Exported to the bash installer as FP_AI_ENGINE_ENABLED on the
    # full-install path only -- the upgrade fast-path deliberately lets
    # the surviving .env value carry forward instead (see below).
    [string] $AiEngine = 'false',
    [string] $InstallAction = ''
)

$ErrorActionPreference = 'Stop'

# Trap MUST be installed before lib.ps1 dot-source -- if lib.ps1 itself
# has a parse error or a dependency miss, this is the only way to find
# out (PowerShell exits 1 silently otherwise). Direct file write because
# Write-FpLogLine isn't defined yet at this point.
$Script:EarlyLogPath = Join-Path $env:TEMP 'falconpulsar-install.log'
trap {
    $msg = $_.Exception.Message
    $where = $_.InvocationInfo.PositionMessage
    $stack = $_.ScriptStackTrace
    $line = "`n[error] 40-run-fp-installer.ps1 crashed: $msg`n[error] At: $where`n[error] Stack:`n$stack`n"
    try {
        Add-Content -Path $Script:EarlyLogPath -Value $line -ErrorAction SilentlyContinue
    } catch { }
    exit 1
}

# Heartbeat -- direct write before lib.ps1 is loaded.
try {
    Add-Content -Path $Script:EarlyLogPath -Value "`n==> 40-run-fp-installer.ps1 entered (PSVersion=$($PSVersionTable.PSVersion), Distro='$Distro', InstallDir='$InstallDir', AdminUser='$AdminUser')" -ErrorAction SilentlyContinue
} catch { }

. (Join-Path $PSScriptRoot 'lib.ps1')

# Manually validate the params we used to mark Mandatory.
foreach ($pair in @(
    @{Name='Distro';      Value=$Distro},
    @{Name='InstallDir';  Value=$InstallDir},
    @{Name='AdminUser';   Value=$AdminUser},
    @{Name='AdminPass';   Value=$AdminPass}
)) {
    if ([string]::IsNullOrEmpty($pair.Value)) {
        Stop-WithError "Required parameter -$($pair.Name) was not provided (got empty string)."
    }
}

Write-Step 'Running the FalconPulsar bash installer inside WSL'

# -- Sentinel: pick the right distro name -----------------------------------
$sentinel = Join-Path $env:TEMP 'falconpulsar-distro.txt'
if (Test-Path $sentinel) {
    $Distro = (Get-Content $sentinel -Raw).Trim()
    Write-Info "Using distro from sentinel: $Distro"
} else {
    # No sentinel -- query WSL for a compatible distro
    Write-Info "No sentinel file -- checking for compatible WSL distros"
    $compatibleDistros = @('Ubuntu-24.04', 'Ubuntu-22.04', 'Ubuntu', 'Debian')
    $found = $false
    foreach ($candidate in $compatibleDistros) {
        if (Test-WslDistroPresent -Name $candidate) {
            $Distro = $candidate
            $found = $true
            Write-Info "Found compatible distro: $Distro"
            break
        }
    }
    if (-not $found) {
        Stop-WithError "No compatible WSL distro found and no sentinel file. Run the installer from the beginning."
    }
}

if (-not (Test-WslDistroPresent -Name $Distro)) {
    Stop-WithError "Distro $Distro is not registered"
}

# -- WSL root access check --------------------------------------------------
# Verify we can run commands as root inside the distro. If the distro's
# default user is non-root and something overrides -u root, the bash
# installer will fail deep inside with confusing permission errors.
Write-Info "Verifying root access inside $Distro..."
$whoami = & wsl.exe -d $Distro -u root -- whoami 2>&1
if ($LASTEXITCODE -ne 0 -or "$whoami".Trim() -ne 'root') {
    Stop-WithError "Cannot run as root inside $Distro (got: $whoami). The distro may be corrupted -- try: wsl --unregister $Distro and re-run the installer."
}
Write-Info "Root access verified"

# -- Resolve the distro's default human user -------------------------------
# The bash installer runs in per-user mode on WSL: it installs the stack
# under /home/<user>/falconpulsar, owned by that user, with no dedicated
# `falconpulsar` system user. We need to know WHICH human user to install
# under. The WSL default user is the natural choice (what `wsl` spawns
# interactively).
Write-Info 'Resolving a non-root user (as root)...'
# Resolve the human user by reading /etc/passwd AS ROOT. We must NOT launch
# the distro as its DEFAULT user (the old `wsl -d $Distro -- whoami`): if
# wsl.conf's `[user] default=` points at a user that no longer exists, WSL
# crashes hard ("getpwnam(<user>) failed") and takes the whole installer
# down before it can do anything. Running as -u root always works (root is
# always resolvable) and is immune to a broken default. Picking the first
# UID>=1000 (not just 1000) also handles distros whose human user isn't at
# 1000. If none is found, the block below creates one -- which also REPAIRS
# a distro left pointing at a since-removed default user.
$resolveUserScript = @'
getent passwd | while IFS=: read -r name _ uid _ _ _ _; do
    if [ "$uid" -ge 1000 ] && [ "$uid" -lt 65534 ] && [ "$name" != "nobody" ]; then
        printf '%s\n' "$name"; break
    fi
done
'@
$resolveFile = Join-Path $env:TEMP 'fp-resolve-user.sh'
[System.IO.File]::WriteAllText($resolveFile, ($resolveUserScript -replace "`r", ''), (New-Object System.Text.UTF8Encoding $false))
$resolveWsl = ConvertTo-WslPath $resolveFile
$WslUser = & wsl.exe -d $Distro -u root -- bash $resolveWsl 2>$null
Remove-Item $resolveFile -ErrorAction SilentlyContinue
$WslUser = "$WslUser".Trim().Trim([char]0)
if ([string]::IsNullOrEmpty($WslUser) -or $WslUser -eq 'root') {
    # No human user exists. This is the normal state of a distro WE
    # provisioned: `wsl --install -d ... --no-launch` (20-install-distro.ps1)
    # deliberately skips Ubuntu's interactive first-run setup, which is the
    # only thing that creates a non-root user. So we create one ourselves --
    # the per-user install needs an owner. Idempotent: this branch only runs
    # when no non-root user was found, and useradd is guarded by `id -u`.
    # IMPORTANT: the user is named 'fpuser', NOT 'falconpulsar'. The fresh-
    # install cleanup below deliberately removes the LEGACY 'falconpulsar'
    # SYSTEM user (userdel falconpulsar) + /home/falconpulsar. If we named the
    # new human user 'falconpulsar' too, that cleanup would delete the very
    # user we just created -- which is exactly what happened, leaving the
    # installer's --user target missing and wsl.conf pointing at a ghost.
    Write-Info "No non-root user in $Distro -- creating 'fpuser'..."
    $mkUserScript = @'
set -e
U=fpuser
if ! id -u "$U" >/dev/null 2>&1; then
    useradd -m -s /bin/bash -U "$U"
fi
# sudo group (the installer runs `sudo -u $U ...`); passwordless to match
# what WSL's own first-user setup grants.
getent group sudo >/dev/null 2>&1 && usermod -aG sudo "$U"
mkdir -p /etc/sudoers.d   # not present on minimal images; set -e would abort
echo "$U ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/fpuser
chmod 0440 /etc/sudoers.d/fpuser
# docker group (the installer uses `sg docker`); create it if the Docker
# Desktop integration hasn't yet, then add the user.
getent group docker >/dev/null 2>&1 || groupadd docker
usermod -aG docker "$U"
# Make this the distro's default user so `wsl -d $Distro` and the fp CLI
# spawn as them on subsequent launches. REPLACE any existing default= (a
# prior install may have left it pointing at a since-removed user, which
# makes WSL unable to launch the default user at all).
if grep -q '^\[user\]' /etc/wsl.conf 2>/dev/null; then
    if grep -q '^default=' /etc/wsl.conf; then
        sed -i "s/^default=.*/default=$U/" /etc/wsl.conf
    else
        sed -i "/^\[user\]/a default=$U" /etc/wsl.conf
    fi
else
    printf '\n[user]\ndefault=%s\n' "$U" >> /etc/wsl.conf
fi
echo "[ok] created non-root user $U"
'@
    $mkRc = Invoke-WslBash -Distro $Distro -Script $mkUserScript -User root
    if ($mkRc -ne 0) {
        Stop-WithError "Failed to create a non-root user in $Distro (exit $mkRc)."
    }
    $WslUser = 'fpuser'
    Write-Info "Created and selected non-root user 'fpuser'"
}
$WslHome = "/home/$WslUser/falconpulsar"
Write-Info ("Install target: user='{0}', stack dir='{1}'" -f $WslUser, $WslHome)

# Write sentinels so fp.exe, the tray, the uninstaller, and future tools
# can locate the stack without re-discovering it.
$homeSentinel = Join-Path $env:TEMP 'falconpulsar-home.txt'
Set-Content -Path $homeSentinel -Value $WslHome -Encoding ASCII
$userSentinel = Join-Path $env:TEMP 'falconpulsar-user.txt'
Set-Content -Path $userSentinel -Value $WslUser -Encoding ASCII
Write-Info "Sentinels written: $homeSentinel, $userSentinel"

if ($AdminPass.Length -lt 10) {
    Stop-WithError 'Admin password is shorter than 10 characters (the credentials page should have caught this)'
}

# -- 1. Translate the Windows install dir to a /mnt/c/... path ---------------
$wslInstallDir = ConvertTo-WslPath -WindowsPath $InstallDir
Write-Info "Windows install dir: $InstallDir"
Write-Info "WSL mount path:      $wslInstallDir"

# -- 2. Stage installer files into /opt/falconpulsar-installer ---------------
$wslInstallDirEscaped = $wslInstallDir -replace "'", "'\''"

$stageScript = @"
set -e
rm -rf /opt/falconpulsar-installer
mkdir -p /opt/falconpulsar-installer
cp -a '$wslInstallDirEscaped/linux'  /opt/falconpulsar-installer/
cp -a '$wslInstallDirEscaped/shared' /opt/falconpulsar-installer/
# Strip Windows CRLF line endings from all text config files. The files
# were copied from NTFS (/mnt/c/) where Git (autocrlf) or Inno Setup may
# have converted them to CRLF. Bash chokes on \r in scripts, and the
# Python YAML loader in the ai-gateway container raises a ReaderError
# when it hits a stray \r in gateway.yaml -- the container exits 1 and
# `docker ps` shows a crash-loop. Strip CRLF from everything text-ish.
find /opt/falconpulsar-installer \
    \( -name '*.sh' -o -name '*.yml' -o -name '*.yaml' \
       -o -name '*.env' -o -name '*.conf' -o -name '*.template' \
       -o -name 'Dockerfile' \) \
    -type f -exec sed -i 's/\r$//' {} + 2>/dev/null || true
chmod +x /opt/falconpulsar-installer/linux/install.sh
chmod +x /opt/falconpulsar-installer/linux/uninstall.sh
chmod +x /opt/falconpulsar-installer/shared/lib/*.sh
echo '[info] installer staged at /opt/falconpulsar-installer'
"@
$rc = Invoke-WslBash -Distro $Distro -Script $stageScript -User root
if ($rc -ne 0) {
    Stop-WithError "Failed to stage installer files (exit $rc)"
}

# -- 3. Check for existing FalconPulsar installation -------------------------
# Probe both the NEW per-user stack dir (/home/<user>/falconpulsar) AND the
# LEGACY service-user dir (/home/falconpulsar) so upgrades from pre-refactor
# installs still get recognised.
#
# IMPORTANT: keep this on ONE line. PowerShell here-strings have CRLF
# newlines, and `wsl.exe ... bash -c <multi-line-string>` passes them
# through to bash, which then fails to parse the resulting if/elif/fi.
$existingProbe = "if [ -f '$WslHome/data/falconpulsar.toml' ] || [ -f '$WslHome/compose.yml' ]; then echo yes; elif [ -f /home/falconpulsar/data/falconpulsar.toml ] || [ -f /home/falconpulsar/compose.yml ]; then echo legacy; else echo no; fi"
$existingInstall = & wsl.exe -d $Distro -u root -- bash -c $existingProbe 2>$null
$existingInstall = "$existingInstall".Trim()
$hasExisting = ($existingInstall -eq 'yes' -or $existingInstall -eq 'legacy')
$hasLegacyInstall = ($existingInstall -eq 'legacy')

# If Inno Setup already determined the action, use it; otherwise default
# based on whether an existing install was found.
if (-not $InstallAction) {
    if ($hasExisting) { $InstallAction = 'upgrade' }
    else              { $InstallAction = 'fresh' }
}
Write-Info "Install action: $InstallAction"
Write-Info "AI Engine opt-in: $AiEngine"

if ($InstallAction -eq 'upgrade' -and $hasExisting -and -not $hasLegacyInstall) {
    Write-Info 'Upgrading in place -- delegating to the bundled bash installer'
    # The bash installer's upgrade fast-path (fp_try_upgrade_fastpath in
    # shared/lib/existing.sh) owns the in-place upgrade: it re-copies the
    # product-managed compose.yml + nginx.conf, provisions gateway.yaml if
    # missing, carries the existing secrets forward in .env, pulls the new
    # images (cleaning up displaced ones), restarts the stack, and
    # health-gates core + AI gateway. Delegating instead of re-implementing
    # the compose dance in PowerShell keeps the installer-driven upgrade
    # identical to the CLI-driven `fp update --apply`. When no usable stack
    # is found, install.sh falls through to a full install using the same
    # credentials.
    #
    # Credentials travel via a one-shot env file, same as the full-install
    # invocation below (argv is visible in /proc/<pid>/cmdline).
    $upgPw      = $AdminPass -replace "'", "'\''"
    $upgUser    = $AdminUser -replace "'", "'\''"
    $upgRegSkip = if ($RegistrySkip) { '1' } else { '0' }
    $upgradeScript = @"
set -e
umask 077
ENVFILE=`$(mktemp /root/fp-upgrade.env.XXXXXX)
trap 'rm -f "`$ENVFILE"' EXIT
# Quoted heredoc: bash writes these lines verbatim (PowerShell already
# interpolated the values), so a password containing dollar signs or
# backticks is neither expanded nor executed on the way into the env file.
# FP_REGISTRY is deliberately NOT exported here: compose gives process env
# precedence over the project .env, so exporting it would clobber a custom
# registry mirror recorded in the stack's .env during the in-place upgrade.
# FP_AI_ENGINE_ENABLED is deliberately NOT exported here for the same
# reason: the upgrade fast-path carries the stack's .env forward, so the
# engine opt-in recorded there survives untouched (sticky; never re-asked
# or clobbered on upgrade).
cat > "`$ENVFILE" <<'FPEOF'
export FP_ADMIN_USER='$upgUser'
export FP_ADMIN_PASS='$upgPw'
export FP_ASSUME_YES=1
export FP_LEGAL_ACCEPTED=1
export FP_REGISTRY_SKIP='$upgRegSkip'
export FP_INSTALL_ACTION='upgrade'
export FP_COOKIE_SECURE='$CookieSecure'
export FP_INVOKING_USER='$WslUser'
FPEOF
. "`$ENVFILE"
rm -f "`$ENVFILE"
trap - EXIT
bash /opt/falconpulsar-installer/linux/install.sh --user '$WslUser' --mode docker --yes
"@
    $rc = Invoke-WslBash -Distro $Distro -Script $upgradeScript -User root
    if ($rc -ne 0) {
        Stop-WithError "Upgrade failed inside WSL with exit code $rc."
    }
    Write-Output '[ok] FalconPulsar upgraded inside WSL'
    exit 0
}
if ($hasLegacyInstall) {
    Write-Info 'Legacy (service-user) install detected -- will migrate to per-user layout'
}

# For 'fresh' -- definitive WSL-side cleanup. This is the SUPERSET of what
# the bash installer's own "fresh" path would do. Running it UNCONDITIONALLY
# when action is 'fresh' guarantees no zombie containers, images, volumes,
# or networks are left to steal ports (e.g. 7436) before the bash
# installer's pre-flight port check runs.
#
# We don't gate on $hasExisting here because `hasExisting` only checks
# one file (/home/falconpulsar/data/falconpulsar.toml); there are many
# ways to have leftover Docker state without that file, which was
# causing port-conflict failures on supposedly-fresh installs.
if ($InstallAction -eq 'fresh') {
    Write-Info 'Fresh install -- wiping any prior FalconPulsar state inside WSL'

    # ── Step 1: wait for the Docker daemon to actually be reachable ───────
    # 30-launch-docker-desktop.ps1 launches Docker Desktop earlier in the
    # chain, but Docker Desktop's tray icon turning green != the daemon
    # accepting connections. On a cold install we routinely see 10-30s
    # between "icon green" and "docker info succeeds". If we run cleanup
    # before the daemon is up, every `docker rm/rmi/volume rm` returns
    # "Cannot connect to the Docker daemon" and the leftover state
    # survives -- the symptom users hit as "Fresh didn't actually clean."
    Write-Info 'Waiting for Docker Desktop daemon to be reachable inside WSL...'
    $waitScript = @"
deadline=`$(( `$(date +%s) + 60 ))
while [ "`$(date +%s)" -lt "`$deadline" ]; do
    if docker info >/dev/null 2>&1; then
        echo '[ok] docker daemon is responsive'
        exit 0
    fi
    sleep 2
done
echo '[warn] docker daemon did not respond within 60s -- cleanup will likely no-op'
exit 1
"@
    $waitRc = Invoke-WslBash -Distro $Distro -Script $waitScript -User root
    if ($waitRc -ne 0) {
        Write-Warning 'Docker daemon not reachable -- proceeding with cleanup anyway, but it may not remove existing state'
    }

    # ── Step 2: actual cleanup, with explicit counts logged ──────────────
    # Differences from the previous silent version:
    #   • compose-first: try `docker compose down --volumes --remove-orphans`
    #     before manual rm, so containers are torn down with their network
    #     and named volumes in coordinated fashion.
    #   • Each step counts what was removed and echoes the count, so the
    #     install log records `Removed N containers` instead of nothing.
    #   • set +e is only kept around the last legacy-cleanup section
    #     where some commands legitimately fail (e.g. userdel of a user
    #     that doesn't exist); active sections use explicit error handling.
    #   • Added: prune the falconpulsar Compose project network even if
    #     `docker network rm falconpulsar` doesn't match (Compose v2
    #     sometimes names the network `<project>_default`).
    $cleanScript = @"
set +e
removed_containers=0
removed_images=0
removed_volumes=0
removed_networks=0

# 2a. Prefer coordinated compose-down if a compose.yml still exists.
# --profile ai: legacy compose compat (pre-mandatory-gateway installs gated
# the ai-gateway behind an 'ai' profile); no-op on current stacks.
if [ -f '$WslHome/compose.yml' ]; then
    echo '[clean] running compose down --volumes --remove-orphans on existing stack'
    cd '$WslHome' && \
        sudo -u '$WslUser' -H sg docker -c \
            'docker compose --profile ai down --volumes --remove-orphans' 2>&1 | sed 's/^/[clean]   /'
fi
if [ -f /home/falconpulsar/compose.yml ]; then
    echo '[clean] running compose down --volumes on legacy service-user stack'
    cd /home/falconpulsar && \
        sudo -u falconpulsar -H sg docker -c \
            'docker compose --profile ai down --volumes --remove-orphans' 2>&1 | sed 's/^/[clean]   /'
fi

# 2b. Belt-and-braces: remove any falconpulsar-* container compose missed.
# docker info (not command -v): with WSL integration off there is a docker
# SHIM on PATH that command -v finds but that fails on every call, which would
# spray "could not be found in this WSL 2 distro" noise through this block.
if docker info >/dev/null 2>&1; then
    container_ids=`$(docker ps -a --filter 'name=falconpulsar-' -q 2>/dev/null)
    if [ -n "`$container_ids" ]; then
        removed_containers=`$(echo "`$container_ids" | wc -l | tr -d ' ')
        echo "[clean] removing `$removed_containers stray container(s)"
        echo "`$container_ids" | xargs -r docker rm -f 2>&1 | sed 's/^/[clean]   /'
    fi

    image_ids=`$(docker images --filter reference='*falconpulsar*' -q 2>/dev/null | sort -u)
    if [ -n "`$image_ids" ]; then
        removed_images=`$(echo "`$image_ids" | wc -l | tr -d ' ')
        echo "[clean] removing `$removed_images falconpulsar image(s)"
        echo "`$image_ids" | xargs -r docker rmi -f 2>&1 | sed 's/^/[clean]   /'
    fi

    volume_names=`$(docker volume ls --format '{{.Name}}' 2>/dev/null | grep -E '^falconpulsar')
    if [ -n "`$volume_names" ]; then
        removed_volumes=`$(echo "`$volume_names" | wc -l | tr -d ' ')
        echo "[clean] removing `$removed_volumes falconpulsar volume(s)"
        echo "`$volume_names" | xargs -r docker volume rm -f 2>&1 | sed 's/^/[clean]   /'
    fi

    # Compose v2 names the project network <project>_default; older
    # versions used the bare project name. Try both.
    for net in falconpulsar falconpulsar_default; do
        if docker network inspect "`$net" >/dev/null 2>&1; then
            echo "[clean] removing network `$net"
            docker network rm "`$net" 2>&1 | sed 's/^/[clean]   /'
            removed_networks=`$(( removed_networks + 1 ))
        fi
    done
fi

# 2c. Filesystem cleanup -- per-user stack dir + legacy service-user paths.
# NOTE: Windows-side artefacts (%LOCALAPPDATA%\falconpulsar, fp.exe in
# WindowsApps, %USERPROFILE%\falconpulsar, the Start Menu folder, the
# HKCU Run key) are intentionally NOT touched here. This script runs in
# ssPostInstall -- AFTER Inno Setup's [Files] section has just deposited
# fp.exe -- so wiping those would leave a working PATH entry pointing
# at a missing executable. Windows-side cleanup belongs in uninstall.ps1.
if [ -d '$WslHome' ]; then
    echo '[clean] removing per-user stack dir: $WslHome'
    rm -rf '$WslHome'
fi
if [ -e /home/falconpulsar ]; then
    echo '[clean] removing legacy service-user paths under /home/falconpulsar'
    rm -rf /home/falconpulsar/compose.yml /home/falconpulsar/.env \
           /home/falconpulsar/gateway.yaml /home/falconpulsar/bin \
           /home/falconpulsar/.docker /home/falconpulsar/ai-gateway-data \
           /home/falconpulsar/data /home/falconpulsar 2>/dev/null
fi
if id falconpulsar >/dev/null 2>&1; then
    echo '[clean] removing legacy `falconpulsar` system user'
    loginctl disable-linger falconpulsar 2>/dev/null
    userdel --force falconpulsar 2>/dev/null || true
fi
rm -f /etc/profile.d/falconpulsar.sh 2>/dev/null

# 2d. Final summary -- explicit, so the install log answers "did it actually
# remove anything?" without the user having to read every line.
echo "[clean] ──────────────────────────────────────────────────"
echo "[clean] Fresh-install cleanup summary:"
echo "[clean]   containers removed: `$removed_containers"
echo "[clean]   images removed:     `$removed_images"
echo "[clean]   volumes removed:    `$removed_volumes"
echo "[clean]   networks removed:   `$removed_networks"
echo "[clean] ──────────────────────────────────────────────────"
echo '[ok] WSL state wiped -- ready for fresh install'
"@
    $null = Invoke-WslBash -Distro $Distro -Script $cleanScript -User root
}

# For 'reinstall' -- lighter cleanup: stop the stack + remove the
# product-managed stack files (compose.yml, gateway.yaml -- re-provisioned
# by the bash installer), but KEEP the data dirs (database, ai-gateway
# data) AND .env: the linux installer's carry-forward reads FP_API_KEY /
# FP_GATEWAY_SECRET / FP_BRIDGE_TOKEN from it, so deleting .env would
# orphan the provider keys encrypted in the preserved gateway data.
# Matches macOS's "Reinstall (keep data)" behavior.
if ($InstallAction -eq 'reinstall') {
    Write-Info 'Reinstall -- stopping stack and rewriting files (database preserved)'
    $cleanScript = @"
set +e
# --profile ai: legacy compose compat (pre-mandatory-gateway installs gated
# the ai-gateway behind an 'ai' profile); no-op on current stacks.
if docker info >/dev/null 2>&1; then   # functional check, not the broken shim
    if [ -f '$WslHome/compose.yml' ]; then
        cd '$WslHome' && \
          sudo -u '$WslUser' -H sg docker -c 'docker compose --profile ai down --remove-orphans' 2>/dev/null
    fi
    if [ -f /home/falconpulsar/compose.yml ]; then
        cd /home/falconpulsar && \
          sudo -u falconpulsar -H sg docker -c 'docker compose --profile ai down --remove-orphans' 2>/dev/null
    fi
    docker ps -a --filter 'name=falconpulsar-' -q 2>/dev/null | xargs -r docker rm -f 2>/dev/null
fi
rm -f '$WslHome/compose.yml' '$WslHome/gateway.yaml'
rm -f /home/falconpulsar/compose.yml /home/falconpulsar/gateway.yaml 2>/dev/null
echo '[ok] Reinstall prep complete (database preserved)'
"@
    $null = Invoke-WslBash -Distro $Distro -Script $cleanScript -User root
}

# -- 3b. Post-cleanup port verification --------------------------------------
# The bash installer's step 1 pre-flight fails hard on ANY port conflict
# (7433/7434/7435/7436/8080). On Windows, WSL-side ss/lsof can't see the
# process holding a port because Docker Desktop binds it on the Windows
# host; that's why the bash error ends up blank after "port X is in use".
#
# We identify the holder here on the Windows side -- same INTENT as macOS
# (report who's holding the port so the user can remediate) but using
# Windows-native tools (Get-NetTCPConnection / tasklist / docker ps).
# If it's another Docker container we offer to stop it; if it's a native
# Windows process we report name+PID and tell the user to stop it.
$FpPorts = @(7433, 7434, 7435, 7436, 8080)
$Conflicts = @()
foreach ($p in $FpPorts) {
    $conn = Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue
    if ($conn) {
        $pid_ = ($conn | Select-Object -First 1).OwningProcess
        $procName = 'unknown'
        $procPath = ''
        try {
            $proc = Get-Process -Id $pid_ -ErrorAction Stop
            $procName = $proc.ProcessName
            try { $procPath = $proc.Path } catch { }
        } catch { }

        # If the holder looks like Docker Desktop's backend, find WHICH
        # container. docker inspect on all containers is cheap.
        $containerName = ''
        if ($procName -match '(?i)docker|com\.docker|wslhost|vpnkit') {
            try {
                $containers = & wsl.exe -d $Distro -u root -- bash -c `
                    "docker ps --format '{{.Names}}|{{.Ports}}' 2>/dev/null" 2>$null
                foreach ($line in $containers) {
                    if ($line -match "^([^|]+)\|.*:$p->") {
                        $containerName = $matches[1]
                        break
                    }
                }
            } catch { }
        }

        $Conflicts += [pscustomobject]@{
            Port          = $p
            Pid           = $pid_
            ProcessName   = $procName
            ProcessPath   = $procPath
            ContainerName = $containerName
        }
    }
}

if ($Conflicts.Count -gt 0) {
    Write-FpLogLine ''
    Write-FpLogLine '[error] Port conflicts detected after cleanup:'
    $summaryLines = @()
    $canAutoFix   = $true
    foreach ($c in $Conflicts) {
        if ($c.ContainerName) {
            $line = "  * Port $($c.Port) held by Docker container '$($c.ContainerName)'"
            $summaryLines += $line
            Write-FpLogLine "[error] $line"
        } else {
            $line = "  * Port $($c.Port) held by Windows process '$($c.ProcessName)' (PID $($c.Pid))"
            if ($c.ProcessPath) { $line += " at $($c.ProcessPath)" }
            $summaryLines += $line
            Write-FpLogLine "[error] $line"
            $canAutoFix = $false
        }
    }

    # If ALL conflicts are from other Docker containers, offer to stop them.
    # Otherwise we can only report -- killing arbitrary Windows processes
    # from an installer is unsafe (user might lose unsaved work, break
    # other services, etc.).
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    if ($canAutoFix) {
        $nonFpContainers = $Conflicts | Where-Object { $_.ContainerName }
        $names = ($nonFpContainers | ForEach-Object { $_.ContainerName } | Select-Object -Unique) -join ', '
        $msg = "FalconPulsar needs TCP ports $($FpPorts -join ', ') but the following Docker " +
               "container(s) currently use some of them:`n`n$($summaryLines -join "`n")`n`n" +
               "These are not part of FalconPulsar. Would you like the installer to STOP them now so the " +
               "install can proceed? (They will be removed with `docker rm -f`.)`n`n" +
               "Yes  -- stop the listed containers and retry`n" +
               "No   -- abort so you can stop them yourself"
        $choice = [System.Windows.Forms.MessageBox]::Show(
            $msg, 'Port conflict: non-FalconPulsar container(s)',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning)
        if ($choice -eq [System.Windows.Forms.DialogResult]::Yes) {
            foreach ($c in ($Conflicts | Where-Object { $_.ContainerName })) {
                Write-Info "Stopping container: $($c.ContainerName)"
                $null = & wsl.exe -d $Distro -u root -- bash -c `
                    "docker rm -f '$($c.ContainerName)' 2>&1" 2>&1
            }
        } else {
            Stop-WithError ("Port conflict not resolved. Containers still holding ports: $names")
        }
    } else {
        $msg = "FalconPulsar needs TCP ports $($FpPorts -join ', ') but the following are already in " +
               "use:`n`n$($summaryLines -join "`n")`n`n" +
               "The installer cannot safely kill native Windows processes -- stopping them might cause " +
               "data loss or break other applications.`n`n" +
               "Please stop the offending process(es) (via Task Manager or their own shutdown command), " +
               "then click OK to retry. Click Cancel to abort the install."
        $choice = [System.Windows.Forms.MessageBox]::Show(
            $msg, 'Port conflict: native Windows process(es)',
            [System.Windows.Forms.MessageBoxButtons]::OKCancel,
            [System.Windows.Forms.MessageBoxIcon]::Error)
        if ($choice -eq [System.Windows.Forms.DialogResult]::Cancel) {
            Stop-WithError "Install aborted due to unresolved port conflict"
        }
        # User chose OK -- they've (hopefully) stopped the processes.
        # Let the bash installer's step 1 port check be the final arbiter.
    }
}

# -- 4. Docker Desktop detection ---------------------------------------------
$dockerDesktopRunning = $false
if (Get-Process -Name 'Docker Desktop' -ErrorAction SilentlyContinue) {
    $dockerDesktopRunning = $true
    Write-Info 'Docker Desktop detected on host'
}

# FUNCTIONAL probe -- `docker info`, not `command -v docker`. With Docker
# Desktop installed but its WSL integration DISABLED for this distro, a docker
# SHIM sits on PATH: `command -v docker` finds it (so we'd think docker works)
# but every call fails with "could not be found in this WSL 2 distro". That
# made us SKIP the "enable WSL integration" guidance below and hand off to the
# bash installer, which then died cryptically at "checking for existing
# installation". `docker info` is true only when docker is actually usable.
$dockerInDistro = & wsl.exe -d $Distro -u root -- bash -c 'docker info >/dev/null 2>&1 && echo yes || echo no' 2>$null
$dockerAvailable = $false
if ($dockerInDistro) {
    $dockerAvailable = ($dockerInDistro.Trim() -eq 'yes')
}

if ($dockerDesktopRunning -and -not $dockerAvailable) {
    Stop-WithError @"
Docker Desktop is running on your Windows host, but its WSL Integration is
NOT enabled for the $Distro distro. The bash installer needs docker
to be available inside the distro.

To fix this:
  1. Open Docker Desktop
  2. Go to Settings -> Resources -> WSL Integration
  3. Toggle ON the integration for "$Distro"
  4. Click "Apply & Restart"
  5. Re-run FalconPulsar-Setup.exe

Alternatively, quit Docker Desktop entirely -- the FalconPulsar installer
will then install Docker Engine directly inside the distro via the
official get.docker.com script.
"@
}

# -- 5. Docker daemon verification -------------------------------------------
# If docker is installed but the daemon is not running (e.g. systemd just
# started), try to start it before handing off to the bash installer.
if ($dockerAvailable) {
    Write-Info "Checking if Docker daemon is responsive inside $Distro..."
    $dockerInfo = & wsl.exe -d $Distro -u root -- bash -c 'docker info >/dev/null 2>&1 && echo ok || echo fail' 2>$null
    if ($dockerInfo -and $dockerInfo.Trim() -eq 'fail') {
        Write-Info 'Docker is installed but daemon is not running -- starting it...'
        & wsl.exe -d $Distro -u root -- bash -c 'sudo systemctl start docker 2>/dev/null || sudo service docker start 2>/dev/null || true' 2>$null
        Start-Sleep -Seconds 3
        $dockerInfo2 = & wsl.exe -d $Distro -u root -- bash -c 'docker info >/dev/null 2>&1 && echo ok || echo fail' 2>$null
        if ($dockerInfo2 -and $dockerInfo2.Trim() -eq 'ok') {
            Write-Info 'Docker daemon started successfully'
        } else {
            Write-Warn 'Could not start Docker daemon -- the bash installer will try again'
        }
    } else {
        Write-Info 'Docker daemon is responsive'
    }
} else {
    Write-Info 'Docker not present in distro yet -- bash installer will install via get.docker.com'
}

# -- 6. Docker Hub credentials check -----------------------------------------
Write-Info '(Docker Hub login will be verified by the bash installer)'

# -- 7. Run the bash installer -----------------------------------------------
# Generate a one-shot env file with the admin password inside the distro.
# The password never appears on the command line (argv is visible in
# /proc/<pid>/cmdline). The file is deleted in the same bash invocation.
$pwEscaped   = $AdminPass -replace "'", "'\''"
$userEscaped = $AdminUser -replace "'", "'\''"
$regEscaped  = $Registry -replace "'", "'\''"
$regUserEscaped = $RegistryUser -replace "'", "'\''"
$regPassEscaped = $RegistryPass -replace "'", "'\''"
$regSkipVal = if ($RegistrySkip) { '1' } else { '0' }
# Normalize to exactly 'true'/'false' -- the value feeds the bash
# installer's COMPOSE_PROFILES=engine decision, so nothing fuzzy goes in.
$aiEngineVal = if ($AiEngine -eq 'true') { 'true' } else { 'false' }

$runScript = @"
set -e
umask 077
ENVFILE=`$(mktemp /root/fp-install.env.XXXXXX)
trap 'rm -f "`$ENVFILE"' EXIT
# Quoted heredoc: bash writes these lines verbatim (PowerShell already
# interpolated the values), so a password containing dollar signs or
# backticks is neither expanded nor executed on the way into the env file.
cat > "`$ENVFILE" <<'FPEOF'
export FP_ADMIN_USER='$userEscaped'
export FP_ADMIN_PASS='$pwEscaped'
export FP_ASSUME_YES=1
export FP_LEGAL_ACCEPTED=1
export FP_REGISTRY='$regEscaped'
export FP_REGISTRY_USER='$regUserEscaped'
export FP_REGISTRY_PASS='$regPassEscaped'
export FP_REGISTRY_SKIP='$regSkipVal'
export FP_INSTALL_ACTION='$InstallAction'
export FP_COOKIE_SECURE='$CookieSecure'
export FP_AI_ENGINE_ENABLED='$aiEngineVal'
export FP_INVOKING_USER='$WslUser'
FPEOF
. "`$ENVFILE"
rm -f "`$ENVFILE"
trap - EXIT
bash /opt/falconpulsar-installer/linux/install.sh --user '$WslUser' --mode docker --yes
"@

Write-Info 'Invoking bash installer (this can take 5-10 minutes for image pulls + first-run init)'
$rc = Invoke-WslBash -Distro $Distro -Script $runScript -User root
if ($rc -ne 0) {
    Stop-WithError "Bash installer failed inside WSL with exit code $rc. Run 'wsl -d $Distro -u root -- bash /opt/falconpulsar-installer/linux/install.sh --mode docker' manually to see the full output."
}

# Stage the Linux fp binary into WSL so the Windows fp.exe wrapper has
# something to exec. The wrapper does:
#   wsl.exe -d <distro> --cd <WslHome> -e <WslHome>/bin/fp <args>
# Belt-and-suspenders for when the bash installer's fp_install_cli call
# silently no-oped (missing binary, wrong perms, etc.).
$fpLinuxSrc = Join-Path $InstallDir 'fp-linux-amd64'
if (Test-Path $fpLinuxSrc) {
    $fpLinuxInWsl = ConvertTo-WslPath -WindowsPath $fpLinuxSrc
    $stageFpScript = @"
set -e
install -d -m 0755 -o '$WslUser' -g '$WslUser' '$WslHome/bin'
install -m 0755 -o '$WslUser' -g '$WslUser' '$fpLinuxInWsl' '$WslHome/bin/fp'
echo '[ok] Linux fp binary installed at $WslHome/bin/fp'
"@
    $null = Invoke-WslBash -Distro $Distro -Script $stageFpScript -User root
} else {
    Write-Warn "Linux fp binary not found at $fpLinuxSrc -- fp.exe wrapper will error until fp is installed in WSL."
}

# Write the sentinel so fp.exe (and the tray) can auto-discover the distro
# without guessing.
$sentinel = Join-Path $env:TEMP 'falconpulsar-distro.txt'
Set-Content -Path $sentinel -Value $Distro -Encoding ASCII
Write-Info "Wrote distro sentinel: $sentinel"

Write-Output '[ok] FalconPulsar installed inside WSL'
exit 0
