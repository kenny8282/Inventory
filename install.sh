#!/usr/bin/env bash
# ============================================================================
#  Gridfinity Label Forge + Inventory â€” single-command installer
#  ----------------------------------------------------------------------------
#  Run on a fresh Raspberry Pi OS Lite (Bookworm or newer), Pi 4 / Pi 5 /
#  Pi Zero 2 W. Requires sudo.
#
#  Quick start:
#    curl -sSL https://raw.githubusercontent.com/YOUR_USER/gridfinity-system/main/install.sh | sudo bash
#
#  Or download and inspect first:
#    wget https://raw.githubusercontent.com/YOUR_USER/gridfinity-system/main/install.sh
#    less install.sh
#    sudo bash install.sh
#
#  Idempotent â€” re-running upgrades in place without losing data.
# ============================================================================
set -euo pipefail

# ---- Config ---------------------------------------------------------------
REPO_URL="${GRIDFINITY_REPO_URL:-https://github.com/kenny8282/Inventory.git}"
REPO_BRANCH="${GRIDFINITY_REPO_BRANCH:-main}"
INSTALL_DIR="/opt/gridfinity"
DATA_DIR="/var/lib/gridfinity"
WEB_DIR="/var/www/html"
# SERVICE_USER is set later after arg parsing (to support GRIDFINITY_USER env var)
PTOUCH_REPO="${PTOUCH_REPO_URL:-https://github.com/farixembedded/ptouch-print.git}"
PTOUCH_BUILD_DIR="/tmp/ptouch-print-build"
PYTHON_BIN="python3"

# Parse args
INSTALL_WIFI_BOOTSTRAP=1
UNATTENDED=0
for arg in "$@"; do
  case "$arg" in
    --no-bootstrap|--no-wifi-bootstrap)
      INSTALL_WIFI_BOOTSTRAP=0
      ;;
    --unattended|-y)
      UNATTENDED=1
      ;;
  esac
done

# In unattended mode, mirror all output to a log file too.
if [ "$UNATTENDED" = "1" ]; then
  LOG_FILE="/var/log/gridfinity-install.log"
  mkdir -p "$(dirname "$LOG_FILE")"
  exec > >(tee -a "$LOG_FILE") 2>&1
  echo "[$(date)] Unattended install starting (log: $LOG_FILE)"
fi

# Never prompt for git credentials. If a clone needs auth, that's a bug â€” fail
# loudly instead of hanging the curl|sudo pipe forever.
export GIT_TERMINAL_PROMPT=0
export GIT_ASKPASS=/bin/true

# Service user: prefer GRIDFINITY_USER (set by firstrun.sh), then SUDO_USER,
# then whoami. Friends installing via the curl|bash one-liner from SSH get
# their account name. Pre-flashed cards using firstrun.sh always use
# 'gridfinity'.
SERVICE_USER="${GRIDFINITY_USER:-${SUDO_USER:-$(whoami)}}"

# Pretty output helpers
RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BLUE=$'\033[34m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
info()  { echo "${BLUE}${BOLD}==>${RESET} $*"; }
ok()    { echo "  ${GREEN}âœ“${RESET} $*"; }
warn()  { echo "  ${YELLOW}!${RESET} $*"; }
fail()  { echo "  ${RED}âœ—${RESET} $*" >&2; exit 1; }

# ---- Pre-flight checks ----------------------------------------------------
info "Pre-flight checks"

if [ "$EUID" -ne 0 ]; then
  fail "Run with sudo: sudo bash install.sh"
fi

if [ "$SERVICE_USER" = "root" ]; then
  fail "Cannot install with SERVICE_USER=root. Run as a regular user with sudo, or set GRIDFINITY_USER=<username>."
fi

if ! id "$SERVICE_USER" >/dev/null 2>&1; then
  fail "Service user '$SERVICE_USER' doesn't exist. Set GRIDFINITY_USER or run sudo as a real user."
fi

if [ ! -f /etc/debian_version ]; then
  fail "This installer is for Raspberry Pi OS / Debian only."
fi

