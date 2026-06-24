#!/usr/bin/env bash
set -Eeuo pipefail

REPO="${KOMARI_SAFE_REPO:-suckdrygod/tcpping}"
INSTALL_DIR='/opt/komari'
BINARY="$INSTALL_DIR/agent"
SERVICE='komari-agent.service'
DROPIN_DIR="/etc/systemd/system/${SERVICE}.d"

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo 'Run as root or with sudo.' >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo 'curl is required.' >&2; exit 1; }
command -v sha256sum >/dev/null 2>&1 || { echo 'sha256sum is required.' >&2; exit 1; }
systemctl cat "$SERVICE" >/dev/null 2>&1 || { echo "$SERVICE is not installed." >&2; exit 1; }

case "$(uname -m)" in
  x86_64|amd64) arch='amd64' ;;
  aarch64|arm64) arch='arm64' ;;
  *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

timezone=''
if command -v timedatectl >/dev/null 2>&1; then
  timezone="$(timedatectl show --property=Timezone --value 2>/dev/null || true)"
fi
if [[ -z "$timezone" && -r /etc/timezone ]]; then
  timezone="$(tr -d '[:space:]' </etc/timezone)"
fi
if [[ -z "$timezone" && -L /etc/localtime ]]; then
  timezone="$(readlink -f /etc/localtime | sed 's#^/usr/share/zoneinfo/##')"
fi
timezone="${timezone:-Etc/UTC}"
[[ "$timezone" =~ ^[A-Za-z0-9_+./-]+$ && -e "/usr/share/zoneinfo/$timezone" ]] || {
  echo "Unable to determine a valid VPS timezone: $timezone" >&2
  exit 1
}

tmp="$(mktemp)"
sumtmp="$(mktemp)"
trap 'rm -f "$tmp" "$sumtmp"' EXIT
asset="komari-agent-linux-${arch}"
url="https://github.com/${REPO}/releases/latest/download/${asset}"
checksums_url="https://github.com/${REPO}/releases/latest/download/SHA256SUMS"
echo "Downloading latest TCP-safe agent for ${arch}..."
curl -fL --proto '=https' --tlsv1.2 \
  --retry 8 --retry-all-errors --retry-delay 5 --connect-timeout 20 \
  "$url" -o "$tmp"
curl -fsSL --proto '=https' --tlsv1.2 \
  --retry 8 --retry-all-errors --retry-delay 5 --connect-timeout 20 \
  "$checksums_url" -o "$sumtmp"
(cd "$(dirname "$tmp")" && grep -E "  ${asset}$" "$sumtmp" | sed "s#  ${asset}\$#  $(basename "$tmp")#" | sha256sum -c -)
chmod 0755 "$tmp"

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
systemctl stop "$SERVICE"
if [[ -f "$BINARY" ]]; then
  cp -a "$BINARY" "${BINARY}.backup-${stamp}"
fi
install -m 0755 "$tmp" "$BINARY"

mkdir -p "$DROPIN_DIR"
cat >"$DROPIN_DIR/10-traffic-reset-timezone.conf" <<EOF
[Service]
Environment=TZ=${timezone}
Environment=AGENT_SSH_LOGIN_NOTIFY=true
Environment=AGENT_SECURITY_ACTION_SYNC=true
Environment=AGENT_SECURITY_ACTION_INTERVAL=15
EOF

systemctl daemon-reload
systemctl restart "$SERVICE"
systemctl --no-pager --full status "$SERVICE"

echo
echo "Agent upgraded. Traffic reset timezone: ${timezone}"
echo 'The existing endpoint, token, month-rotate day, and TCP allow-list were preserved.'
echo 'Panel queued security ban/unban sync is enabled (fixed nftables actions only).'
