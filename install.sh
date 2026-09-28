#!/usr/bin/env bash
# ADSBItalia feeder installer
# Includes stable feeder identity and automatic registration heartbeat.

if [[ ! -t 0 || ! -t 1 ]]; then
  echo "This installer must be run in an interactive terminal."
  exit 1
fi

set -euo pipefail

# ── Public endpoints ─────────────────────────────────────────────────────────
FEED_HOST="feed.adsbitalia.it"
MLAT_HOST="mlat.adsbitalia.it"
FEED_PORT="31108"
MLAT_PORT="41113"
MLAT_RETURN_PORT_DEFAULT="33106"
MLAT_RETURN_PORT="${MLAT_RETURN_PORT_DEFAULT}"
SITE_URL="https://adsbitalia.it"
REGISTER_URL="${SITE_URL}/api/register-feeder"

# ── Local defaults ───────────────────────────────────────────────────────────
LOCAL_BEAST_PORT_DEFAULT="30005"
CONFIG_DIR="/etc/adsbitalia"
CONFIG_FILE="${CONFIG_DIR}/feeder.conf"

# ── MLAT ─────────────────────────────────────────────────────────────────────
MLAT_REPO="https://github.com/wiedehopf/mlat-client.git"
MLAT_VENV="/opt/adsbitalia-mlat"
MLAT_BIN="${MLAT_VENV}/bin/mlat-client"

# ── Optional tar1090 local map ───────────────────────────────────────────────
TAR1090_REPO="https://github.com/wiedehopf/tar1090.git"
TAR1090_WEB_PATH="/tar1090/"
TAR1090_INSTALLED="no"
TAR1090_LOCAL_URL=""

PUBLIC_IP_SERVICES=(
  "https://api.ipify.org"
  "https://ifconfig.me"
  "https://icanhazip.com"
)

msg()   { echo "[ADSBItalia] $*"; }
fatal() { echo "[ADSBItalia] ERROR: $*" >&2; exit 1; }

# ── Platform and validation ──────────────────────────────────────────────────
detect_distro() {
  if [[ -f /etc/arch-release ]]; then
    DISTRO="arch"
  elif [[ -f /etc/debian_version ]]; then
    DISTRO="debian"
  else
    fatal "Unsupported distribution. Supported: Debian/Ubuntu/Raspberry Pi OS/Arch."
  fi
}

install_packages() {
  msg "Installing dependencies..."
  if [[ "$DISTRO" == "arch" ]]; then
    sudo pacman -Syu --noconfirm --needed \
      whiptail curl git python python-pip base-devel iproute2 socat
  else
    sudo apt update
    sudo apt install -y \
      whiptail curl git ca-certificates python3 python3-pip python3-venv \
      python3-setuptools gcc build-essential iproute2 socat
  fi
}

validate_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 ))
}

validate_float() {
  [[ "$1" =~ ^-?[0-9]+([.][0-9]+)?$ ]]
}

validate_feeder_name() {
  [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]
}

normalize_number() {
  echo "${1//,/.}"
}

load_existing_config() {
  if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE" || true
  fi
}

# ── Interactive setup ────────────────────────────────────────────────────────
show_welcome() {
  whiptail --title "ADSBItalia Network" --msgbox "Welcome to the ADSBItalia installer.

This installer configures:

- ADS-B feed forwarding to ADSBItalia
- MLAT client
- Stable feeder identity (FEEDER_ID + FEEDER_TOKEN)
- Automatic registration heartbeat for IP changes
- Optional local ADSBItalia map based on tar1090

Your existing readsb/dump1090 installation will NOT be modified.

Feed: ${FEED_HOST}:${FEED_PORT}
MLAT: ${MLAT_HOST}:${MLAT_PORT}" 25 78
}

