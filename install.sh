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
REPO_URL="${GRIDFINITY_REPO_URL:-https://github.com/YOUR_USER/gridfinity-system.git}"
REPO_BRANCH="${GRIDFINITY_REPO_BRANCH:-main}"
INSTALL_DIR="/opt/gridfinity"
DATA_DIR="/var/lib/gridfinity"
WEB_DIR="/var/www/html"
SERVICE_USER="${SUDO_USER:-$(whoami)}"
PTOUCH_REPO="https://github.com/clarkewd/ptouch-print.git"
PTOUCH_BUILD_DIR="/tmp/ptouch-print-build"
PYTHON_BIN="python3"

# Parse args
INSTALL_WIFI_BOOTSTRAP=1
for arg in "$@"; do
  case "$arg" in
    --no-bootstrap|--no-wifi-bootstrap)
      INSTALL_WIFI_BOOTSTRAP=0
      ;;
  esac
done

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
  fail "Don't run from a root login â€” sudo from a regular user account so the printer udev rule attaches to that user."
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
  git build-essential pkg-config \
  libudev-dev libusb-1.0-0-dev \
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
# so the home page's "Update Now" button works.
cat > /etc/sudoers.d/gridfinity-update <<EOF
$SERVICE_USER ALL=(ALL) NOPASSWD: /bin/bash $INSTALL_DIR/update.sh
$SERVICE_USER ALL=(ALL) NOPASSWD: $INSTALL_DIR/update.sh
EOF
chmod 0440 /etc/sudoers.d/gridfinity-update
if ! visudo -c -q -f /etc/sudoers.d/gridfinity-update 2>/dev/null; then
  warn "Update sudoers validation failed"
  rm -f /etc/sudoers.d/gridfinity-update
else
  ok "Update system sudoers rule installed"
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

# ---- TLS cert (self-signed, 10-year) --------------------------------------
info "Setting up TLS certificate"
CERT_DIR=/etc/ssl/gridfinity
mkdir -p "$CERT_DIR"
if [ -f "$CERT_DIR/gridfinity.crt" ] && [ -f "$CERT_DIR/gridfinity.key" ]; then
  ok "Existing cert at $CERT_DIR â€” keeping it"
else
  # Generate cert valid for both .local and the Pi's hostname
  HOSTNAME=$(hostname)
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$CERT_DIR/gridfinity.key" \
    -out    "$CERT_DIR/gridfinity.crt" \
    -subj "/CN=${HOSTNAME}.local" \
    -addext "subjectAltName=DNS:${HOSTNAME}.local,DNS:${HOSTNAME},DNS:gridfinity.local,IP:127.0.0.1" \
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
