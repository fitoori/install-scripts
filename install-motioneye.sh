#!/usr/bin/env bash
# motionEye one-script installer (idempotent, platform-aware; includes fix_perms)
# - Installs motionEye into /opt/motioneye (Python venv)
# - Creates service user/group, config, logs
# - Sets up hardened systemd unit
# - Incorporates a robust permission fixer, adapted for venv installs
# - Re-run safe; set ME_UPGRADE=1 to upgrade within the venv; set ME_PRE=0 to avoid --pre builds

set -Eeuo pipefail
IFS=$'\n\t'
umask 027
shopt -s nullglob

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log() { printf '[%s] %s\n' "$(ts)" "$*"; }
warn() { printf '[%s] WARNING: %s\n' "$(ts)" "$*" >&2; }
die() { printf '[%s] ERROR: %s\n' "$(ts)" "$*" >&2; exit 1; }
trap 'die "Installer failed at line $LINENO. See logs above."' ERR

[[ $EUID -eq 0 ]] || die "Run as root (sudo)."
command -v uname >/dev/null 2>&1 || die "uname not found."
command -v awk   >/dev/null 2>&1 || die "awk not found."

#---- Constants
readonly ME_VENV="/opt/motioneye"
readonly ME_USER="motioneye"
readonly ME_GROUP="motioneye"
readonly ME_CONF_DIR="/etc/motioneye"
readonly ME_CONF="$ME_CONF_DIR/motioneye.conf"
readonly ME_MEDIA="/var/lib/motioneye"
readonly ME_LOG="/var/log/motioneye"
readonly ME_SERVICE="/etc/systemd/system/motioneye.service"
readonly ME_LOGROTATE="/etc/logrotate.d/motioneye"
readonly ME_PORT="8765"
readonly NEED_PRE="${ME_PRE:-1}"
readonly WANT_UPGRADE="${ME_UPGRADE:-1}"
readonly WANT_REINSTALL="${ME_REINSTALL:-0}"

#---- OS / pkg manager detection
if [[ -r /etc/os-release ]]; then . /etc/os-release; fi
PKG=""
if command -v apt-get >/dev/null 2>&1; then PKG="apt"
elif command -v dnf     >/dev/null 2>&1; then PKG="dnf"
elif command -v yum     >/dev/null 2>&1; then PKG="yum"
elif command -v zypper  >/dev/null 2>&1; then PKG="zypper"
elif command -v pacman  >/dev/null 2>&1; then PKG="pacman"
else die "Unsupported package manager. Use Debian/Ubuntu/Fedora/RHEL/openSUSE/Arch."; fi

command -v systemctl >/dev/null 2>&1 || die "systemd not found."
if ! pidof systemd >/dev/null 2>&1; then warn "PID 1 is not systemd. Proceeding may fail."; fi

#---- Network check + link validation (fail hard if core endpoints are unreachable)
require_url() { command -v curl >/dev/null 2>&1 && curl -fsSLI --retry 3 --retry-delay 1 --max-time 10 "$1" >/dev/null; }
ensure_net() {
  if ! require_url "https://github.com/motioneye-project/motioneye"; then die "Cannot reach GitHub repo."; fi
  if ! require_url "https://pypi.org/simple/motioneye/"; then die "Cannot reach PyPI index for motioneye."; fi
}
ensure_net

