#!/usr/bin/env bash
# ============================================================================
#  migrate-hostname.sh — rename a deployed Pi's hostname to "inv" persistently
#  ----------------------------------------------------------------------------
#  Use this if you have an EXISTING Pi installed under an older name (typically
#  "gridfinity") and want to rename it to "inv". New Pi installs from current
#  install.sh handle this automatically — this script is only for migrations.
#
#  What it does:
#    1. Writes a cloud-init override so the new hostname persists across reboots
#       (Raspberry Pi OS uses cloud-init to re-template /etc/hostname and
#       /etc/hosts on boot, which silently undoes manual renames).
#    2. Sets the runtime hostname via hostnamectl.
#    3. Updates /etc/hostname and /etc/hosts.
#    4. Restarts avahi-daemon so mDNS broadcasts the new name immediately.
#    5. Prompts to reboot.
#
#  Usage:
#    sudo bash migrate-hostname.sh           # rename to default "inv"
#    sudo bash migrate-hostname.sh somename  # rename to a different name
# ============================================================================
set -euo pipefail

RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BLUE=$'\033[34m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
info()  { echo "${BLUE}${BOLD}==>${RESET} $*"; }
ok()    { echo "  ${GREEN}✓${RESET} $*"; }
warn()  { echo "  ${YELLOW}!${RESET} $*"; }
fail()  { echo "  ${RED}✗${RESET} $*" >&2; exit 1; }

if [ "$EUID" -ne 0 ]; then
  fail "Run with sudo."
fi

NEW_HOSTNAME="${1:-inv}"
OLD_HOSTNAME=$(hostname)

if [ "$OLD_HOSTNAME" = "$NEW_HOSTNAME" ]; then
  ok "Already named '$NEW_HOSTNAME' — nothing to do."
  exit 0
fi

info "Renaming hostname: '$OLD_HOSTNAME' → '$NEW_HOSTNAME'"

# 1. Cloud-init override — must come first or steps 2-4 get rolled back on next boot.
if [ -d /etc/cloud/cloud.cfg.d ]; then
  cat > /etc/cloud/cloud.cfg.d/99-zzz-hostname.cfg <<'EOF'
# Prevents cloud-init from rewriting hostname/hosts on every boot.
# Written by migrate-hostname.sh (or install.sh on fresh installs).
preserve_hostname: true
manage_etc_hosts: false
EOF
  ok "cloud-init hostname management disabled"
else
  warn "No /etc/cloud/cloud.cfg.d directory — this Pi may not use cloud-init."
  warn "If the hostname reverts after reboot, file an issue."
fi

# 2. Runtime hostname.
hostnamectl set-hostname "$NEW_HOSTNAME"
ok "Runtime hostname set"

# 3. /etc/hostname.
echo "$NEW_HOSTNAME" > /etc/hostname
ok "/etc/hostname written"

# 4. /etc/hosts — replace the old name everywhere it appears as a whole word.
# The \b word boundaries prevent accidental matches inside paths or comments.
sed -i "s/\\b${OLD_HOSTNAME}\\b/${NEW_HOSTNAME}/g" /etc/hosts
# Make sure the 127.0.1.1 entry exists at all.
if ! grep -qE '^127\.0\.1\.1\s' /etc/hosts; then
  echo "127.0.1.1 ${NEW_HOSTNAME} ${NEW_HOSTNAME}" >> /etc/hosts
fi
ok "/etc/hosts updated"

# 5. mDNS — restart avahi so it advertises the new name without waiting for boot.
systemctl restart avahi-daemon 2>/dev/null || warn "avahi-daemon not running"
ok "avahi-daemon reloaded (mDNS advertising '$NEW_HOSTNAME')"

echo
echo "${GREEN}${BOLD}Hostname migration complete.${RESET}"
echo
echo "Reach this Pi at: ${BOLD}http://${NEW_HOSTNAME}.local/${RESET}"
echo
echo "A reboot is recommended to ensure all services pick up the new name."
echo "Reboot now? (y/N)"
read -r REPLY
if [[ "$REPLY" =~ ^[Yy]$ ]]; then
  info "Rebooting…"
  reboot
else
  warn "Reboot skipped. Some services may still reference the old hostname"
  warn "in their logs until you reboot."
fi