generate_feeder_identity() {
  sudo install -d -m 755 "$CONFIG_DIR"

  # Preserve identity during updates/reinstallations.
  if [[ -z "${FEEDER_ID:-}" ]]; then
    if [[ -r /proc/sys/kernel/random/uuid ]]; then
      FEEDER_ID="$(cat /proc/sys/kernel/random/uuid)"
    else
      FEEDER_ID="$(python3 - <<'PY'
import uuid
print(uuid.uuid4())
PY
)"
    fi
  fi

  if [[ -z "${FEEDER_TOKEN:-}" ]]; then
    FEEDER_TOKEN="$(python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(48))
PY
)"
  fi
}

collect_user_data() {
  local feeder_default="${FEEDER_NAME:-}"
  local lat_default="${LAT:-}"
  local lon_default="${LON:-}"
  local alt_default="${ALT:-}"
  local beast_default="${LOCAL_BEAST_PORT:-$LOCAL_BEAST_PORT_DEFAULT}"

  FEEDER_NAME="$(whiptail --inputbox "Enter your feeder name.

Allowed characters: A-Z a-z 0-9 . _ -
Spaces will be converted to underscores." \
    14 72 "$feeder_default" --title "Feeder Configuration" 3>&1 1>&2 2>&3)" || exit 1
  FEEDER_NAME="${FEEDER_NAME// /_}"

  LAT="$(whiptail --inputbox "Enter your latitude.\n\nExample: 44.8040" \
    12 60 "$lat_default" --title "Coordinates" 3>&1 1>&2 2>&3)" || exit 1
  LON="$(whiptail --inputbox "Enter your longitude.\n\nExample: 11.9730" \
    12 60 "$lon_default" --title "Coordinates" 3>&1 1>&2 2>&3)" || exit 1
  ALT="$(whiptail --inputbox "Enter altitude in meters.\n\nExample: 5" \
    12 60 "$alt_default" --title "Altitude" 3>&1 1>&2 2>&3)" || exit 1

  local mlat_return_default="${MLAT_RETURN_PORT:-$MLAT_RETURN_PORT_DEFAULT}"

  LOCAL_BEAST_PORT="$(whiptail --inputbox "Enter your local Beast OUT port.

Common examples:
30005
30006
30105
31005" \
    18 72 "$beast_default" --title "Local Beast OUT Port" 3>&1 1>&2 2>&3)" || exit 1

  MLAT_RETURN_PORT="$(whiptail --inputbox "Enter your local MLAT results return port (listen).

The MLAT client will listen on this port to feed MLAT aircraft positions back to your local decoder/map (readsb/tar1090/dump1090).

Common examples:
33106 (Default for ADSBItalia)
39008 (Ultrafeeder standard)
30105
30007" \
    19 74 "$mlat_return_default" --title "MLAT Results Return Port" 3>&1 1>&2 2>&3)" || exit 1

  LAT="$(normalize_number "$LAT")"
  LON="$(normalize_number "$LON")"
  ALT="$(normalize_number "$ALT")"

  [[ -n "$FEEDER_NAME" ]] || fatal "Feeder name cannot be empty."
  [[ -n "$LAT" && -n "$LON" && -n "$ALT" ]] || fatal "Coordinates and altitude cannot be empty."
  [[ -n "$LOCAL_BEAST_PORT" ]] || fatal "Local Beast port cannot be empty."
  [[ -n "$MLAT_RETURN_PORT" ]] || fatal "MLAT return port cannot be empty."

  validate_feeder_name "$FEEDER_NAME" || fatal "Invalid feeder name."
  validate_float "$LAT" || fatal "Invalid latitude."
  validate_float "$LON" || fatal "Invalid longitude."
  validate_float "$ALT" || fatal "Invalid altitude."
  validate_port "$LOCAL_BEAST_PORT" || fatal "Invalid local Beast port."
  validate_port "$MLAT_RETURN_PORT" || fatal "Invalid MLAT return port."
}

