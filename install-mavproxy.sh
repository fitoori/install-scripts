#!/usr/bin/env bash
# MAVProxy installer for Debian 12 / Raspberry Pi OS (Bookworm)
# Idempotent, non-interactive, headless-safe, DietPi-friendly (uses venv)

set -euo pipefail
IFS=$'\n\t'

SCRIPT_NAME="$(basename "$0")"

log() {
    echo "[$SCRIPT_NAME] $*"
}

fail() {
    echo "[$SCRIPT_NAME] ERROR: $*" >&2
    exit 1
}

require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        fail "Must be run as root"
    fi
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

pkg_available() {
    apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/{print $2}' | grep -qv '(none)'
}

apt_install() {
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
}

apt_maybe_install() {
    local have_any=0
    for p in "$@"; do
        if pkg_available "$p"; then
            have_any=1
        else
            log "Optional package not available: $p"
        fi
    done

    if (( have_any == 0 )); then
        return 0
    fi

    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@" || \
        log "Optional package install failed: $*"
}

ensure_venv() {
    local venv_path="$1"

    if [[ -x "$venv_path/bin/python3" ]]; then
        if ! "$venv_path/bin/python3" - <<'PY'; then
import sys
import sysconfig
assert sys.prefix
assert sysconfig.get_paths().get("purelib")
PY
            log "Existing venv looks broken; recreating at $venv_path"
            rm -rf "$venv_path"
        fi
    fi

    if [[ ! -x "$venv_path/bin/python3" ]]; then
        log "Creating virtualenv at $venv_path"
        python3 -m venv "$venv_path"
    fi

    "$venv_path/bin/python" -m ensurepip --upgrade >/dev/null 2>&1 || true
    "$venv_path/bin/python" -m pip install --upgrade --disable-pip-version-check pip setuptools wheel
}

link_mavproxy() {
    local venv_path="$1"
    local target="$venv_path/bin/mavproxy.py"
    local link_path="/usr/local/bin/mavproxy.py"

    if [[ ! -x "$target" ]]; then
        fail "mavproxy.py not found in venv at $target"
    fi

    if [[ -L "$link_path" ]]; then
        local current
        current="$(readlink -f "$link_path")"
        if [[ "$current" == "$target" ]]; then
            return 0
        fi
    fi

    install -d /usr/local/bin
    ln -sfn "$target" "$link_path"
}

main() {
    require_root

    local venv_dir="${MAVPROXY_VENV:-/opt/mavproxy}"
    local install_gui="${MAVPROXY_GUI:-0}"

    log "Updating APT index"
    apt-get update -y

    log "Installing system dependencies"
    apt_install \
        python3 \
        python3-dev \
        python3-venv \
        python3-pip \
        libatlas-base-dev \
        libglib2.0-0 \
        libgl1

    apt_maybe_install \
        python3-lxml \
        python3-opencv

    if (( install_gui == 1 )); then
        log "Installing GUI-related optional dependencies (MAVPROXY_GUI=1)"
        apt_maybe_install \
            python3-matplotlib \
            python3-pygame \
            python3-wxgtk4.0
    fi

    if ! command_exists python3; then
        fail "python3 missing after install"
    fi

    ensure_venv "$venv_dir"

    log "Installing MAVProxy into venv"
    "$venv_dir/bin/python" -m pip install --upgrade --disable-pip-version-check \
        future \
        pymavlink \
        mavproxy

    link_mavproxy "$venv_dir"

    log "Validating MAVProxy execution"
    /usr/local/bin/mavproxy.py --version >/dev/null

    log "Ensuring dialout group exists"
    getent group dialout >/dev/null || groupadd dialout

    log "Installation complete"
    log "Add non-root users to serial group:"
    log "  sudo usermod -aG dialout <username>"
    log "Run MAVProxy: /usr/local/bin/mavproxy.py"
}

main "$@"