ARCH=$(uname -m)
case "$ARCH" in
  aarch64|armv7l|armv6l) ok "Architecture: $ARCH" ;;
  *) warn "Untested architecture: $ARCH â€” proceeding anyway" ;;
esac

if ! ping -c 1 -W 3 github.com >/dev/null 2>&1; then
  fail "No internet access. The installer needs to download packages."
fi

ok "Running as: $SERVICE_USER (with sudo)"
ok "Internet: reachable"

# ---- Package install -------------------------------------------------------
info "Installing system packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  git build-essential pkg-config cmake gettext \
  libudev-dev libusb-1.0-0-dev libgd-dev \
  python3 python3-venv python3-pip \
  nginx openssl \
  ca-certificates curl
ok "System packages installed"

# ---- ptouch-print build ---------------------------------------------------
info "Building ptouch-print (Brother label driver)"
if command -v ptouch-print >/dev/null 2>&1 && [ "${FORCE_PTOUCH_BUILD:-}" != "1" ]; then
  ok "ptouch-print already installed: $(ptouch-print --version 2>&1 | head -1 || echo '(version unknown)')"
else
  rm -rf "$PTOUCH_BUILD_DIR"
  git clone --depth 1 "$PTOUCH_REPO" "$PTOUCH_BUILD_DIR"
  cd "$PTOUCH_BUILD_DIR"
  # Build (no autotools â€” ptouch-print uses CMake)
  mkdir -p build && cd build
  cmake .. -DCMAKE_BUILD_TYPE=Release >/dev/null
  make -j"$(nproc)" >/dev/null
  make install >/dev/null
  ldconfig
  cd /
  rm -rf "$PTOUCH_BUILD_DIR"
  ok "ptouch-print built and installed to $(command -v ptouch-print)"
fi

# ---- udev rule for Brother printer access ---------------------------------
info "Setting up printer USB permissions"
UDEV_RULE=/etc/udev/rules.d/50-brother-ptouch.rules
cat > "$UDEV_RULE" <<'EOF'
# Brother P-touch label printers â€” accessible to plugdev group
# Covers PT-H500, PT-P700, PT-E550W, PT-D460BT and similar
SUBSYSTEM=="usb", ATTR{idVendor}=="04f9", GROUP="plugdev", MODE="0664"
EOF
ok "udev rule installed: $UDEV_RULE"

# Add service user to plugdev so they can talk to the printer
if id -nG "$SERVICE_USER" | grep -qw plugdev; then
  ok "$SERVICE_USER is already in plugdev group"
else
  usermod -aG plugdev "$SERVICE_USER"
  ok "Added $SERVICE_USER to plugdev group (will take effect after next login)"
fi

# Reload udev so the rule applies now
udevadm control --reload-rules
udevadm trigger --subsystem-match=usb || true

# ---- Source files ---------------------------------------------------------
# ---- Source files ---------------------------------------------------------
# Keep a persistent clone in /opt/gridfinity/src/ so the update system can
# `git pull` later instead of re-downloading every time. Update if it exists,
# clone fresh if not.
info "Fetching application source"
PERSISTENT_SRC="$INSTALL_DIR/src"
mkdir -p "$INSTALL_DIR"
if [ -d "$PERSISTENT_SRC/.git" ]; then
  ok "Existing source clone â€” pulling latest"
  cd "$PERSISTENT_SRC"
  git fetch --quiet origin
  git checkout --quiet "$REPO_BRANCH"
  git reset --hard --quiet "origin/$REPO_BRANCH"
  cd /
else
  rm -rf "$PERSISTENT_SRC"
  git clone --branch "$REPO_BRANCH" "$REPO_URL" "$PERSISTENT_SRC"
  ok "Source cloned to $PERSISTENT_SRC"
fi
SRC_DIR="$PERSISTENT_SRC"

# Permissions: the service user needs to read everything in src, and the
# update script needs to be able to fetch/pull as that user.
chown -R "$SERVICE_USER:$SERVICE_USER" "$PERSISTENT_SRC"