check_local_feed() {
  msg "Checking local Beast OUT feed on localhost:${LOCAL_BEAST_PORT}..."
  if ! timeout 3 bash -c "</dev/tcp/127.0.0.1/${LOCAL_BEAST_PORT}" 2>/dev/null; then
    whiptail --title "Local Beast feed not found" --msgbox "No Beast feed was detected on localhost:${LOCAL_BEAST_PORT}.

Select a local Beast OUT port from your existing readsb/dump1090 installation." 14 74
    exit 1
  fi
  msg "Local Beast feed reachable."
}

check_adsbitalia_dns() {
  msg "Checking ADSBItalia DNS records..."
  getent ahostsv4 "$FEED_HOST" >/dev/null 2>&1 || fatal "Unable to resolve ${FEED_HOST}."
  getent ahostsv4 "$MLAT_HOST" >/dev/null 2>&1 || fatal "Unable to resolve ${MLAT_HOST}."

  FEED_IP="$(getent ahostsv4 "$FEED_HOST" | awk 'NR==1 {print $1}')"
  MLAT_IP="$(getent ahostsv4 "$MLAT_HOST" | awk 'NR==1 {print $1}')"
  msg "DNS OK: ${FEED_HOST} -> ${FEED_IP}"
  msg "DNS OK: ${MLAT_HOST} -> ${MLAT_IP}"
}

check_remote_ports() {
  msg "Checking ADSBItalia remote ports..."
  if timeout 5 bash -c "</dev/tcp/${FEED_HOST}/${FEED_PORT}" 2>/dev/null; then
    msg "Feed port reachable: ${FEED_HOST}:${FEED_PORT}"
  else
    msg "Warning: feed port not reachable now; service will retry after installation."
  fi

  if timeout 5 bash -c "</dev/tcp/${MLAT_HOST}/${MLAT_PORT}" 2>/dev/null; then
    msg "MLAT port reachable: ${MLAT_HOST}:${MLAT_PORT}"
  else
    msg "Warning: MLAT port not reachable now; service will retry after installation."
  fi
}

save_config() {
  msg "Saving configuration..."
  sudo install -d -m 755 "$CONFIG_DIR"

  sudo tee "$CONFIG_FILE" >/dev/null <<EOFCONF
FEEDER_NAME=$FEEDER_NAME
FEEDER_ID=$FEEDER_ID
FEEDER_TOKEN=$FEEDER_TOKEN
LAT=$LAT
LON=$LON
ALT=$ALT
LOCAL_BEAST_PORT=$LOCAL_BEAST_PORT
FEED_HOST=$FEED_HOST
MLAT_HOST=$MLAT_HOST
FEED_PORT=$FEED_PORT
MLAT_PORT=$MLAT_PORT
MLAT_RETURN_PORT=$MLAT_RETURN_PORT
SITE_URL=$SITE_URL
REGISTER_URL=$REGISTER_URL
TAR1090_LOCAL_URL=${TAR1090_LOCAL_URL:-}
EOFCONF

  sudo chmod 600 "$CONFIG_FILE"
}

# ── MLAT ─────────────────────────────────────────────────────────────────────
install_mlat_client() {
  if [[ -x "$MLAT_BIN" ]]; then
    msg "MLAT client already installed."
    return
  fi

  msg "Installing MLAT client..."
  local tmpdir
  tmpdir="$(mktemp -d)"

  sudo mkdir -p "$MLAT_VENV"
  sudo python3 -m venv "$MLAT_VENV"
  sudo "$MLAT_VENV/bin/pip" install --upgrade --timeout 120 --retries 10 pip setuptools wheel

  sudo "$MLAT_VENV/bin/python" -c "import asyncore" >/dev/null 2>&1 || \
    sudo "$MLAT_VENV/bin/pip" install --timeout 120 --retries 10 pyasyncore

  if ! git clone "$MLAT_REPO" "$tmpdir/mlat-client"; then
    rm -rf "$tmpdir"
    fatal "Unable to clone the official mlat-client repository."
  fi

  sudo "$MLAT_VENV/bin/pip" install "$tmpdir/mlat-client"
  sudo rm -rf "$tmpdir"
}

