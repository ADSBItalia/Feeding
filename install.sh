#!/usr/bin/env bash
# ADSBItalia feeder installer
# Includes stable feeder identity and automatic registration heartbeat.

if [[ ! -t 0 ]]; then
  if [[ -r /dev/tty ]]; then
    exec < /dev/tty
  else
    echo "This installer requires an interactive terminal or TTY."
    exit 1
  fi
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

# ── Optional Station Radar (Avionics Map) ───────────────────────────────────
STATION_RADAR_REPO="https://github.com/ADSBItalia/station-radar.git"
STATION_RADAR_PORT="8088"
STATION_RADAR_INSTALLED="no"
STATION_RADAR_LOCAL_URL=""

# ── Optional Station Graphs (RF Telemetry) ──────────────────────────────────
STATION_GRAPHS_REPO="https://github.com/ADSBItalia/station-graphs.git"
STATION_GRAPHS_PORT="8085"
STATION_GRAPHS_INSTALLED="no"
STATION_GRAPHS_LOCAL_URL=""

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
    sudo DEBIAN_FRONTEND=noninteractive apt-get update -y
    sudo DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get install -y --no-install-recommends \
      whiptail curl git ca-certificates python3 python3-dev python3-pip python3-venv \
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

  local email_default="${EMAIL:-}"
  EMAIL="$(whiptail --inputbox "Enter your email address (optional).\n\nReceive instant alerts if your station goes offline, MLAT sync warnings, and weekly/monthly performance digests.\n\nLeave blank to skip." \
    16 72 "$email_default" --title "Alert Notifications (Optional)" 3>&1 1>&2 2>&3)" || true
  EMAIL="$(echo "${EMAIL:-}" | tr -d '[:space:]')"

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
  local feed_ok=0
  if python3 -c "import socket; s=socket.socket(); s.settimeout(2.0); s.connect(('127.0.0.1', int('$LOCAL_BEAST_PORT'))); s.close()" >/dev/null 2>&1; then
    feed_ok=1
  elif python3 -c "import socket; s=socket.socket(socket.AF_INET6, socket.SOCK_STREAM); s.settimeout(2.0); s.connect(('::1', int('$LOCAL_BEAST_PORT'))); s.close()" >/dev/null 2>&1; then
    feed_ok=1
  fi

  if [[ "$feed_ok" -eq 1 ]]; then
    msg "Local Beast feed reachable."
  else
    if ! whiptail --title "Local Beast feed not detected" --yesno "No active Beast feed was detected on port ${LOCAL_BEAST_PORT}.

This can happen if readsb/dump1090 is still starting up or uses a different port.

Do you want to proceed anyway with port ${LOCAL_BEAST_PORT}?" 15 74; then
      fatal "Installation cancelled: local Beast feed on port ${LOCAL_BEAST_PORT} not found."
    fi
    msg "Continuing with local Beast port ${LOCAL_BEAST_PORT} as selected."
  fi
}

check_adsbitalia_dns() {
  msg "Checking ADSBItalia network connectivity and DNS resolution..."

  local needs_fallback=0
  for target in "adsbitalia.it" "$FEED_HOST" "$MLAT_HOST"; do
    if ! getent ahostsv4 "$target" >/dev/null 2>&1; then
      needs_fallback=1
      break
    fi
  done

  if (( needs_fallback == 1 )); then
    msg "Notice: Local ISP/router DNS cannot resolve ADSBItalia domains. Applying automatic direct host mapping..."
    sudo sed -i '/adsbitalia/d' /etc/hosts 2>/dev/null || true
    sudo tee -a /etc/hosts >/dev/null <<'EOF'
5.231.80.21 adsbitalia.it
185.119.19.188 feed.adsbitalia.it
185.119.19.188 mlat.adsbitalia.it
EOF
    if grep -qE '^nameserver (192\.168\.|10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.)' /etc/resolv.conf 2>/dev/null; then
      if ! grep -q '8.8.8.8' /etc/resolv.conf 2>/dev/null; then
        echo -e "nameserver 8.8.8.8\nnameserver 1.1.1.1" | sudo tee -a /etc/resolv.conf >/dev/null 2>&1 || true
      fi
    fi
  fi

  FEED_IP="$(getent ahostsv4 "$FEED_HOST" 2>/dev/null | awk 'NR==1 {print $1}' || echo "185.119.19.188")"
  MLAT_IP="$(getent ahostsv4 "$MLAT_HOST" 2>/dev/null | awk 'NR==1 {print $1}' || echo "185.119.19.188")"
  msg "DNS OK: ${FEED_HOST} -> ${FEED_IP}"
  msg "DNS OK: ${MLAT_HOST} -> ${MLAT_IP}"
}