# ---- Directories ----------------------------------------------------------
info "Creating directories"
mkdir -p "$INSTALL_DIR" "$DATA_DIR"
mkdir -p "$WEB_DIR/forge" "$WEB_DIR/inventory" "$WEB_DIR/wifi"
chown -R "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR" "$DATA_DIR"
ok "Directories ready"

# ---- Backend deployment ---------------------------------------------------
info "Installing Python backend"
cp "$SRC_DIR/backend/gridfinity_backend.py" "$INSTALL_DIR/"
chown "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR/gridfinity_backend.py"

if [ ! -d "$INSTALL_DIR/venv" ]; then
  sudo -u "$SERVICE_USER" "$PYTHON_BIN" -m venv "$INSTALL_DIR/venv"
fi
sudo -u "$SERVICE_USER" "$INSTALL_DIR/venv/bin/pip" install --quiet --upgrade pip
sudo -u "$SERVICE_USER" "$INSTALL_DIR/venv/bin/pip" install --quiet flask gunicorn pillow qrcode
ok "Python venv: $INSTALL_DIR/venv"
ok "Backend installed"

# ---- Frontend deployment --------------------------------------------------
info "Installing web frontend"
cp "$SRC_DIR/frontend/index.html"            "$WEB_DIR/index.html"
cp "$SRC_DIR/frontend/forge/index.html"      "$WEB_DIR/forge/index.html"
cp "$SRC_DIR/frontend/inventory/index.html"  "$WEB_DIR/inventory/index.html"
cp "$SRC_DIR/frontend/wifi/index.html"       "$WEB_DIR/wifi/index.html"
chown -R www-data:www-data "$WEB_DIR"
ok "Web pages installed under $WEB_DIR"

# ---- WiFi management permissions ------------------------------------------
info "Configuring WiFi management permissions"
if [ -f "$SRC_DIR/etc/gridfinity-wifi-sudoers.template" ]; then
  # Substitute the service user into the template and install
  awk -v u="$SERVICE_USER" '{ gsub(/%s/, u); print }' \
    "$SRC_DIR/etc/gridfinity-wifi-sudoers.template" \
    > /etc/sudoers.d/gridfinity-wifi
  chmod 0440 /etc/sudoers.d/gridfinity-wifi
  # Validate
  if ! visudo -c -q -f /etc/sudoers.d/gridfinity-wifi 2>/dev/null; then
    warn "Sudoers validation failed â€” removing the file"
    rm -f /etc/sudoers.d/gridfinity-wifi
  else
    ok "WiFi management sudoers rule installed"
  fi
else
  warn "WiFi sudoers template not found â€” WiFi setup page will be read-only"
fi

# ---- Update system --------------------------------------------------------
info "Configuring update system"
# Copy update.sh into place so the home page's update button can call it.
cp "$SRC_DIR/update.sh" "$INSTALL_DIR/update.sh"
chmod +x "$INSTALL_DIR/update.sh"

# Allow the service user to run update.sh as root without a password,
# so the home page's "Update Now" button works. We also need systemd-run
# because that's how we detach update.sh from the gunicorn worker that
# triggers it (otherwise the workers die mid-update and kill the script).
cat > /etc/sudoers.d/gridfinity-update <<EOF
$SERVICE_USER ALL=(ALL) NOPASSWD: /bin/bash $INSTALL_DIR/update.sh
$SERVICE_USER ALL=(ALL) NOPASSWD: $INSTALL_DIR/update.sh
$SERVICE_USER ALL=(ALL) NOPASSWD: /usr/bin/systemd-run --unit=gridfinity-update-runner --collect --no-block /bin/bash $INSTALL_DIR/update.sh
EOF
chmod 0440 /etc/sudoers.d/gridfinity-update
if ! visudo -c -q -f /etc/sudoers.d/gridfinity-update 2>/dev/null; then
  warn "Update sudoers validation failed"
  rm -f /etc/sudoers.d/gridfinity-update
else
  ok "Update system sudoers rule installed"
fi