# ── Systemd feed + MLAT services ─────────────────────────────────────────────
write_feed_service() {
  msg "Creating ADSBItalia feed service..."
  sudo tee /etc/systemd/system/adsbitalia-feed.service >/dev/null <<EOFUNIT
[Unit]
Description=ADSBItalia Feed Service
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/socat -u TCP:127.0.0.1:${LOCAL_BEAST_PORT},connect-timeout=10 TCP:${FEED_HOST}:${FEED_PORT},connect-timeout=10
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOFUNIT
}

write_mlat_service() {
  msg "Creating ADSBItalia MLAT service..."
  sudo tee /etc/systemd/system/adsbitalia-mlat.service >/dev/null <<EOFUNIT
[Unit]
Description=ADSBItalia MLAT Service
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
ExecStart=${MLAT_BIN} \\
  --input-type dump1090 \\
  --input-connect 127.0.0.1:${LOCAL_BEAST_PORT} \\
  --server ${MLAT_HOST}:${MLAT_PORT} \\
  --user ${FEEDER_NAME} \\
  --lat ${LAT} \\
  --lon ${LON} \\
  --alt ${ALT} \\
  --results beast,listen,${MLAT_RETURN_PORT}
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOFUNIT
}

# ── Stable identity + automatic public-IP refresh ────────────────────────────
write_registration_heartbeat() {
  msg "Creating authenticated registration heartbeat..."

  sudo tee /usr/local/sbin/adsbitalia-register-heartbeat >/dev/null <<'EOFHEART'
#!/usr/bin/env bash
# Runs locally on the feeder. It keeps the server record aligned with the
# feeder's current public IPv4 using the permanent FEEDER_ID + FEEDER_TOKEN.

set -euo pipefail

CONFIG_FILE="/etc/adsbitalia/feeder.conf"
PUBLIC_IP_SERVICES=(
  "https://api.ipify.org"
  "https://ifconfig.me"
  "https://icanhazip.com"
)

log() { echo "[ADSBItalia] $*"; }

[[ -r "$CONFIG_FILE" ]] || { log "Missing $CONFIG_FILE"; exit 1; }
# shellcheck disable=SC1090
source "$CONFIG_FILE"

: "${FEEDER_ID:?missing FEEDER_ID}"
: "${FEEDER_TOKEN:?missing FEEDER_TOKEN}"
: "${FEEDER_NAME:?missing FEEDER_NAME}"
: "${LAT:?missing LAT}"
: "${LON:?missing LON}"
: "${ALT:?missing ALT}"
: "${LOCAL_BEAST_PORT:?missing LOCAL_BEAST_PORT}"
: "${FEED_HOST:?missing FEED_HOST}"
: "${FEED_PORT:?missing FEED_PORT}"
: "${MLAT_HOST:?missing MLAT_HOST}"
: "${MLAT_PORT:?missing MLAT_PORT}"
: "${MLAT_RETURN_PORT:?missing MLAT_RETURN_PORT}"

REGISTER_URL="${REGISTER_URL:-https://adsbitalia.it/api/register-feeder}"

detect_public_ip() {
  local url candidate
  for url in "${PUBLIC_IP_SERVICES[@]}"; do
    candidate="$(curl -4fsS --connect-timeout 8 --max-time 12 "$url" 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ "$candidate" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      PUBLIC_IP="$candidate"
      return 0
    fi
  done
  return 1
}

build_payload() {
  python3 - \
    "$FEEDER_ID" "$FEEDER_TOKEN" "$FEEDER_NAME" "$PUBLIC_IP" "$HOSTNAME_LOCAL" \
    "$LOCAL_BEAST_PORT" "$FEED_HOST" "$FEED_PORT" "$MLAT_HOST" "$MLAT_PORT" \
    "$MLAT_RETURN_PORT" "$LAT" "$LON" "$ALT" <<'PY'
import json
import sys
(
    feeder_id, feeder_token, user, host, hostname, local_beast_port,
    feed_host, feed_port, mlat_host, mlat_port, mlat_return_port,
    lat, lon, alt,
) = sys.argv[1:]

print(json.dumps({
    "feeder_id": feeder_id,
    "feeder_token": feeder_token,
    "user": user,
    "host": host,
    "hostname": hostname,
    "beast_port": int(local_beast_port),
    "local_beast_port": int(local_beast_port),
    "feed_host": feed_host,
    "feed_port": int(feed_port),
    "feed_mode": "push",
    "mlat_host": mlat_host,
    "mlat_port": int(mlat_port),
    "mlat_return_port": int(mlat_return_port),
    "lat": lat,
    "lon": lon,
    "alt": alt,
}, separators=(",", ":")))
PY
}

detect_public_ip || { log "Unable to detect current public IPv4."; exit 1; }
HOSTNAME_LOCAL="$(hostname -f 2>/dev/null || hostname)"
PAYLOAD="$(build_payload)"

if curl -4fsS \
  --connect-timeout 10 \
  --max-time 25 \
  -H "Content-Type: application/json" \
  --data-binary "$PAYLOAD" \
  "$REGISTER_URL" >/dev/null; then
  log "Registration heartbeat completed for ${FEEDER_NAME} (${PUBLIC_IP})."
else
  log "Registration heartbeat failed."
  exit 1
fi
EOFHEART

  sudo chmod 700 /usr/local/sbin/adsbitalia-register-heartbeat

  sudo tee /etc/systemd/system/adsbitalia-registration.service >/dev/null <<'EOFSERVICE'
[Unit]
Description=ADSBItalia Feeder Registration Heartbeat
Wants=network-online.target
After=network-online.target adsbitalia-feed.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/adsbitalia-register-heartbeat
TimeoutStartSec=45s
EOFSERVICE

  sudo tee /etc/systemd/system/adsbitalia-registration.timer >/dev/null <<'EOFTIMER'
[Unit]
Description=Refresh ADSBItalia feeder registration

[Timer]
OnBootSec=30s
OnUnitActiveSec=10min
RandomizedDelaySec=60s
Persistent=true
Unit=adsbitalia-registration.service

[Install]
WantedBy=timers.target
EOFTIMER
}

