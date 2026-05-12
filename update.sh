#!/usr/bin/env bash
# Update Gridfinity to the latest version from the repo.
set -euo pipefail

REPO_URL="${GRIDFINITY_REPO_URL:-https://github.com/kenny8282/Inventory.git}"
REPO_BRANCH="${GRIDFINITY_REPO_BRANCH:-main}"
INSTALL_DIR="/opt/gridfinity"
WEB_DIR="/var/www/html"
SERVICE_USER="$(stat -c '%U' "$INSTALL_DIR/gridfinity_backend.py" 2>/dev/null || echo "$SUDO_USER")"

if [ "$EUID" -ne 0 ]; then
  echo "Run with sudo: sudo bash /opt/gridfinity/update.sh"
  exit 1
fi

echo "==> Fetching latest source"
SRC_DIR="/tmp/gridfinity-update-$$"
git clone --depth 1 --branch "$REPO_BRANCH" "$REPO_URL" "$SRC_DIR"

echo "==> Updating backend"
cp "$SRC_DIR/backend/gridfinity_backend.py" "$INSTALL_DIR/"
chown "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR/gridfinity_backend.py"

echo "==> Updating frontend"
cp "$SRC_DIR/frontend/index.html"           "$WEB_DIR/index.html"
cp "$SRC_DIR/frontend/forge/index.html"     "$WEB_DIR/forge/index.html"
cp "$SRC_DIR/frontend/inventory/index.html" "$WEB_DIR/inventory/index.html"
chown -R www-data:www-data "$WEB_DIR"

echo "==> Refreshing nginx config (in case it changed)"
cp "$SRC_DIR/etc/gridfinity-nginx.conf" /etc/nginx/sites-available/gridfinity
nginx -t >/dev/null 2>&1 && systemctl reload nginx

echo "==> Refreshing systemd service (in case it changed)"
sed -e "s/^User=.*/User=$SERVICE_USER/" \
    -e "s/^Group=.*/Group=$SERVICE_USER/" \
    "$SRC_DIR/etc/gridfinity-backend.service" \
    > /etc/systemd/system/gridfinity-backend.service
systemctl daemon-reload
systemctl restart gridfinity-backend
sleep 2

rm -rf "$SRC_DIR"

if systemctl is-active --quiet gridfinity-backend; then
  echo
  echo "✓ Update complete. Service is running."
else
  echo
  echo "! Service didn't come back up. Check:"
  echo "  sudo journalctl -u gridfinity-backend -n 30 --no-pager"
  exit 1
fi