check_remote_ports() {
  msg "Checking ADSBItalia remote ports..."
  if python3 -c "import socket; s=socket.socket(); s.settimeout(3.0); s.connect(('$FEED_HOST', int('$FEED_PORT'))); s.close()" >/dev/null 2>&1; then
    msg "Feed port reachable: ${FEED_HOST}:${FEED_PORT}"
  else
    msg "Warning: feed port not reachable now; service will retry after installation."
  fi

  if python3 -c "import socket; s=socket.socket(); s.settimeout(3.0); s.connect(('$MLAT_HOST', int('$MLAT_PORT'))); s.close()" >/dev/null 2>&1; then
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
EMAIL=${EMAIL:-}
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
  sudo "$MLAT_VENV/bin/pip" install --upgrade --timeout 30 --retries 3 pip setuptools wheel

  sudo "$MLAT_VENV/bin/python" -c "import asyncore" >/dev/null 2>&1 || \
    sudo "$MLAT_VENV/bin/pip" install --timeout 30 --retries 3 pyasyncore || true

  if ! git clone --depth 1 "$MLAT_REPO" "$tmpdir/mlat-client"; then
    rm -rf "$tmpdir"
    fatal "Unable to clone the official mlat-client repository."
  fi

  if ! sudo "$MLAT_VENV/bin/pip" install --timeout 60 "$tmpdir/mlat-client"; then
    rm -rf "$tmpdir"
    fatal "Failed to build/install mlat-client. Ensure python3-dev and gcc are installed."
  fi
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
ExecStart=/usr/bin/socat -u TCP:127.0.0.1:${LOCAL_BEAST_PORT},connect-timeout=10,keepalive,keepidle=30,keepintvl=10,keepcnt=3 TCP:${FEED_HOST}:${FEED_PORT},connect-timeout=10,keepalive,keepidle=30,keepintvl=10,keepcnt=3
Restart=always
RestartSec=5

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
    candidate="$(curl -4fsS --connect-timeout 5 --max-time 8 "$url" 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ "$candidate" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      PUBLIC_IP="$candidate"
      return 0
    fi
  done
  return 1
}

