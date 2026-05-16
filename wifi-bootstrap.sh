#!/usr/bin/env bash
# ============================================================================
#  WiFi AP-mode bootstrap installer
#  ----------------------------------------------------------------------------
#  Installs and configures comitup, which makes the Pi broadcast an open WiFi
#  hotspot called "Inv-Setup" when:
#    - The Pi has never been configured (no wifi profiles stored) — AP mode
#      immediately, no wait
#    - A configured Pi boots and can't find any of its known WiFi networks for
#      60 seconds — falls back to AP mode so user can reconfigure
#
#  Once a user connects through comitup's captive portal and provides
#  credentials, comitup switches the Pi to client mode. AP mode only returns
#  on the next fresh boot if WiFi is unreachable.
#
#  This script is called by install.sh during initial setup. It can also be
#  run standalone (idempotent).
# ============================================================================
set -euo pipefail

RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BLUE=$'\033[34m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
info()  { echo "${BLUE}${BOLD}==>${RESET} $*"; }
ok()    { echo "  ${GREEN}âœ“${RESET} $*"; }
warn()  { echo "  ${YELLOW}!${RESET} $*"; }
fail()  { echo "  ${RED}âœ—${RESET} $*" >&2; exit 1; }

if [ "$EUID" -ne 0 ]; then
  fail "Run with sudo."
fi

# Check for a WiFi device first - if there isn't one, AP mode is pointless
if ! ls /sys/class/net/ | grep -q '^wlan'; then
  warn "No WiFi device detected â€” skipping AP bootstrap install."
  warn "(Pi will work in ethernet-only mode.)"
  exit 0
fi

info "Installing comitup (WiFi AP-mode bootstrap)"
export DEBIAN_FRONTEND=noninteractive

# comitup is available in Debian Bookworm's main repos.
# On older releases or in case the package is missing, fall back to
# the upstream apt source.
if apt-cache show comitup >/dev/null 2>&1; then
  apt-get install -y -qq --no-install-recommends comitup
  ok "comitup installed from apt repo"
else
  warn "comitup not in main apt repo â€” adding upstream source"
  # Add the upstream apt source (davesteele/comitup maintainer)
  curl -fsSL -o /tmp/comitup-src.deb \
    "https://davesteele.github.io/comitup/latest/davesteele-comitup-apt-source_latest.deb" \
    || fail "Failed to download comitup apt source"
  dpkg -i /tmp/comitup-src.deb
  rm -f /tmp/comitup-src.deb
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends comitup
  ok "comitup installed from upstream source"
fi

# ---- Configure comitup ----------------------------------------------------
info "Configuring comitup"

# Comitup's main config: /etc/comitup.conf
# Settings we care about:
#   ap_name      - SSID prefix; comitup appends -XXXX from MAC automatically
#   ap_password  - leave blank for open network (during setup only)
#   web_service  - comitup's built-in captive portal page (keep enabled)
#   verbose      - 0 for production
#
# State machine timings:
#   start_state         - HOTSPOT means "AP mode if no configured wifi"
#                         CONNECTING means "try wifi first, then AP after timeout"
#   For our case: we want HOTSPOT (skip wait) when no profile, but
#   CONNECTING (60s timeout) when profiles exist. Comitup's default behavior
#   matches this: it always tries existing profiles first, falling back to
#   HOTSPOT if none connect within ~60s.

if [ -f /etc/comitup.conf ]; then
  cp /etc/comitup.conf /etc/comitup.conf.bak.$(date +%s)
fi

cat > /etc/comitup.conf <<'EOF'
# comitup configuration
# Edit this file to customize AP behavior; rerun comitup-cli if needed.

# AP SSID. Plain "Inv-Setup" - simple and friendly. Comitup's <nnn>
# suffix is supported (last 4 of MAC) but we omit it for simplicity.
# If two Pis end up nearby in AP mode simultaneously, change one to
# "Inv-Setup-<nnn>" to disambiguate.
ap_name: Inv-Setup

# AP password: blank = open network (only on during setup, then disappears)
ap_password:

# The web_service setting is the FULL systemd unit name comitup will
# start when entering HOTSPOT mode and stop when leaving. The default
# is comitup-web.service. Earlier values like 'enabled', 'nm-cli', or
# bare 'comitup-web' (without .service) crash comitup with dbus errors
# like "Unit name X is not valid".
web_service: comitup-web.service

# Verbose logs only when troubleshooting
verbose: 0

# Try connecting to existing WiFi profiles for up to this many seconds
# before falling back to AP mode. If no profiles exist, AP mode starts
# immediately.
primary_wifi_timeout: 60

# Don't include external services in the captive portal â€” keep it focused.
external_callback:
EOF

ok "comitup config written to /etc/comitup.conf"

# Enable comitup so it starts on boot
systemctl enable comitup.service >/dev/null 2>&1
systemctl enable comitup-web.service >/dev/null 2>&1
ok "comitup services enabled (will start on next reboot)"

echo
echo "${YELLOW}Note:${RESET} comitup will take effect on the next reboot."
echo "Until then, the Pi stays on whatever network it's currently using."
echo
echo "To trigger AP mode for testing without a reboot:"
echo "    sudo systemctl restart comitup"