# Reboot rule: wifi_connect schedules a reboot after saving WiFi creds
# (rather than trying to live-switch from AP -> client mode, which races
# with comitup and frequently leaves the Pi stuck).
cat > /etc/sudoers.d/gridfinity-reboot <<EOF
$SERVICE_USER ALL=(ALL) NOPASSWD: /sbin/reboot
$SERVICE_USER ALL=(ALL) NOPASSWD: /usr/bin/systemd-run --unit=gridfinity-reboot-runner --collect --no-block --on-active=5 /sbin/reboot
EOF
chmod 0440 /etc/sudoers.d/gridfinity-reboot
if ! visudo -c -q -f /etc/sudoers.d/gridfinity-reboot 2>/dev/null; then
  warn "Reboot sudoers validation failed"
  rm -f /etc/sudoers.d/gridfinity-reboot
else
  ok "Reboot sudoers rule installed"
fi

# Daily cron to refresh the update-check cache so the home page banner
# stays current without making the user wait for a network call.
CRON_FILE=/etc/cron.d/gridfinity-update-check
cat > "$CRON_FILE" <<EOF
# Daily update check for Gridfinity â€” refreshes the update-cache.json file
# so the home page knows whether a new version is available.
# Runs at 3:17am to avoid clashing with common backup windows.
17 3 * * * $SERVICE_USER curl -sk https://localhost/api/system/update-check?refresh=1 >/dev/null 2>&1
EOF
chmod 644 "$CRON_FILE"
ok "Daily update-check cron installed: $CRON_FILE"

# ---- Hostname enforcement -------------------------------------------------
# Default hostname for fresh installs is "inv" (so the Pi is reachable at
# inv.local). If a different name is already set, we leave it alone — the
# operator is presumed to have chosen it deliberately. The only case we fix
# automatically is the legacy "gridfinity" hostname from older SD images.
info "Hostname check"
CURRENT_HOSTNAME=$(hostname)
DESIRED_HOSTNAME=inv
NEEDS_HOSTNAME_CHANGE=0
if [ "$CURRENT_HOSTNAME" = "gridfinity" ]; then
  warn "Detected legacy hostname 'gridfinity' — renaming to '$DESIRED_HOSTNAME'"
  NEEDS_HOSTNAME_CHANGE=1
elif [ "$CURRENT_HOSTNAME" = "raspberrypi" ] || [ -z "$CURRENT_HOSTNAME" ]; then
  warn "Detected default hostname '$CURRENT_HOSTNAME' — renaming to '$DESIRED_HOSTNAME'"
  NEEDS_HOSTNAME_CHANGE=1
else
  ok "Hostname is '$CURRENT_HOSTNAME' — keeping it"
fi

if [ "$NEEDS_HOSTNAME_CHANGE" = "1" ]; then
  # Disable cloud-init's hostname management so our changes persist across reboots.
  # The /etc/cloud/cloud.cfg.d/ override loads after the Pi defaults (lexical sort).
  if [ -d /etc/cloud/cloud.cfg.d ]; then
    cat > /etc/cloud/cloud.cfg.d/99-zzz-hostname.cfg <<EOF
# Set by install.sh — prevents cloud-init from rewriting hostname/hosts on boot.
preserve_hostname: true
manage_etc_hosts: false
EOF
    ok "cloud-init hostname management disabled"
  fi
  hostnamectl set-hostname "$DESIRED_HOSTNAME"
  echo "$DESIRED_HOSTNAME" > /etc/hostname
  # Replace any whole-word match of the old hostname in /etc/hosts.
  sed -i "s/\\b${CURRENT_HOSTNAME}\\b/${DESIRED_HOSTNAME}/g" /etc/hosts
  # Also make sure the standard 127.0.1.1 entry exists.
  if ! grep -qE '^127\.0\.1\.1\s' /etc/hosts; then
    echo "127.0.1.1 ${DESIRED_HOSTNAME} ${DESIRED_HOSTNAME}" >> /etc/hosts
  fi
  systemctl restart avahi-daemon 2>/dev/null || true
  ok "Hostname set to '$DESIRED_HOSTNAME' (avahi reloaded)"
  # Update the HOSTNAME variable so subsequent steps (cert generation below)
  # use the new name.
  HOSTNAME="$DESIRED_HOSTNAME"