build_payload() {
  python3 - \
    "$FEEDER_ID" "$FEEDER_TOKEN" "$FEEDER_NAME" "${PUBLIC_IP:-}" "$HOSTNAME_LOCAL" \
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
    "host": host if host else "",
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

PUBLIC_IP=""
detect_public_ip || log "Notice: External public IP lookup timed out; server will auto-detect IPv4."
HOSTNAME_LOCAL="$(hostname -f 2>/dev/null || hostname)"
PAYLOAD="$(build_payload)"

if curl -4fsS \
  --connect-timeout 10 \
  --max-time 25 \
  -H "Content-Type: application/json" \
  --data-binary "$PAYLOAD" \
  "$REGISTER_URL" >/dev/null; then
  log "Registration heartbeat completed for ${FEEDER_NAME} (${PUBLIC_IP:-auto-detected})."
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

  # Optional feeder email alerts subscription
  if [[ -n "${EMAIL:-}" ]]; then
    msg "Subscribing ${EMAIL} to ADSBItalia feeder alerts..."
    local alert_res
    alert_res="$(curl -4fsS --connect-timeout 8 --max-time 15 -X POST "${SITE_URL}/api/alerts/subscribe" \
      -H "Content-Type: application/json" \
      -d "{\"station\":\"${FEEDER_NAME}\",\"email\":\"${EMAIL}\"}" 2>&1 || true)"
    if echo "$alert_res" | grep -q '"success":true'; then
      msg "Alert subscription initiated! A verification email has been sent to ${EMAIL}."
    else
      msg "Note: Feeder alerts can be verified on ${SITE_URL}/status.html once online."
    fi
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

install_optional_station_radar() {
  msg "Installing optional ADSBItalia Station Radar..."
  detect_local_lan_ip
  if bash <(curl -sL https://raw.githubusercontent.com/ADSBItalia/station-radar/main/install.sh) < /dev/null; then
    STATION_RADAR_LOCAL_URL="http://${LOCAL_LAN_IP}:${STATION_RADAR_PORT}"
    STATION_RADAR_INSTALLED="yes"
    sudo touch "$CONFIG_DIR/station-radar-installed"
    sudo sed -i '/^STATION_RADAR_LOCAL_URL=/d' "$CONFIG_FILE"
    echo "STATION_RADAR_LOCAL_URL=${STATION_RADAR_LOCAL_URL}" | sudo tee -a "$CONFIG_FILE" >/dev/null
    sudo chmod 600 "$CONFIG_FILE"
    whiptail --title "Station Radar Installed" --msgbox "The ADSBItalia Station Radar has been installed successfully.

Open it from any browser on your local network:

${STATION_RADAR_LOCAL_URL}

Station Control & Customization Panel:
${STATION_RADAR_LOCAL_URL}/settings.html" 17 78
  else
    msg "Station Radar installation skipped or encountered an issue. Feeder remains active."
  fi
}

ask_optional_station_radar() {
  if whiptail --title "ADSBItalia Station Radar (Optional)" --yesno "Do you want to install the ADSBItalia Station Radar?

Features:
- Modern avionics web radar (port 8088)
- 3D terrain, runways & airspace boundaries
- Bundled airline banners & autonomous vector logo generator
- Direct multi-source aircraft photo engine
- Responsive Station Control & Settings Panel (/settings.html)

Choose No if you already have a local map or only wish to feed data." 18 78; then
    install_optional_station_radar
  else
    msg "Optional ADSBItalia Station Radar skipped."
  fi
}

install_optional_station_graphs() {
  msg "Installing optional Station Telemetry & RF Performance Graphs..."
  detect_local_lan_ip
  if bash <(curl -sL https://raw.githubusercontent.com/ADSBItalia/station-graphs/main/install.sh) < /dev/null; then
    STATION_GRAPHS_LOCAL_URL="http://${LOCAL_LAN_IP}:${STATION_GRAPHS_PORT}"
    STATION_GRAPHS_INSTALLED="yes"
    sudo touch "$CONFIG_DIR/station-graphs-installed"
    sudo sed -i '/^STATION_GRAPHS_LOCAL_URL=/d' "$CONFIG_FILE"
    echo "STATION_GRAPHS_LOCAL_URL=${STATION_GRAPHS_LOCAL_URL}" | sudo tee -a "$CONFIG_FILE" >/dev/null
    sudo chmod 600 "$CONFIG_FILE"
    whiptail --title "Station Graphs Installed" --msgbox "ADSBItalia Station Telemetry & RF Graphs installed successfully.

Open the interactive telemetry dashboard from your local browser:

${STATION_GRAPHS_LOCAL_URL}" 16 78
  else
    msg "Station Graphs installation skipped or encountered an issue. Feeder remains active."
  fi
}

ask_optional_station_graphs() {
  if whiptail --title "Station Telemetry & RF Graphs (Optional)" --yesno "Do you want to install Station Telemetry & Performance Graphs?

Features:
- Real-time SDR metrics (Signal Peak, Median dBFS, Noise, SNR dB)
- Live message rate & position demodulation rates
- Interactive Chart.js historical telemetry (1h, 6h, 24h, 7d, 30d, 1yr)
- Dynamic 360° antenna reception polar diagram
- Live feeder health and network distribution monitor on port 8085

Choose No if you do not need telemetry graphs." 18 78; then
    install_optional_station_graphs
  else
    msg "Optional Station Telemetry & RF Graphs skipped."
  fi
}

# ── Final status ─────────────────────────────────────────────────────────────
show_status() {
  local feed_state mlat_state heartbeat_state map_text
  feed_state="$(systemctl is-active adsbitalia-feed.service || true)"
  mlat_state="$(systemctl is-active adsbitalia-mlat.service || true)"
  heartbeat_state="$(systemctl is-active adsbitalia-registration.timer || true)"

  local alerts_text
  if [[ -n "${EMAIL:-}" ]]; then
    alerts_text="Feeder alerts:\nConfigured for ${EMAIL} (Check inbox to verify)"
  else
    alerts_text="Feeder alerts:\nNot configured (You can subscribe anytime on ${SITE_URL}/status.html)"
  fi

  local radar_text graphs_text
  if [[ "${STATION_RADAR_INSTALLED:-no}" == "yes" && -n "${STATION_RADAR_LOCAL_URL:-}" ]]; then
    radar_text="Local Station Radar:\n${STATION_RADAR_LOCAL_URL}"
  else
    radar_text="Local Station Radar:\nNot installed"
  fi

  if [[ "${STATION_GRAPHS_INSTALLED:-no}" == "yes" && -n "${STATION_GRAPHS_LOCAL_URL:-}" ]]; then
    graphs_text="Station Telemetry & RF Graphs:\n${STATION_GRAPHS_LOCAL_URL}"
  else
    graphs_text="Station Telemetry & RF Graphs:\nNot installed"
  fi

  whiptail --title "Installation Completed" --msgbox "ADSBItalia feeder installation completed.

Feed service: ${feed_state}
MLAT service: ${mlat_state}
Registration heartbeat: ${heartbeat_state}

Local Beast OUT port: ${LOCAL_BEAST_PORT}
MLAT results return port: ${MLAT_RETURN_PORT}
Feed destination: ${FEED_HOST}:${FEED_PORT}
MLAT destination: ${MLAT_HOST}:${MLAT_PORT}

${alerts_text}

${radar_text}

${graphs_text}

Useful commands:

sudo systemctl status adsbitalia-feed
sudo systemctl status adsbitalia-mlat
sudo systemctl status adsbitalia-registration.timer

sudo systemctl start adsbitalia-registration.service
sudo journalctl -u adsbitalia-registration.service -n 50 --no-pager" 36 80
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
  ask_optional_station_radar
  ask_optional_station_graphs
  show_status
}

main "$@"