#---- Pkg helpers
pkg_available() {
  case "$PKG" in
    apt)   apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/{print $2}' | grep -qv '(none)' ;;
    dnf)   dnf -q list --available "$1" >/dev/null 2>&1 ;;
    yum)   yum -q list available "$1" >/dev/null 2>&1 ;;
    zypper) zypper -q info "$1" >/dev/null 2>&1 ;;
    pacman) pacman -Si "$1" >/dev/null 2>&1 ;;
  esac
}
pkg_install() {
  case "$PKG" in
    apt)
      DEBIAN_FRONTEND=noninteractive apt-get update -qq
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
      ;;
    dnf) dnf -y install "$@" ;;
    yum) yum -y install "$@" ;;
    zypper) zypper --non-interactive install --no-recommends "$@" ;;
    pacman) pacman -Sy --noconfirm --needed "$@" ;;
  esac
}
pkg_maybe_install() {
  local have_any=0
  for p in "$@"; do pkg_available "$p" && have_any=1; done
  (( have_any == 1 )) || { warn "Skipping optional packages (not available): $*"; return 0; }
  case "$PKG" in
    apt)
      DEBIAN_FRONTEND=noninteractive apt-get update -qq
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@" || warn "Optional install failed: $*"
      ;;
    dnf) dnf -y install "$@" || warn "Optional install failed: $*";;
    yum) yum -y install "$@" || warn "Optional install failed: $*";;
    zypper) zypper --non-interactive install --no-recommends "$@" || warn "Optional install failed: $*";;
    pacman) pacman -Sy --noconfirm --needed "$@" || warn "Optional install failed: $*";;
  esac
}

#---- Core prerequisites
ARCH="$(uname -m || true)"
log "Detected: pkgmgr=$PKG os_id=${ID:-unknown} arch=$ARCH"

case "$PKG" in
  apt)
    pkg_install ca-certificates curl python3 python3-venv
    if [[ "$ARCH" =~ ^(armv6l|armv7l|riscv64)$ ]]; then
      pkg_maybe_install python3-dev gcc libjpeg62-turbo-dev libcurl4-openssl-dev libssl-dev
    fi
    ;;
  dnf|yum)
    pkg_install ca-certificates curl python3 python3-pip python3-virtualenv gcc
    if [[ "$ARCH" =~ ^(armv6l|armv7l|armhf|riscv64)$ ]]; then
      pkg_maybe_install python3-devel libjpeg-turbo-devel libcurl-devel openssl-devel
    fi
    ;;
  zypper)
    pkg_install ca-certificates curl python3 python3-pip python3-virtualenv gcc
    if [[ "$ARCH" =~ ^(armv6l|armv7l|armhf|riscv64)$ ]]; then
      pkg_maybe_install python3-devel libjpeg62-devel libcurl-devel libopenssl-devel
    fi
    ;;
  pacman)
    pkg_install ca-certificates curl python python-pip
    if [[ "$ARCH" =~ ^(armv6l|armv7l)$ ]]; then
      pkg_maybe_install base-devel libjpeg-turbo curl openssl
    fi
    ;;
esac

# Optional runtime (recommended when using local cameras)
pkg_maybe_install motion ffmpeg v4l-utils

#---- Users/dirs
getent group "$ME_GROUP" >/dev/null 2>&1 || groupadd --system "$ME_GROUP"
id "$ME_USER" >/dev/null 2>&1 || useradd --system --no-create-home --home-dir "$ME_MEDIA" --shell /usr/sbin/nologin -g "$ME_GROUP" "$ME_USER"
install -d -o "$ME_USER" -g "$ME_GROUP" -m 0750 "$ME_MEDIA"
install -d -o "$ME_USER" -g "$ME_GROUP" -m 0750 "$ME_LOG"
install -d -o root     -g root       -m 0755 "$ME_CONF_DIR"

#---- Python venv + motionEye install
ensure_venv() {
  if [[ -x "$ME_VENV/bin/python3" ]]; then
    if ! "$ME_VENV/bin/python3" - <<'PY'; then
import sys
import sysconfig
assert sys.prefix, "Missing venv prefix"
assert sysconfig.get_paths().get("purelib"), "Missing site-packages"
PY
      warn "Existing motionEye venv is broken; recreating at $ME_VENV"
      rm -rf "$ME_VENV"
    fi
  fi

  if [[ ! -x "$ME_VENV/bin/python3" ]]; then
    log "Creating virtualenv at $ME_VENV"
    python3 -m venv "$ME_VENV"
  fi
}
ensure_venv
fix_venv_perms() {
  # The service runs as $ME_USER; ensure the venv is traversable/readable by that user.
  chown -R root:"$ME_GROUP" "$ME_VENV"
  chmod -R g+rX "$ME_VENV"
  chmod -R o-rwx "$ME_VENV"
}
fix_venv_perms
"$ME_VENV/bin/python" -m pip --version >/dev/null 2>&1 || "$ME_VENV/bin/python" -m ensurepip --upgrade
"$ME_VENV/bin/python" -m pip install --upgrade --disable-pip-version-check pip setuptools wheel