fi

# ---- TLS cert (self-signed, 10-year) --------------------------------------
info "Setting up TLS certificate"
CERT_DIR=/etc/ssl/gridfinity
mkdir -p "$CERT_DIR"
if [ -f "$CERT_DIR/gridfinity.crt" ] && [ -f "$CERT_DIR/gridfinity.key" ]; then
  ok "Existing cert at $CERT_DIR â€” keeping it"
else
  # Generate cert valid for .local, the Pi's hostname, and the legacy
  # gridfinity.local name so old bookmarks still verify cleanly.
  HOSTNAME=$(hostname)
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$CERT_DIR/gridfinity.key" \
    -out    "$CERT_DIR/gridfinity.crt" \
    -subj "/CN=${HOSTNAME}.local" \
    -addext "subjectAltName=DNS:${HOSTNAME}.local,DNS:${HOSTNAME},DNS:inv.local,DNS:gridfinity.local,IP:127.0.0.1" \
    2>/dev/null
  chmod 600 "$CERT_DIR/gridfinity.key"
  chmod 644 "$CERT_DIR/gridfinity.crt"
  ok "Generated self-signed cert (10-year): CN=${HOSTNAME}.local"
fi

# ---- nginx config ---------------------------------------------------------
info "Configuring nginx"
cp "$SRC_DIR/etc/gridfinity-nginx.conf" /etc/nginx/sites-available/gridfinity
ln -sf /etc/nginx/sites-available/gridfinity /etc/nginx/sites-enabled/gridfinity
# Remove the default site if it's still there
rm -f /etc/nginx/sites-enabled/default
nginx -t >/dev/null 2>&1 || fail "nginx config test failed â€” check /etc/nginx/sites-available/gridfinity"
systemctl reload nginx 2>/dev/null || systemctl restart nginx
ok "nginx running on 80 (redirect) and 443 (HTTPS)"

# ---- systemd service ------------------------------------------------------
info "Installing systemd service"
# Replace the User= field with the actual service user
sed -e "s/^User=.*/User=$SERVICE_USER/" \
    -e "s/^Group=.*/Group=$SERVICE_USER/" \
    "$SRC_DIR/etc/gridfinity-backend.service" \
    > /etc/systemd/system/gridfinity-backend.service
systemctl daemon-reload
systemctl enable gridfinity-backend >/dev/null
systemctl restart gridfinity-backend
sleep 2
if systemctl is-active --quiet gridfinity-backend; then
  ok "gridfinity-backend.service is active"
else
  warn "Service started but is not active yet â€” check: sudo journalctl -u gridfinity-backend -n 30"
fi

# ---- Verify mDNS (Avahi) so <hostname>.local works ------------------------
info "Verifying mDNS (so <hostname>.local resolves)"
if systemctl is-active --quiet avahi-daemon; then
  ok "avahi-daemon is running"
else
  warn "avahi-daemon not running â€” installing/starting it"
  apt-get install -y -qq --no-install-recommends avahi-daemon
  systemctl enable avahi-daemon >/dev/null 2>&1 || true
  systemctl start avahi-daemon
  if systemctl is-active --quiet avahi-daemon; then
    ok "avahi-daemon now running"
  else
    warn "avahi-daemon failed to start â€” users will need to use the IP address"
  fi
fi

# ---- WiFi AP-mode bootstrap (comitup) -------------------------------------
if [ "$INSTALL_WIFI_BOOTSTRAP" = "1" ]; then
  if [ -f "$SRC_DIR/wifi-bootstrap.sh" ]; then
    info "Installing WiFi AP-mode bootstrap"
    bash "$SRC_DIR/wifi-bootstrap.sh" || warn "WiFi bootstrap failed â€” Pi will still work over ethernet"
  else
    warn "wifi-bootstrap.sh not found in repo â€” skipping AP mode setup"
  fi
