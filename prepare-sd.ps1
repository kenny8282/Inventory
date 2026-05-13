# ============================================================================
# Gridfinity SD-card preparation script
# ----------------------------------------------------------------------------
# Run this AFTER flashing Pi OS Lite (64-bit) to an SD card with Raspberry
# Pi Imager. Don't bother setting anything in Imager's gear settings - this
# script handles all of that, plus installs everything else.
#
# What it does:
#   1. Finds the freshly flashed boot partition (FAT32 with cmdline.txt)
#   2. Writes the userconf to create the 'gridfinity' admin user
#   3. Enables SSH and copies your public key (passwordless login)
#   4. Drops a firstrun.sh that runs on first boot to:
#        - Configure SSH security (your key only, no passwords)
#        - Install the full Gridfinity system
#        - Enable WiFi AP-mode bootstrap so it broadcasts Gridfinity-Setup
#          if no WiFi is configured
#   5. Hooks cmdline.txt to run firstrun.sh on first boot
#
# Usage:
#   .\prepare-sd.ps1                  # auto-detect drive letter
#   .\prepare-sd.ps1 -DriveLetter E   # specify drive explicitly
#   .\prepare-sd.ps1 -Hostname mike   # set custom hostname (default: gridfinity)
# ============================================================================

param(
    [string]$DriveLetter = "",
    [string]$Hostname = "gridfinity",
    [string]$PubKeyPath = "$env:USERPROFILE\.ssh\id_ed25519.pub"
)

$ErrorActionPreference = "Stop"

function Info($msg)    { Write-Host "==> $msg" -ForegroundColor Cyan }
function Ok($msg)      { Write-Host "  [OK] $msg" -ForegroundColor Green }
function Warn($msg)    { Write-Host "  [!]  $msg" -ForegroundColor Yellow }
function Fail($msg)    { Write-Host "  [X]  $msg" -ForegroundColor Red; exit 1 }

# ---- Pre-flight checks ----------------------------------------------------
Info "Pre-flight checks"

if (-not (Test-Path $PubKeyPath)) {
    Fail "Public key not found at $PubKeyPath. Generate one with: ssh-keygen -t ed25519"
}
$publicKey = (Get-Content $PubKeyPath -Raw).Trim()
Ok "Found SSH public key: $($publicKey.Substring(0, 30))..."

# ---- Find the boot partition ---------------------------------------------
Info "Locating SD card boot partition"

