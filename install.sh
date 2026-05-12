#!/usr/bin/env bash
# ============================================================================
#  Gridfinity Label Forge + Inventory — single-command installer
#  ----------------------------------------------------------------------------
#  Run on a fresh Raspberry Pi OS Lite (Bookworm or newer), Pi 4 / Pi 5 /
#  Pi Zero 2 W. Requires sudo.
#
#  Quick start:
#    curl -sSL https://raw.githubusercontent.com/kenny8282/Inventory/main/install.sh | sudo bash
#
#  Or download and inspect first:
#    wget https://raw.githubusercontent.com/kenny8282/Inventory/main/install.sh
#    less install.sh
#    sudo bash install.sh
#
#  Idempotent — re-running upgrades in place without losing data.
# ============================================================================
set -euo pipefail

# ---- Config ---------------------------------------------------------------
REPO_URL="${GRIDFINITY_REPO_URL:-https://github.com/kenny8282/Inventory.git}"
REPO_BRANCH="${GRIDFINITY_REPO_BRANCH:-main}"
INSTALL_DIR="/opt/gridfinity"
DATA_DIR="/var/lib/gridfinity"
WEB_DIR="/var/www/html"
SERVICE_USER="${SUDO_USER:-$(whoami)}"
PTOUCH_REPO="https://github.com/clarkewd/ptouch-print.git"
PTOUCH_BUILD_DIR="/tmp/ptouch-print-build"
PYTHON_BIN="python3"

# Pretty output helpers
RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BLUE=$'\033[34m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
info()  { echo "${BLUE}${BOLD}==>${RESET} $*"; }
ok()    { echo "  ${GREEN}✓${RESET} $*"; }
warn()  { echo "  ${YELLOW}!${RESET} $*"; }
fail()  { echo "  ${RED}✗${RESET} $*" >&2; exit 1; }

# ---- Pre-flight checks ----------------------------------------------------
info "Pre-flight checks"

if [ "$EUID" -ne 0 ]; then
  fail "Run with sudo: sudo bash install.sh"
fi

if [ "$SERVICE_USER" = "root" ]; then
  fail "Don't run from a root login — sudo from a regular user account so the printer udev rule attaches to that user."
fi

if [ ! -f /etc/debian_version ]; then
  fail "This installer is for Raspberry Pi OS / Debian only."
fi

ARCH=$(uname -m)
case "$ARCH" in
  aarch64|armv7l|armv6l) ok "Architecture: $ARCH" ;;
  *) warn "Untested architecture: $ARCH — proceeding anyway" ;;
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
  # Build (no autotools — ptouch-print uses CMake)
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
# Brother P-touch label printers — accessible to plugdev group
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
info "Fetching application source"
SRC_DIR="/tmp/gridfinity-src-$$"
git clone --depth 1 --branch "$REPO_BRANCH" "$REPO_URL" "$SRC_DIR"

# ---- Directories ----------------------------------------------------------
info "Creating directories"
mkdir -p "$INSTALL_DIR" "$DATA_DIR"
mkdir -p "$WEB_DIR/forge" "$WEB_DIR/inventory"
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
chown -R www-data:www-data "$WEB_DIR"
ok "Web pages installed under $WEB_DIR"

# ---- TLS cert (self-signed, 10-year) --------------------------------------
info "Setting up TLS certificate"
CERT_DIR=/etc/ssl/gridfinity
mkdir -p "$CERT_DIR"
if [ -f "$CERT_DIR/gridfinity.crt" ] && [ -f "$CERT_DIR/gridfinity.key" ]; then
  ok "Existing cert at $CERT_DIR — keeping it"
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
nginx -t >/dev/null 2>&1 || fail "nginx config test failed — check /etc/nginx/sites-available/gridfinity"
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
  warn "Service started but is not active yet — check: sudo journalctl -u gridfinity-backend -n 30"
fi

# ---- Passwordless sudo for printer commands (so backend can call ptouch) --
# ptouch-print works via plugdev group, doesn't actually need sudo, but keep
# the sudoers stub for forward compat if you add other privileged calls.
# (Skipped intentionally — group membership is enough.)

# ---- Cleanup --------------------------------------------------------------
rm -rf "$SRC_DIR"

# ---- Success ---------------------------------------------------------------
HOSTNAME=$(hostname)
IP=$(hostname -I | awk '{print $1}')
echo
echo "${GREEN}${BOLD}════════════════════════════════════════════════════════════════${RESET}"
echo "${GREEN}${BOLD}  Gridfinity is installed and running!${RESET}"
echo "${GREEN}${BOLD}════════════════════════════════════════════════════════════════${RESET}"
echo
echo "  Open one of these URLs on any device on your network:"
echo
echo "    ${BOLD}https://${HOSTNAME}.local/${RESET}"
echo "    ${BOLD}https://${IP}/${RESET}"
echo
echo "  Your browser will show a security warning (self-signed cert)."
echo "  This is expected. Click ${BOLD}'Advanced'${RESET} → ${BOLD}'Proceed'${RESET} once per device."
echo
echo "  First time using the printer? Plug it in via USB and run:"
echo "    ${BOLD}ptouch-print --info${RESET}"
echo
echo "  Useful commands:"
echo "    sudo systemctl status gridfinity-backend     ${BLUE}# is it running?${RESET}"
echo "    sudo journalctl -u gridfinity-backend -f     ${BLUE}# live logs${RESET}"
echo "    sudo bash /opt/gridfinity/update.sh          ${BLUE}# pull latest${RESET}"
echo
echo "  Documentation:  ${REPO_URL%.git}#readme"
echo
echo "${GREEN}${BOLD}════════════════════════════════════════════════════════════════${RESET}"