else
  ok "WiFi AP-mode bootstrap skipped (--no-bootstrap)"
fi

# ---- Optional USB backup drive --------------------------------------------
# If the user has an ext4 partition labeled "backup-ssd" plugged in, set it up
# as the backup target at /mnt/backup. This is fully optional — installation
# succeeds without it. The mount is configured to fail gracefully if the drive
# is unplugged (nofail), so removing the SSD won't break boot.
if blkid -L backup-ssd >/dev/null 2>&1; then
  info "Detected backup drive (LABEL=backup-ssd)"
  mkdir -p /mnt/backup
  # Add fstab line if not already present.
  FSTAB_LINE='LABEL=backup-ssd  /mnt/backup  ext4  defaults,nofail,x-systemd.device-timeout=10s  0  2'
  if ! grep -q "^LABEL=backup-ssd" /etc/fstab 2>/dev/null; then
    echo "$FSTAB_LINE" >> /etc/fstab
    ok "Added backup-ssd to /etc/fstab"
  fi
  systemctl daemon-reload
  # Mount if not already mounted
  if ! mountpoint -q /mnt/backup; then
    mount /mnt/backup 2>/dev/null || warn "Could not mount /mnt/backup — check fstab"
  fi
  # Service user must own /mnt/backup so the backend can write backup files.
  # Without this, /api/system/backup-to-drive fails with PermissionError.
  if mountpoint -q /mnt/backup; then
    chown "$SERVICE_USER:$SERVICE_USER" /mnt/backup
    chmod 755 /mnt/backup
    ok "Backup drive mounted at /mnt/backup (owner $SERVICE_USER)"
  fi
else
  ok "No USB backup drive detected (optional — skip)"
fi

# ---- Cleanup --------------------------------------------------------------
# (We KEEP $SRC_DIR now â€” it lives at $PERSISTENT_SRC and is used by the
#  update system to pull future versions. Don't delete it.)

# ---- Success ---------------------------------------------------------------
HOSTNAME_SHORT=$(hostname)
IP=$(hostname -I | awk '{print $1}')
echo
echo "${GREEN}${BOLD}â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•${RESET}"
echo "${GREEN}${BOLD}  Gridfinity is installed and running!${RESET}"
echo "${GREEN}${BOLD}â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•${RESET}"
echo
echo "  Open one of these URLs on any device on your network:"
echo
echo "    ${BOLD}https://${HOSTNAME_SHORT}.local/${RESET}        ${BLUE}(works on most devices)${RESET}"
echo "    ${BOLD}https://${IP}/${RESET}                  ${BLUE}(direct IP â€” always works)${RESET}"
echo
echo "  ${YELLOW}The ${HOSTNAME_SHORT}.local URL uses mDNS, which works on:${RESET}"
echo "    macOS, iOS, Windows 10+, Linux, and Android 12+"
echo
echo "  ${YELLOW}If <hostname>.local doesn't work for your device:${RESET}"
echo "    - Use the IP address (https://${IP}/) instead â€” always works"
echo "    - Or set a static IP/DHCP reservation on your router so it stays fixed"
echo "    - The IP can change after a reboot if not reserved"
echo
echo "  Your browser will show a security warning (self-signed cert)."
echo "  Click ${BOLD}'Advanced'${RESET} â†’ ${BOLD}'Proceed'${RESET} once per device."
echo
echo "  First time using the printer? Plug it in via USB and run:"
echo "    ${BOLD}ptouch-print --info${RESET}"
echo
echo "  Useful commands:"
echo "    sudo systemctl status gridfinity-backend     ${BLUE}# is it running?${RESET}"
echo "    sudo journalctl -u gridfinity-backend -f     ${BLUE}# live logs${RESET}"
echo "    sudo bash /opt/gridfinity/update.sh          ${BLUE}# pull latest${RESET}"
echo "    hostname -I                                  ${BLUE}# show my IP${RESET}"
echo
echo "  Documentation:  ${REPO_URL%.git}#readme"
echo
echo "${GREEN}${BOLD}â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•${RESET}"