enable_services() {
  msg "Enabling ADSBItalia services..."
  sudo systemctl daemon-reload
  sudo systemctl enable --now adsbitalia-feed.service
  sudo systemctl enable --now adsbitalia-mlat.service
  sudo systemctl enable --now adsbitalia-registration.timer

  # First registration immediately; timer retries every ten minutes.
  if sudo systemctl start adsbitalia-registration.service; then
    msg "Initial registration heartbeat completed."
  else
    msg "Initial registration heartbeat failed; timer will retry automatically."
  fi
}

# ── Optional tar1090 local map ───────────────────────────────────────────────
detect_local_lan_ip() {
  LOCAL_LAN_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  [[ -n "$LOCAL_LAN_IP" ]] || LOCAL_LAN_IP="127.0.0.1"
}

detect_aircraft_json() {
  AIRCRAFT_JSON_PATH=""
  local path
  for path in \
    /run/readsb/aircraft.json \
    /run/dump1090-fa/aircraft.json \
    /var/run/readsb/aircraft.json \
    /var/run/dump1090-fa/aircraft.json \
    /run/skyaware978/aircraft.json
  do
    if [[ -f "$path" ]]; then
      AIRCRAFT_JSON_PATH="$path"
      return 0
    fi
  done
  return 1
}

detect_ultrafeeder_docker() {
  command -v docker >/dev/null 2>&1 || return 1
  sudo docker ps --format '{{.Names}} {{.Image}}' 2>/dev/null \
    | grep -Eiq 'ultrafeeder|docker-adsb-ultrafeeder|sdr-enthusiasts'
}

