#!/usr/bin/env bash
# Uninstall Gridfinity. Preserves data by default; pass --purge to wipe it.
set -euo pipefail

if [ "$EUID" -ne 0 ]; then
  echo "Run with sudo."
  exit 1
fi

PURGE=0
if [ "${1:-}" = "--purge" ]; then PURGE=1; fi

echo "==> Stopping service"
systemctl stop gridfinity-backend 2>/dev/null || true
systemctl disable gridfinity-backend 2>/dev/null || true
rm -f /etc/systemd/system/gridfinity-backend.service
systemctl daemon-reload

echo "==> Removing nginx config"
rm -f /etc/nginx/sites-enabled/gridfinity
rm -f /etc/nginx/sites-available/gridfinity
nginx -t >/dev/null 2>&1 && systemctl reload nginx || true

echo "==> Removing web files"
rm -f /var/www/html/index.html
rm -rf /var/www/html/forge /var/www/html/inventory /var/www/html/wifi

echo "==> Removing WiFi sudoers rule"
rm -f /etc/sudoers.d/gridfinity-wifi

echo "==> Removing app directory"
rm -rf /opt/gridfinity

echo "==> Removing TLS cert"
rm -rf /etc/ssl/gridfinity

echo "==> Removing udev rule"
rm -f /etc/udev/rules.d/50-brother-ptouch.rules
udevadm control --reload-rules

if [ "$PURGE" = "1" ]; then
  echo "==> Purging data (--purge passed)"
  rm -rf /var/lib/gridfinity
else
  echo
  echo "Your inventory data is preserved at:"
  echo "  /var/lib/gridfinity/"
  echo "Run with --purge to delete it too."
fi

echo
echo "âœ“ Uninstalled."