PIP_FLAGS=()
(( NEED_PRE == 1 )) && PIP_FLAGS+=(--pre)

PIP_REPAIR_FLAGS=()
HAS_MOTION=0
if "$ME_VENV/bin/python" -m pip show motioneye >/dev/null 2>&1; then HAS_MOTION=1; fi
if (( HAS_MOTION == 1 )); then
  if [[ ! -x "$ME_VENV/bin/meyectl" ]]; then
    warn "motionEye install missing meyectl; will force reinstall."
    PIP_REPAIR_FLAGS+=(--force-reinstall)
  fi
fi
if (( WANT_REINSTALL == 1 )); then
  log "ME_REINSTALL=1 requested; forcing reinstall of motionEye."
  PIP_REPAIR_FLAGS+=(--force-reinstall)
fi

if (( HAS_MOTION == 1 )); then
  log "motionEye already installed; ensuring it is up to date."
  if (( WANT_UPGRADE == 1 )); then
    "$ME_VENV/bin/python" -m pip install "${PIP_FLAGS[@]}" "${PIP_REPAIR_FLAGS[@]}" --upgrade motioneye
  else
    log "Skipping motionEye upgrade (ME_UPGRADE=0)."
  fi
else
  log "Installing motionEye..."
  "$ME_VENV/bin/python" -m pip install "${PIP_FLAGS[@]}" motioneye
fi

fix_venv_perms
if ! su -s /bin/sh - "$ME_USER" -c "test -x '$ME_VENV/bin/python' && test -x '$ME_VENV/bin/meyectl'" >/dev/null 2>&1; then
  die "Service user $ME_USER cannot access $ME_VENV; check directory permissions."
fi

INSTALLED_VER="$("$ME_VENV/bin/python" -m pip show motioneye 2>/dev/null | awk -F': ' '/^Version/{print $2}')"
[[ -n "$INSTALLED_VER" ]] && log "motionEye version: $INSTALLED_VER"
"$ME_VENV/bin/python" -m pip check >/dev/null 2>&1 || warn "Detected Python package conflicts; reinstall with ME_REINSTALL=1 if issues persist."

#---- Default config if missing
if [[ ! -f "$ME_CONF" ]]; then
  cat >"$ME_CONF" <<CONF
conf_path $ME_CONF_DIR
run_path /run/motioneye
media_path $ME_MEDIA
log_path $ME_LOG
# Web UI: http://<host>:$ME_PORT/  (admin / empty password until changed)
CONF
  chown root:root "$ME_CONF"
  chmod 0640 "$ME_CONF"
fi

#---- systemd unit (hardened)
generate_unit() {
  cat <<UNIT
[Unit]
Description=motionEye Server
Documentation=https://github.com/motioneye-project/motioneye
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$ME_USER
Group=$ME_GROUP
WorkingDirectory=$ME_MEDIA
ExecStart=$ME_VENV/bin/meyectl startserver -c $ME_CONF
Restart=on-failure
RestartSec=5s

StateDirectory=motioneye
RuntimeDirectory=motioneye
LogsDirectory=motioneye

AmbientCapabilities=
CapabilityBoundingSet=
NoNewPrivileges=yes
PrivateTmp=yes
ProtectHome=yes
ProtectSystem=full
ReadWritePaths=$ME_MEDIA $ME_CONF_DIR $ME_LOG

[Install]
WantedBy=multi-user.target
UNIT
}
UNIT_CONTENT="$(generate_unit)"
if [[ ! -f "$ME_SERVICE" ]] || ! diff -q <(printf "%s" "$UNIT_CONTENT") "$ME_SERVICE" >/dev/null 2>&1; then
  printf "%s" "$UNIT_CONTENT" >"$ME_SERVICE"
  chmod 0644 "$ME_SERVICE"
fi
systemctl daemon-reload