find_tar1090_html_dir() {
  TAR1090_HTML_DIR=""
  local dir
  for dir in /usr/local/share/tar1090/html /usr/share/tar1090/html /var/www/html/tar1090; do
    if [[ -f "$dir/index.html" ]]; then
      TAR1090_HTML_DIR="$dir"
      return 0
    fi
  done
  return 1
}

apply_adsbitalia_tar1090_branding() {
  msg "Applying ADSBItalia branding to tar1090..."
  find_tar1090_html_dir || { msg "tar1090 HTML directory not found. Branding skipped."; return 0; }

  sudo tee "${TAR1090_HTML_DIR}/adsbitalia-brand.css" >/dev/null <<'EOFCSS'
#adsbitalia-local-badge {
  position:absolute; z-index:10000; left:12px; bottom:12px;
  display:inline-flex; align-items:center; gap:8px; padding:8px 11px;
  border-radius:999px; border:1px solid rgba(42,166,166,.55);
  background:rgba(13,16,20,.86); color:#edf2f7;
  font-family:system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;
  font-size:13px; line-height:1; box-shadow:0 8px 24px rgba(0,0,0,.35);
  backdrop-filter:blur(8px);
}
#adsbitalia-local-badge strong { color:#7fe7e7; font-weight:700; }
#adsbitalia-local-badge a { color:inherit; text-decoration:none; }
#adsbitalia-local-badge a:hover { color:#7fe7e7; }
@media (max-width:700px) {
  #adsbitalia-local-badge { left:8px; bottom:8px; font-size:12px; padding:7px 9px; }
}
EOFCSS

  sudo tee "${TAR1090_HTML_DIR}/adsbitalia-brand.js" >/dev/null <<'EOFJS'
(function () {
  "use strict";
  document.title = "ADSBItalia Local Map";
  function addBadge() {
    if (document.getElementById("adsbitalia-local-badge")) return;
    var badge = document.createElement("div");
    badge.id = "adsbitalia-local-badge";
    badge.innerHTML = '<a href="https://adsbitalia.it" target="_blank" rel="noopener noreferrer"><strong>ADSBItalia</strong> Local Map</a>';
    document.body.appendChild(badge);
  }
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", addBadge);
  } else {
    addBadge();
  }
})();
EOFJS

  sudo python3 - "${TAR1090_HTML_DIR}/index.html" <<'PY'
from pathlib import Path
import sys
index = Path(sys.argv[1])
html = index.read_text(encoding="utf-8", errors="ignore")
css = '<link rel="stylesheet" href="adsbitalia-brand.css?v=1">'
js = '<script src="adsbitalia-brand.js?v=1"></script>'
if "adsbitalia-brand.css" not in html:
    html = html.replace("</head>", f"  {css}\n</head>", 1) if "</head>" in html else css + "\n" + html
if "adsbitalia-brand.js" not in html:
    html = html.replace("</body>", f"  {js}\n</body>", 1) if "</body>" in html else html + "\n" + js + "\n"
index.write_text(html, encoding="utf-8")
PY
}