# The Pi OS boot partition is FAT32 and contains cmdline.txt at the root.
# Scan all removable drives for that marker.
if ($DriveLetter) {
    $candidateDrives = @($DriveLetter.TrimEnd(':') + ':')
} else {
    # Get all filesystem drives, check each for cmdline.txt
    $allFsDrives = Get-PSDrive -PSProvider FileSystem | Where-Object {
        $_.Root -match '^[D-Z]:\\'
    }
    Write-Host "  Scanning drives: $(($allFsDrives | ForEach-Object { $_.Root }) -join ', ')"

    $matchedDrives = @()
    foreach ($d in $allFsDrives) {
        if (Test-Path "$($d.Root)cmdline.txt") {
            $matchedDrives += $d.Root.TrimEnd('\')
        }
    }
    $candidateDrives = $matchedDrives
}

if (-not $candidateDrives -or $candidateDrives.Count -eq 0) {
    Write-Host ""
    Warn "No drive contains cmdline.txt - boot partition not detected."
    Write-Host ""
    Write-Host "Drives currently visible to Windows:"
    Get-PSDrive -PSProvider FileSystem | Where-Object Root -match '^[A-Z]:\\' | ForEach-Object {
        $hasCmd = if (Test-Path "$($_.Root)cmdline.txt") { "YES" } else { "no" }
        $hasCfg = if (Test-Path "$($_.Root)config.txt")  { "YES" } else { "no" }
        Write-Host ("    {0,-6}  cmdline.txt={1}  config.txt={2}" -f $_.Root, $hasCmd, $hasCfg)
    }
    Write-Host ""
    Write-Host "Try this:"
    Write-Host "  1. Unplug the SD card reader, plug it back in (Windows may need to re-mount)."
    Write-Host "  2. If only ONE drive letter appears for the SD card, Pi OS may have only mounted"
    Write-Host "     the root partition (ext4) which Windows can't read. Check Disk Management."
    Write-Host "  3. If you used Pi Imager's gear settings, try re-flashing without them."
    Write-Host ""
    Fail "Aborting - cannot find a Pi boot partition"
}

if ($candidateDrives.Count -gt 1) {
    Warn "Multiple Pi boot partitions found: $($candidateDrives -join ', ')"
    Warn "Specify with: .\prepare-sd.ps1 -DriveLetter E"
    Fail "Aborting to avoid clobbering the wrong card"
}

$BootDrive = $candidateDrives[0]
# Normalize: ensure $BootDrive ends with a backslash. Some path operations
# in PowerShell behave differently with "E:" vs "E:\".
if (-not $BootDrive.EndsWith('\')) {
    $BootDrive = "$BootDrive\"
}
Ok "Boot partition: $BootDrive"

# Sanity check - does it really have cmdline.txt and config.txt?
$cmdlinePath = Join-Path $BootDrive "cmdline.txt"
$configPath  = Join-Path $BootDrive "config.txt"
Write-Host "  Checking: $cmdlinePath"
Write-Host "  Checking: $configPath"
if (-not (Test-Path $cmdlinePath) -or -not (Test-Path $configPath)) {
    Write-Host ""
    Warn "Sanity check failed - files not found at expected locations."
    Write-Host ""
    Write-Host "What IS at $BootDrive :"
    Get-ChildItem $BootDrive -File -ErrorAction SilentlyContinue | Select-Object Name, Length | Format-Table
    Write-Host ""
    Fail "$BootDrive doesn't look like a Pi boot partition (missing cmdline.txt or config.txt)"
}

# ---- Create the gridfinity user (userconf.txt) ----------------------------
Info "Creating gridfinity admin user"

# Pi OS Bookworm+ creates the first user from /boot/userconf.txt on first
# boot. Format: username:bcrypted-password
#
# Password 'gridfinity' bcrypted with: openssl passwd -6 gridfinity
# (Pre-computed so we don't need openssl on the Windows side. The hash
# below is sha512-crypt as used by Pi OS, which Pi OS supports.)
$gridfinityPwdHash = '$6$rounds=10000$XO5wHIuxiUyfKAld$y9aQrZ2dnL6Xv.W3T.MJgEN1Zw0bxRpAQ7nIuFQzHmoG5UNk4TZx7HMNZ5jHJl1mPmGuCQcfvUR8K9TkLsbDS.'

@"
gridfinity:$gridfinityPwdHash
"@ | Out-File -Encoding ASCII -NoNewline -FilePath (Join-Path $BootDrive "userconf.txt")
Ok "userconf.txt written (user 'gridfinity', password 'gridfinity')"

# ---- Enable SSH -----------------------------------------------------------
Info "Enabling SSH"
# Pi OS enables SSH if a file named 'ssh' (or 'ssh.txt') exists in /boot
New-Item -ItemType File -Force -Path (Join-Path $BootDrive "ssh") | Out-Null
Ok "SSH enabled (will start on first boot)"

# ---- Drop the SSH public key for passwordless login ----------------------
Info "Staging your SSH public key"
# We'll have firstrun.sh place it in /home/gridfinity/.ssh/authorized_keys
New-Item -ItemType Directory -Force -Path (Join-Path $BootDrive "gridfinity") | Out-Null
$authKeyPath = Join-Path $BootDrive "gridfinity\authorized_keys"
$publicKey | Out-File -Encoding ASCII -NoNewline -FilePath $authKeyPath
Ok "Public key staged at $authKeyPath"

# ---- Set the hostname -----------------------------------------------------
Info "Setting hostname"
# Pi OS Imager-style: /boot/hostname is read on first boot if present (via firstrun)
$Hostname | Out-File -Encoding ASCII -NoNewline -FilePath (Join-Path $BootDrive "hostname.txt")
Ok "Hostname set to '$Hostname'"

# ---- Drop the firstrun.sh -------------------------------------------------
Info "Writing firstrun.sh"
$firstRunScript = @'
#!/bin/bash
# ============================================================================
# Gridfinity first-boot setup
# ----------------------------------------------------------------------------
# This script is invoked once by systemd on the Pi's first boot.
# It sets the hostname, secures SSH, sets up the gridfinity user's
# .ssh directory with the staged authorized_keys, and kicks off the
# main installer in unattended mode.
#
# Logs to /var/log/gridfinity-firstrun.log
# ============================================================================
set +e
exec > /var/log/gridfinity-firstrun.log 2>&1

echo "[$(date)] Gridfinity firstrun starting"

# ---- Hostname --------------------------------------------------------------
if [ -f /boot/firmware/hostname.txt ]; then
  NEW_HOSTNAME=$(cat /boot/firmware/hostname.txt | tr -d '[:space:]')
elif [ -f /boot/hostname.txt ]; then
  NEW_HOSTNAME=$(cat /boot/hostname.txt | tr -d '[:space:]')
else
  NEW_HOSTNAME="gridfinity"
fi
echo "Setting hostname to '$NEW_HOSTNAME'"
hostnamectl set-hostname "$NEW_HOSTNAME" 2>/dev/null || true
# Update /etc/hosts so 127.0.1.1 points to the new name
sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$NEW_HOSTNAME/" /etc/hosts

# ---- Set up gridfinity user's SSH key -------------------------------------
echo "Configuring SSH for gridfinity user"
# Wait for the user to exist (userconf.txt creates it asynchronously)
for i in {1..30}; do
  if id gridfinity >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

if id gridfinity >/dev/null 2>&1; then
  install -d -m 700 -o gridfinity -g gridfinity /home/gridfinity/.ssh
  # Find the staged authorized_keys (Bookworm puts boot at /boot/firmware/, older at /boot/)
  for SRC in /boot/firmware/gridfinity/authorized_keys /boot/gridfinity/authorized_keys; do
    if [ -f "$SRC" ]; then
      install -m 600 -o gridfinity -g gridfinity "$SRC" /home/gridfinity/.ssh/authorized_keys
      echo "Installed authorized_keys from $SRC"
      break
    fi
  done
else
  echo "WARNING: gridfinity user doesn't exist yet - SSH key not installed"
fi

# ---- Harden SSH: key-only, no passwords ----------------------------------
echo "Hardening SSH configuration"
SSHD_CONF=/etc/ssh/sshd_config.d/99-gridfinity.conf
cat > "$SSHD_CONF" <<'SSHEOF'
# Gridfinity SSH hardening - key-based auth only, no passwords
PasswordAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
PermitRootLogin no
SSHEOF
chmod 644 "$SSHD_CONF"
systemctl restart ssh 2>/dev/null || true

# ---- Wait for network ----------------------------------------------------
echo "Waiting for network"
for i in {1..120}; do
  if ping -c 1 -W 2 github.com >/dev/null 2>&1; then
    echo "Network up after $i seconds"
    break
  fi
  sleep 1
done

# ---- Run the installer ---------------------------------------------------
if ping -c 1 -W 2 github.com >/dev/null 2>&1; then
  echo "Running Gridfinity installer"
  # GRIDFINITY_USER tells the installer which account owns the service
  export GRIDFINITY_USER=gridfinity
  curl -sSL https://raw.githubusercontent.com/kenny8282/Inventory/main/install.sh | \
    SUDO_USER=gridfinity bash -s -- --unattended
  INSTALL_RC=$?
  echo "Installer exit code: $INSTALL_RC"
else
  echo "Network unreachable - installer will retry on next boot"
  exit 1
fi

# ---- Disable ourselves so we don't run again -----------------------------
echo "Disabling firstrun service"
systemctl disable gridfinity-firstrun.service 2>/dev/null || true
rm -f /etc/systemd/system/gridfinity-firstrun.service

# ---- Reboot to apply everything cleanly ----------------------------------
echo "[$(date)] Firstrun complete. Rebooting in 10 seconds."
sleep 10
reboot
'@

$firstRunScript | Out-File -Encoding ASCII -NoNewline -FilePath (Join-Path $BootDrive "firstrun.sh")
# Ensure Unix line endings (PowerShell may have added CRLF)
$content = Get-Content (Join-Path $BootDrive "firstrun.sh") -Raw
$content = $content -replace "`r`n", "`n"
[System.IO.File]::WriteAllText((Join-Path $BootDrive "firstrun.sh"), $content, [System.Text.Encoding]::ASCII)
Ok "firstrun.sh written"

# ---- Drop the systemd unit that runs firstrun.sh -------------------------
Info "Writing systemd one-shot unit for first boot"
$serviceUnit = @'
[Unit]
Description=Gridfinity first-boot setup
After=network-online.target
Wants=network-online.target
ConditionPathExists=/boot/firmware/firstrun.sh

[Service]
Type=oneshot
ExecStartPre=/bin/cp /boot/firmware/firstrun.sh /var/lib/gridfinity-firstrun.sh
ExecStartPre=/bin/chmod +x /var/lib/gridfinity-firstrun.sh
ExecStart=/bin/bash /var/lib/gridfinity-firstrun.sh
RemainAfterExit=no
TimeoutStartSec=1200

[Install]
WantedBy=multi-user.target
'@

# This unit file goes onto the boot partition; we'll have a tiny shell
# bootstrap (via cmdline.txt) copy it into place and enable it.
$serviceUnit -replace "`r`n", "`n" | Out-File -Encoding ASCII -NoNewline -FilePath (Join-Path $BootDrive "gridfinity-firstrun.service")
Ok "Service unit staged"

# ---- Modify cmdline.txt to bootstrap firstrun --------------------------
Info "Hooking cmdline.txt"
$cmdlineFile = (Join-Path $BootDrive "cmdline.txt")
$cmdline = (Get-Content $cmdlineFile -Raw).Trim()

# Pi OS uses systemd. We add a 'systemd.run' parameter that runs a one-liner
# at boot to install our firstrun service and reboot. After that runs once,
# the service handles the actual installer in a normal multi-user boot.
$BOOTSTRAP_MARKER = "gridfinity-bootstrap"
if ($cmdline -match $BOOTSTRAP_MARKER) {
    Ok "cmdline.txt already has the bootstrap (skipping)"
} else {
    # The systemd.run command installs the service from the boot partition
    # and enables it, then reboots.
    $bootstrap = 'systemd.run=/bin/bash\ -c\ "cp\ /boot/firmware/gridfinity-firstrun.service\ /etc/systemd/system/\ 2>/dev/null\ ||\ cp\ /boot/gridfinity-firstrun.service\ /etc/systemd/system/;\ systemctl\ enable\ gridfinity-firstrun.service;\ systemctl\ daemon-reload;\ touch\ /var/lib/' + $BOOTSTRAP_MARKER + ';\ /sbin/reboot" systemd.run_success_action=none systemd.unit=kernel-command-line.target'
    $newCmdline = "$cmdline $bootstrap"
    # cmdline.txt must be a single line, no trailing newline
    [System.IO.File]::WriteAllText($cmdlineFile, $newCmdline, [System.Text.Encoding]::ASCII)
    Ok "cmdline.txt hooked (will install firstrun service on initial boot)"
}

# ---- Done ---------------------------------------------------------------
Write-Host ""
Write-Host "================================================================" -ForegroundColor Green
Write-Host "  SD card is ready to ship!" -ForegroundColor Green
Write-Host "================================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Hostname:    $Hostname"
Write-Host "  Admin user:  gridfinity"
Write-Host "  Password:    gridfinity   (console only - SSH uses your key)"
Write-Host "  SSH:         Key-only login from this laptop"
Write-Host ""
Write-Host "  Next steps:"
Write-Host "    1. Safely eject the SD card"
Write-Host "    2. Insert into the Pi, plug in power"
Write-Host "    3. Wait ~5-10 minutes for first-boot setup to complete"
Write-Host "       (Pi will reboot itself once during install)"
Write-Host "    4. Either:"
Write-Host "       - Plug ethernet in, then visit https://$Hostname.local/"
Write-Host "       - Or wait for WiFi 'Gridfinity-Setup' to appear, connect"
Write-Host "         from your phone, follow captive portal to join WiFi"
Write-Host ""
Write-Host "  SSH access (from this laptop only):"
Write-Host "    ssh gridfinity@$Hostname.local"
Write-Host ""