#---- logrotate integration
ensure_logrotate() {
  local sample=""
  for p in "$ME_VENV"/lib/python*/site-packages/motioneye/extra/motioneye.logrotate \
           /usr/share/motioneye/extra/motioneye.logrotate \
           /usr/local/share/motioneye/extra/motioneye.logrotate; do
    [[ -f "$p" ]] && sample="$p" && break
  done

  if [[ -n "$sample" ]]; then
    log "Installing logrotate policy from official sample ($sample)."
    sed "s|/var/log/motioneye|$ME_LOG|g" "$sample" >"$ME_LOGROTATE"
  else
    cat >"$ME_LOGROTATE" <<ROTATE
$ME_LOG/*.log {
  daily
  missingok
  rotate 7
  compress
  delaycompress
  notifempty
  copytruncate
  create 0640 $ME_USER $ME_GROUP
}
ROTATE
  fi
}
ensure_logrotate

#---- Incorporate: robust permission fixer (adapted to venv/systemd)
fix_motioneye_perms() {
  command -v systemctl >/dev/null || die "systemctl not available"

  local svc_user svc_group
  svc_user="$(
    systemctl cat motioneye 2>/dev/null | awk -F= '/^[[:space:]]*User=/{gsub(/[[:space:]]*/,"",$2);print $2;exit}'
  )"
  if [[ -z "${svc_user}" ]]; then
    if getent passwd motion >/dev/null; then svc_user="motion"
    elif getent passwd "$ME_USER" >/dev/null; then svc_user="$ME_USER"
    else svc_user="root"; fi
  fi
  svc_group="$(id -gn "$svc_user" 2>/dev/null || echo "$svc_user")"

  systemctl stop motioneye 2>/dev/null || true
  systemctl reset-failed motioneye 2>/dev/null || true

  # Ensure config exists (try venv + system paths for sample; otherwise synthesize)
  if [[ ! -f "$ME_CONF" ]]; then
    install -d -m 0755 -o root -g root "$ME_CONF_DIR"
    local sample=""
    for p in "$ME_VENV"/lib/python*/site-packages/motioneye/extra/motioneye.conf.sample \
             /usr/share/motioneye/extra/motioneye.conf.sample \
             /usr/local/share/motioneye/extra/motioneye.conf.sample; do
      [[ -f "$p" ]] && sample="$p" && break
    done
    if [[ -n "$sample" ]]; then
      cp -f "$sample" "$ME_CONF"
    else
      cat >"$ME_CONF" <<CONF
conf_path $ME_CONF_DIR
run_path /run/motioneye
media_path $ME_MEDIA
log_path $ME_LOG
CONF
    fi
  fi

  # Ownership/permissions
  chown -R "$svc_user:$svc_group" "$ME_CONF_DIR"
  chmod 0750 "$ME_CONF_DIR"
  chmod 0640 "$ME_CONF"

  # Ensure log directory exists and is owned by service user
  install -d -m 0750 -o "$svc_user" -g "$svc_group" "$ME_LOG"

  # Normalize mis-set log_path values
  if grep -Eq '^[[:space:]]*log_path[[:space:]]+/var/log/?$' "$ME_CONF"; then
    cp -a "$ME_CONF" "${ME_CONF}.bak.$(date +%s)"
    sed -E -i 's|^[[:space:]]*log_path[[:space:]]+/var/log/?$|log_path '"$ME_LOG"'|' "$ME_CONF"
  fi
}

# Apply permission fixes before enabling/starting
fix_motioneye_perms

#---- Enable & start
systemctl enable motioneye >/dev/null 2>&1 || true
systemctl restart motioneye || systemctl start motioneye

#---- Final checks
sleep 1
if systemctl is-active --quiet motioneye; then
  IP4="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  HOST_HINT="$(hostname -f 2>/dev/null || hostname || echo localhost)"
  log "motionEye is running."
  [[ -n "$IP4" ]] && log "UI: http://$IP4:$ME_PORT/" || true
  log "UI (hostname): http://$HOST_HINT:$ME_PORT/"
  systemctl --no-pager --full status motioneye | sed -n '1,12p' || true
else
  die "motionEye service is not active. Run: systemctl status motioneye"
fi

exit 0