install_optional_tar1090() {
  msg "Installing optional local tar1090 map..."

  if ! detect_aircraft_json; then
    if ! whiptail --title "aircraft.json not detected" --yesno "No local aircraft.json was detected.

tar1090 may remain empty until readsb or dump1090 creates this file.

Continue anyway?" 15 76; then
      msg "Optional tar1090 local map skipped."
      return 0
    fi
  else
    msg "Detected local aircraft.json: ${AIRCRAFT_JSON_PATH}"
  fi

  local tmpdir
  tmpdir="$(mktemp -d)"
  if ! git clone --depth 1 "$TAR1090_REPO" "$tmpdir/tar1090"; then
    rm -rf "$tmpdir"
    msg "Unable to clone tar1090. Main feeder installation remains complete."
    return 0
  fi

  if ! sudo bash "$tmpdir/tar1090/install.sh"; then
    rm -rf "$tmpdir"
    msg "tar1090 installation failed. Main feeder installation remains complete."
    return 0
  fi
  rm -rf "$tmpdir"

  apply_adsbitalia_tar1090_branding
  sudo systemctl restart lighttpd 2>/dev/null || true
  sudo systemctl restart apache2 2>/dev/null || true
  sudo systemctl restart nginx 2>/dev/null || true

  detect_local_lan_ip
  TAR1090_LOCAL_URL="http://${LOCAL_LAN_IP}${TAR1090_WEB_PATH}"
  TAR1090_INSTALLED="yes"
  sudo touch "$CONFIG_DIR/tar1090-installed"
  sudo sed -i '/^TAR1090_LOCAL_URL=/d' "$CONFIG_FILE"
  echo "TAR1090_LOCAL_URL=${TAR1090_LOCAL_URL}" | sudo tee -a "$CONFIG_FILE" >/dev/null
  sudo chmod 600 "$CONFIG_FILE"

  whiptail --title "Local map installed" --msgbox "The optional ADSBItalia local map has been installed.

Open it from another device on your local network:

${TAR1090_LOCAL_URL}" 15 78
}

ask_optional_tar1090() {
  if [[ "$DISTRO" != "debian" ]]; then
    msg "Optional tar1090 local map skipped on this distribution."
    return 0
  fi

  if detect_ultrafeeder_docker; then
    whiptail --title "Ultrafeeder detected" --msgbox "Ultrafeeder/Docker appears to be running.

Do not install a separate tar1090 from this installer. Use the web interface already provided by Ultrafeeder." 14 76
    return 0
  fi

  if whiptail --title "Optional local ADSBItalia map" --yesno "Do you want to install an optional local ADSBItalia map based on tar1090?

Choose No if you already have a local map or only want to feed ADSBItalia." 15 76; then
    install_optional_tar1090
  else
    msg "Optional tar1090 local map skipped."
  fi
}

# ── Final status ─────────────────────────────────────────────────────────────
show_status() {
  local feed_state mlat_state heartbeat_state map_text
  feed_state="$(systemctl is-active adsbitalia-feed.service || true)"
  mlat_state="$(systemctl is-active adsbitalia-mlat.service || true)"
  heartbeat_state="$(systemctl is-active adsbitalia-registration.timer || true)"

  if [[ "${TAR1090_INSTALLED:-no}" == "yes" && -n "${TAR1090_LOCAL_URL:-}" ]]; then
    map_text="Optional local map:\n${TAR1090_LOCAL_URL}"
  else
    map_text="Optional local map:\nNot installed"
  fi

  whiptail --title "Installation Completed" --msgbox "ADSBItalia feeder installation completed.

Feed service: ${feed_state}
MLAT service: ${mlat_state}
Registration heartbeat: ${heartbeat_state}

Local Beast OUT port: ${LOCAL_BEAST_PORT}
MLAT results return port: ${MLAT_RETURN_PORT}
Feed destination: ${FEED_HOST}:${FEED_PORT}
MLAT destination: ${MLAT_HOST}:${MLAT_PORT}

${map_text}

Useful commands:

sudo systemctl status adsbitalia-feed
sudo systemctl status adsbitalia-mlat
sudo systemctl status adsbitalia-registration.timer

sudo systemctl start adsbitalia-registration.service
sudo journalctl -u adsbitalia-registration.service -n 50 --no-pager" 33 80
}

main() {
  detect_distro
  install_packages
  load_existing_config
  show_welcome
  collect_user_data
  generate_feeder_identity
  check_local_feed
  check_adsbitalia_dns
  check_remote_ports
  save_config
  install_mlat_client
  write_feed_service
  write_mlat_service
  write_registration_heartbeat
  enable_services
  ask_optional_tar1090
  show_status
}

main "$@"
