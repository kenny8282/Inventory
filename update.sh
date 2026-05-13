#!/usr/bin/env bash
# Update Gridfinity to the latest version.
# Uses the persistent git clone at /opt/gridfinity/src/.
# Idempotent â€” safe to run when no update is available.
set -euo pipefail

INSTALL_DIR="/opt/gridfinity"
SRC_DIR="$INSTALL_DIR/src"
WEB_DIR="/var/www/html"
SERVICE_USER="$(stat -c '%U' "$INSTALL_DIR/gridfinity_backend.py" 2>/dev/null || echo "$SUDO_USER")"
REPO_BRANCH="${GRIDFINITY_REPO_BRANCH:-main}"

if [ "$EUID" -ne 0 ]; then
  echo "Run with sudo: sudo bash $INSTALL_DIR/update.sh"
  exit 1
fi

# If no persistent source dir exists, fall back to fetching to /tmp
if [ ! -d "$SRC_DIR/.git" ]; then
  echo "==> No persistent source dir at $SRC_DIR â€” falling back to fresh clone"
  SRC_DIR="/tmp/gridfinity-update-$$"
  REPO_URL="${GRIDFINITY_REPO_URL:-https://github.com/kenny8282/Inventory.git}"
  git clone --depth 1 --branch "$REPO_BRANCH" "$REPO_URL" "$SRC_DIR"
  CLEANUP=1
else
  echo "==> Pulling latest from origin/$REPO_BRANCH"
  cd "$SRC_DIR"
  sudo -u "$SERVICE_USER" git fetch --quiet origin
  sudo -u "$SERVICE_USER" git checkout --quiet "$REPO_BRANCH"
  sudo -u "$SERVICE_USER" git reset --hard --quiet "origin/$REPO_BRANCH"
  CLEANUP=0
fi

echo "==> Updating backend"
cp "$SRC_DIR/backend/gridfinity_backend.py" "$INSTALL_DIR/"
chown "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR/gridfinity_backend.py"

echo "==> Updating frontend"
cp "$SRC_DIR/frontend/index.html"           "$WEB_DIR/index.html"
cp "$SRC_DIR/frontend/forge/index.html"     "$WEB_DIR/forge/index.html"
cp "$SRC_DIR/frontend/inventory/index.html" "$WEB_DIR/inventory/index.html"
if [ -f "$SRC_DIR/frontend/wifi/index.html" ]; then
  mkdir -p "$WEB_DIR/wifi"
  cp "$SRC_DIR/frontend/wifi/index.html"    "$WEB_DIR/wifi/index.html"
fi
chown -R www-data:www-data "$WEB_DIR"

echo "==> Refreshing nginx config"
cp "$SRC_DIR/etc/gridfinity-nginx.conf" /etc/nginx/sites-available/gridfinity
nginx -t >/dev/null 2>&1 && systemctl reload nginx

echo "==> Refreshing systemd service"
sed -e "s/^User=.*/User=$SERVICE_USER/" \
    -e "s/^Group=.*/Group=$SERVICE_USER/" \
    "$SRC_DIR/etc/gridfinity-backend.service" \
    > /etc/systemd/system/gridfinity-backend.service
systemctl daemon-reload

echo "==> Refreshing update.sh itself"
cp "$SRC_DIR/update.sh" "$INSTALL_DIR/update.sh"
chmod +x "$INSTALL_DIR/update.sh"

echo "==> Refreshing WiFi sudoers"
if [ -f "$SRC_DIR/etc/gridfinity-wifi-sudoers.template" ]; then
  awk -v u="$SERVICE_USER" '{ gsub(/%s/, u); print }' \
    "$SRC_DIR/etc/gridfinity-wifi-sudoers.template" \
    > /etc/sudoers.d/gridfinity-wifi
  chmod 0440 /etc/sudoers.d/gridfinity-wifi
  if ! visudo -c -q -f /etc/sudoers.d/gridfinity-wifi 2>/dev/null; then
    rm -f /etc/sudoers.d/gridfinity-wifi
  fi
fi

echo "==> Refreshing update-runner sudoers"
cat > /etc/sudoers.d/gridfinity-update <<EOF
$SERVICE_USER ALL=(ALL) NOPASSWD: /bin/bash $INSTALL_DIR/update.sh
$SERVICE_USER ALL=(ALL) NOPASSWD: $INSTALL_DIR/update.sh
$SERVICE_USER ALL=(ALL) NOPASSWD: /usr/bin/systemd-run --unit=gridfinity-update-runner --collect --no-block /bin/bash $INSTALL_DIR/update.sh
EOF
chmod 0440 /etc/sudoers.d/gridfinity-update
if ! visudo -c -q -f /etc/sudoers.d/gridfinity-update 2>/dev/null; then
  rm -f /etc/sudoers.d/gridfinity-update
fi

echo "==> Clearing update cache"
# The cached update-check state is now stale; remove it so the next
# check returns fresh data.
rm -f /var/lib/gridfinity/update-cache.json || true

echo "==> Restarting service"
systemctl restart gridfinity-backend
sleep 2

if [ "$CLEANUP" = "1" ]; then
  rm -rf "$SRC_DIR"
fi

if systemctl is-active --quiet gridfinity-backend; then
  echo
  echo "âœ“ Update complete. Service is running."
else
  echo
  echo "! Service didn't come back up. Check:"
  echo "  sudo journalctl -u gridfinity-backend -n 30 --no-pager"
  exit 1
fi
