#!/usr/bin/env bash
set -euo pipefail

FEED_SERVICE="adsbitalia-feed.service"
MLAT_SERVICE="adsbitalia-mlat.service"
REG_SERVICE="adsbitalia-registration.service"
REG_TIMER="adsbitalia-registration.timer"

FEED_UNIT="/etc/systemd/system/${FEED_SERVICE}"
MLAT_UNIT="/etc/systemd/system/${MLAT_SERVICE}"
REG_UNIT="/etc/systemd/system/${REG_SERVICE}"
REG_TIMER_UNIT="/etc/systemd/system/${REG_TIMER}"

REG_HEARTBEAT_SCRIPT="/usr/local/sbin/adsbitalia-register-heartbeat"

MLAT_VENV="/opt/adsbitalia-mlat"

CONFIG_DIR="/etc/adsbitalia"
CONFIG_FILE="${CONFIG_DIR}/feeder.conf"

# Optional local ADSBItalia map based on tar1090
ADSBITALIA_TAR1090_MARKER="${CONFIG_DIR}/tar1090-installed"
TAR1090_HTML_DIRS=(
    "/usr/local/share/tar1090/html"
    "/usr/share/tar1090/html"
    "/var/www/html/tar1090"
)

TAR1090_PATHS=(
    "/usr/local/share/tar1090"
    "/usr/share/tar1090"
    "/var/www/html/tar1090"
    "/var/lib/tar1090"
    "/run/tar1090"
    "/etc/default/tar1090"
    "/etc/lighttpd/conf-enabled/89-tar1090.conf"
    "/etc/lighttpd/conf-available/89-tar1090.conf"
    "/etc/lighttpd/conf-enabled/88-tar1090.conf"
    "/etc/lighttpd/conf-available/88-tar1090.conf"
    "/etc/apache2/conf-enabled/tar1090.conf"
    "/etc/apache2/conf-available/tar1090.conf"
    "/etc/nginx/sites-enabled/tar1090"
    "/etc/nginx/sites-available/tar1090"
)

msg() {
    echo "[ADSBItalia] $*"
}

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        echo "Please run this script as root."
        exit 1
    fi
}

remove_service() {
    local service="$1"
    local unit="$2"

    if systemctl list-unit-files 2>/dev/null | grep -q "^${service}"; then
        msg "Stopping ${service}..."
        systemctl stop "${service}" 2>/dev/null || true

        msg "Disabling ${service}..."
        systemctl disable "${service}" 2>/dev/null || true
    fi

    if [[ -f "${unit}" ]]; then
        msg "Removing ${unit}..."
        rm -f "${unit}"
    fi

    if [[ -L "/etc/systemd/system/multi-user.target.wants/${service}" ]]; then
        rm -f "/etc/systemd/system/multi-user.target.wants/${service}"
    fi

    if [[ -L "/etc/systemd/system/timers.target.wants/${service}" ]]; then
        rm -f "/etc/systemd/system/timers.target.wants/${service}"
    fi
}

remove_path() {
    local path="$1"

    if [[ -e "$path" || -L "$path" ]]; then
        msg "Removing ${path}..."
        rm -rf "$path"
    fi
}

adsbitalia_tar1090_detected() {
    # 1. Check for dedicated marker file created exclusively by ADSBItalia installer
    if [[ -f "$ADSBITALIA_TAR1090_MARKER" ]]; then
        return 0
    fi

    # 2. Only consider configured URL if it contains a non-empty, valid URL scheme (not just TAR1090_LOCAL_URL=)
    if [[ -f "$CONFIG_FILE" ]] && grep -q '^TAR1090_LOCAL_URL=https\?://' "$CONFIG_FILE"; then
        return 0
    fi

    # 3. Check for ADSBItalia custom branding files injected into tar1090
    for dir in "${TAR1090_HTML_DIRS[@]}"; do
        if [[ -f "${dir}/adsbitalia-brand.css" || -f "${dir}/adsbitalia-brand.js" ]]; then
            return 0
        fi

        if [[ -f "${dir}/index.html" ]] && grep -q 'adsbitalia-brand' "${dir}/index.html"; then
            return 0
        fi
    done

    return 1
}

remove_adsbitalia_tar1090_branding() {
    local dir=""

    for dir in "${TAR1090_HTML_DIRS[@]}"; do
        if [[ -d "$dir" ]]; then
            rm -f "${dir}/adsbitalia-brand.css" "${dir}/adsbitalia-brand.js"

            if [[ -f "${dir}/index.html" ]]; then
                python3 - "${dir}/index.html" <<'PY' || true
from pathlib import Path
import sys

index = Path(sys.argv[1])
html = index.read_text(encoding="utf-8", errors="ignore")

lines = []
for line in html.splitlines():
    if "adsbitalia-brand.css" in line:
        continue
    if "adsbitalia-brand.js" in line:
        continue
    lines.append(line)

index.write_text("\n".join(lines) + "\n", encoding="utf-8")
PY
            fi
        fi
    done
}

remove_optional_tar1090() {
    if ! adsbitalia_tar1090_detected; then
        msg "Optional ADSBItalia tar1090 local map not detected or not installed by ADSBItalia. Skipping tar1090 removal to preserve existing web views."
        return 0
    fi

    msg "Removing optional ADSBItalia tar1090 local map..."

    remove_adsbitalia_tar1090_branding

    for unit in tar1090.service tar1090.timer; do
        if systemctl list-unit-files 2>/dev/null | grep -q "^${unit}"; then
            msg "Stopping ${unit}..."
            systemctl stop "$unit" 2>/dev/null || true

            msg "Disabling ${unit}..."
            systemctl disable "$unit" 2>/dev/null || true
        fi

        remove_path "/etc/systemd/system/${unit}"
        remove_path "/etc/systemd/system/multi-user.target.wants/${unit}"
        remove_path "/etc/systemd/system/timers.target.wants/${unit}"
    done

    for path in "${TAR1090_PATHS[@]}"; do
        remove_path "$path"
    done

    systemctl reload apache2 2>/dev/null || true
    systemctl restart lighttpd 2>/dev/null || true
    systemctl reload nginx 2>/dev/null || true

    msg "Optional ADSBItalia tar1090 local map removed."
}

main() {
    require_root

    msg "Removing ADSBItalia services..."

    # Stop and remove feed service
    remove_service "${FEED_SERVICE}" "${FEED_UNIT}"
    
    # Stop and remove MLAT client service
    remove_service "${MLAT_SERVICE}" "${MLAT_UNIT}"

    # Stop and remove registration heartbeat service and timer
    remove_service "${REG_TIMER}" "${REG_TIMER_UNIT}"
    remove_service "${REG_SERVICE}" "${REG_UNIT}"

    # Remove registration heartbeat script
    remove_path "${REG_HEARTBEAT_SCRIPT}"

    msg "Reloading systemd..."
    systemctl daemon-reload

    # Safely handle optional tar1090 removal if installed by ADSBItalia
    remove_optional_tar1090

    if [[ -d "${MLAT_VENV}" ]]; then
        msg "Removing MLAT virtual environment..."
        rm -rf "${MLAT_VENV}"
    fi

    if [[ -d "${CONFIG_DIR}" ]]; then
        msg "Removing ADSBItalia configuration..."
        rm -rf "${CONFIG_DIR}"
    fi

    msg "Cleanup completed successfully."
    msg "Your main readsb/dump1090 installation was NOT modified."
    msg "Note: System packages (e.g. socat, python3-venv) were kept intact to ensure other feeders remain fully functional."
}

main "$@"
