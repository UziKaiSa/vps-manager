#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_VERSION="0.9.6-test"
SCRIPT_NAME="VPS Manager"
SCRIPT_UPDATE_URL="https://raw.githubusercontent.com/UziKaiSa/vps-manager/main/vps-manager.sh"

XRAY_BIN="/usr/local/bin/xray"
XRAY_CONFIG="/usr/local/etc/xray/config.json"
XRAY_INSTALL_URL="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"
KOMARI_INSTALL_URL="https://raw.githubusercontent.com/komari-monitor/komari-agent/refs/heads/main/install.sh"
KOMARI_DEFAULT_TEAM="your-team-name"
KOMARI_DEFAULT_PRIVATE_URL="http://komari.example.internal:8080"
KOMARI_TOKEN_ENV_FILE="/root/warp-token.env"
KOMARI_WARP_MIN_ROOT_MIB=3072
KOMARI_WARP_MIN_FREE_MIB=1536
KOMARI_WARP_LEGACY_MIN_FREE_MIB=400
KOMARI_WARP_LEGACY_VERSION="2026.1.150.0"
KOMARI_WARP_LEGACY_URL="https://downloads.cloudflareclient.com/v1/download/bookworm-intel/version/2026.1.150.0"
KOMARI_WARP_LEGACY_SHA256="049ad669140ac0f428a980ebd8b4bca7949307076d7cf51f6e5668c239d6ad87"
KOMARI_WARP_LEGACY_ARM64_URL="https://downloads.cloudflareclient.com/v1/download/bookworm-arm/version/2026.1.150.0"
KOMARI_WARP_LEGACY_ARM64_SHA256="4a1854dd5dae9cbbb88113297898aecd857e2b16d066238b7207212fc6435222"
KOMARI_WARP_LEGACY_JAMMY_URL="https://downloads.cloudflareclient.com/v1/download/jammy-intel/version/2026.1.150.0"
KOMARI_WARP_LEGACY_JAMMY_SHA256="4d54b54880c7c0eebbed8165ce876b43693884ef636b1517136645445a8681a"
KOMARI_WARP_LEGACY_NOBLE_URL="https://downloads.cloudflareclient.com/v1/download/noble-intel/version/2026.1.150.0"
KOMARI_WARP_LEGACY_NOBLE_SHA256="2e388e4746e2cb1918227f84da38786de3dded883feaa3ad4fb5be10a70bc30a"
KOMARI_WARP_LEGACY_BULLSEYE_URL="https://downloads.cloudflareclient.com/v1/download/bullseye-intel/version/2026.1.150.0"
KOMARI_WARP_LEGACY_BULLSEYE_SHA256="fcad2595a371f051b81f548b65f6cab93681690c45bda97bc4e729a8b14f4528"
ALPINE_WARP_ROOT="/opt/cloudflare-warp"
ALPINE_WARP_MIN_FREE_MIB=300
WARP_GUARD_PATH="/usr/local/sbin/vps-manager-warp-guard"
WARP_RSS_MAX_KIB=163840
ALPINE_WARP_LOG_MAX_BYTES=8388608
ALPINE_WARP_LOG_TAIL_BYTES=2097152

OS_ID=""
INIT_SYSTEM=""

SSHD_MAIN_CONFIG="/etc/ssh/sshd_config"
SSHD_DROPIN_DIR="/etc/ssh/sshd_config.d"
SSHD_MANAGED_CONFIG="${SSHD_DROPIN_DIR}/00-vps-manager-hardening.conf"
SSH_SOCKET_TRANSITIONED=0
SSH_SOCKET_WAS_ENABLED=0
SSH_SOCKET_WAS_ACTIVE=0

STATE_DIR="/etc/vps-manager"
STATE_FILE="${STATE_DIR}/state.json"
INFO_FILE="${STATE_DIR}/last-install.txt"
YAML_FILE="${STATE_DIR}/proxies.yaml"
BACKUP_ROOT="/var/backups/vps-manager"

DEMO_MODE=0
WORK_DIR=""
DEMO_CONFIG_FILE=""
DEMO_INFO_FILE=""
DEMO_YAML_FILE=""
DEMO_STATE_FILE=""
YAML_MANAGER_TARGET=""

XRAY_PENDING_MODEL=""
XRAY_CANDIDATE_CONFIG=""
XRAY_CANDIDATE_STATE=""
XRAY_CANDIDATE_INFO=""
XRAY_CANDIDATE_YAML=""
XRAY_CANDIDATE_READY=0
XRAY_UPDATE_DIRTY=0

CFG_NODE_NAME=""
CFG_PUBLIC_ADDRESS=""
CFG_REALITY_PORT=""
CFG_REALITY_DEST=""
CFG_SERVER_NAMES=""
CFG_ENABLE_SOCKS=0
CFG_SOCKS_LISTEN="127.0.0.1"
CFG_SOCKS_PORT=""
CFG_SOCKS_USER=""
CFG_SOCKS_PASS=""
CFG_ENABLE_SS=0
CFG_SS_LISTEN="0.0.0.0"
CFG_SS_PORT=""
CFG_SS_METHOD="2022-blake3-aes-128-gcm"
CFG_SS_PASS=""
declare -a CFG_PROXY_NAMES=()
declare -a CFG_PROXY_LINKS=()


cleanup() {
  if [[ -n "${WORK_DIR}" && "${WORK_DIR}" == /tmp/vps-manager.* && -d "${WORK_DIR}" ]]; then
    rm -rf -- "${WORK_DIR}"
  fi
}

trap cleanup EXIT


log() {
  printf '\n[%s] %s\n' "$(date '+%F %T')" "$*"
}


warn() {
  printf '\n警告: %s\n' "$*" >&2
}


die() {
  printf '\n错误: %s\n' "$*" >&2
  exit 1
}


pause_screen() {
  printf '\n'
  read -r -p "按回车返回主菜单..." _unused || true
}


prompt_default() {
  local prompt="$1"
  local default_value="$2"
  local value

  read -r -p "${prompt} [${default_value}]: " value
  printf '%s' "${value:-${default_value}}"
}


prompt_secret() {
  local prompt="$1"
  local value

  read -r -s -p "${prompt}: " value
  printf '\n' >&2
  printf '%s' "${value}"
}


prompt_yes_no() {
  local prompt="$1"
  local default_value="$2"
  local suffix
  local value

  if [[ "${default_value}" == "1" ]]; then
    suffix="Y/n"
  else
    suffix="y/N"
  fi

  while true; do
    read -r -p "${prompt} [${suffix}]: " value
    case "${value}" in
      y|Y|yes|YES|Yes) return 0 ;;
      n|N|no|NO|No) return 1 ;;
      "")
        [[ "${default_value}" == "1" ]]
        return
        ;;
      *) printf '请输入 y 或 n。\n' >&2 ;;
    esac
  done
}


require_root() {
  if [[ "${DEMO_MODE}" == "1" ]]; then
    return 0
  fi
  if [[ "${EUID}" -ne 0 ]]; then
    die "该操作需要 root 权限，请运行：sudo bash $0"
  fi
}


check_supported_os() {
  local os_id
  local os_like

  [[ -r /etc/os-release ]] || die "无法识别操作系统。"
  # shellcheck disable=SC1091
  . /etc/os-release
  os_id="${ID:-}"
  os_like="${ID_LIKE:-}"
  OS_ID="${os_id}"
  if [[ "${os_id}" == "alpine" ]]; then
    command -v apk >/dev/null 2>&1 || die "Alpine 系统缺少 apk。"
    command -v rc-service >/dev/null 2>&1 || die "Alpine 系统缺少 OpenRC。"
    INIT_SYSTEM="openrc"
    return 0
  fi
  if [[ "${os_id}" != "debian" && "${os_id}" != "ubuntu" && "${os_like}" != *debian* ]]; then
    die "当前测试版仅支持 Debian/Ubuntu，以及受限功能的 Alpine。"
  fi
  command -v systemctl >/dev/null 2>&1 || die "当前 Debian/Ubuntu 未使用 systemd。"
  INIT_SYSTEM="systemd"
}


is_alpine() {
  [[ "${OS_ID:-}" == "alpine" ]]
}


service_restart() {
  local service="$1"
  if is_alpine; then rc-service "${service}" restart; else systemctl restart "${service}.service"; fi
}


service_enable_start() {
  local service="$1"
  if is_alpine; then
    rc-update add "${service}" default >/dev/null 2>&1 || true
    rc-service "${service}" start
  else
    systemctl enable --now "${service}.service"
  fi
}


service_is_active() {
  local service="$1"
  if is_alpine; then rc-service "${service}" status >/dev/null 2>&1; else systemctl is-active --quiet "${service}.service"; fi
}


service_status_text() {
  local service="$1"
  if is_alpine; then rc-service "${service}" status 2>&1; else systemctl status "${service}.service" --no-pager -l 2>&1; fi
}


ensure_work_dir() {
  cleanup
  WORK_DIR="$(mktemp -d /tmp/vps-manager.XXXXXX)"
  chmod 700 "${WORK_DIR}"
}


mktemp_json() {
  local directory="$1"
  local prefix="$2"
  local reserved
  local destination

  reserved="$(mktemp "${directory}/${prefix}.XXXXXX")" || return 1
  destination="${reserved}.json"
  if ! mv -- "${reserved}" "${destination}"; then
    rm -f -- "${reserved}"
    return 1
  fi
  printf '%s' "${destination}"
}


backup_file() {
  local source="$1"
  local label="$2"
  local timestamp
  local destination_dir

  [[ -e "${source}" ]] || return 0
  timestamp="$(date -u '+%Y%m%dT%H%M%SZ')"
  destination_dir="${BACKUP_ROOT}/${label}-${timestamp}"
  install -d -m 700 "${destination_dir}"
  cp -a -- "${source}" "${destination_dir}/"
  printf '%s' "${destination_dir}"
}



repair_debian_bullseye_apt_sources() {
  local os_id=""
  local version_id=""
  local version_codename=""
  local backup_dir=""
  local source_file
  local candidate
  local relative_path
  local -a source_files=(/etc/apt/sources.list)

  [[ -r /etc/os-release ]] || return 0
  # shellcheck disable=SC1091
  . /etc/os-release
  os_id="${ID:-}"
  version_id="${VERSION_ID:-}"
  version_codename="${VERSION_CODENAME:-}"
  [[ "${os_id}" == "debian" ]] || return 0
  [[ "${version_codename}" == "bullseye" || "${version_id}" == "11" ]] || return 0

  while IFS= read -r -d '' source_file; do
    source_files+=("${source_file}")
  done < <(find /etc/apt/sources.list.d -maxdepth 1 -type f -name '*.list' -print0 2>/dev/null)

  for source_file in "${source_files[@]}"; do
    [[ -f "${source_file}" && ! -L "${source_file}" ]] || continue
    candidate="$(mktemp "${source_file}.vps-manager.XXXXXX")"
    sed -E \
      -e 's#https?://security\.debian\.org(/debian-security)?/?([[:space:]]+)bullseye/updates#http://security.debian.org/debian-security\2bullseye-security#g' \
      -e 's#https?://deb\.debian\.org/debian-security([[:space:]]+)bullseye/updates#http://security.debian.org/debian-security\1bullseye-security#g' \
      -e '/^[[:space:]]*deb(-src)?([[:space:]]+\[[^]]+\])?[[:space:]]+https?:\/\/deb\.debian\.org\/debian[[:space:]]+bullseye-backports([[:space:]]|$)/ s/^/# VPS Manager disabled EOL repository: /' \
      "${source_file}" > "${candidate}"

    if cmp -s -- "${source_file}" "${candidate}"; then
      rm -f -- "${candidate}"
      continue
    fi

    if [[ -z "${backup_dir}" ]]; then
      backup_dir="${BACKUP_ROOT}/apt-sources-$(date -u '+%Y%m%dT%H%M%SZ')"
      install -d -o root -g root -m 700 "${backup_dir}"
    fi
    relative_path="${source_file#/etc/apt/}"
    install -d -o root -g root -m 700 "${backup_dir}/$(dirname "${relative_path}")"
    cp -a -- "${source_file}" "${backup_dir}/${relative_path}"
    chmod --reference="${source_file}" "${candidate}"
    chown --reference="${source_file}" "${candidate}"
    mv -f -- "${candidate}" "${source_file}"
    log "已修复 Debian 11 失效软件源：${source_file}"
  done

  [[ -z "${backup_dir}" ]] || printf '原 APT 软件源备份：%s\n' "${backup_dir}"
}


apt_update_safe() {
  local update_log
  update_log="$(mktemp /tmp/vps-manager-apt-update.XXXXXX.log)"

  if apt-get update 2>&1 | tee "${update_log}"; then
    rm -f -- "${update_log}"
    return 0
  fi

  if ! grep -Eqi 'Unable to parse package file|package cache file is corrupted|Problem with MergeList|package lists or status file could not be parsed' "${update_log}"; then
    rm -f -- "${update_log}"
    return 1
  fi

  if dmesg 2>/dev/null | grep -Eqi 'EXT4-fs error|XFS.*corrupt|BTRFS.*error|I/O error|Buffer I/O error|bad block bitmap checksum'; then
    rm -f -- "${update_log}"
    die "检测到文件系统或块设备错误，APT 缓存损坏可能只是表象。请先离线执行 fsck/存储检查；脚本拒绝继续删除缓存。"
  fi

  warn "检测到可重建的 APT 索引/缓存损坏，将清理下载缓存后自动重试一次。"
  install -d -m 0755 /var/lib/apt/lists/partial
  find /var/lib/apt/lists -mindepth 1 -maxdepth 1 ! -name partial -exec rm -rf -- {} +
  find /var/lib/apt/lists/partial -mindepth 1 -delete
  rm -f -- /var/cache/apt/pkgcache.bin /var/cache/apt/srcpkgcache.bin
  rm -f -- "${update_log}"
  apt-get clean
  apt-get update
}


random_password() {
  openssl rand -base64 24 | tr -d '\n'
}

shadowsocks_password_for_method() {
  case "$1" in
    2022-blake3-aes-128-gcm) openssl rand -base64 16 | tr -d '\n';;
    2022-blake3-aes-256-gcm) openssl rand -base64 32 | tr -d '\n';;
    *) random_password;;
  esac
}


validate_port() {
  local value="$1"
  [[ "${value}" =~ ^[0-9]+$ ]] && (( value >= 1 && value <= 65535 ))
}


normalize_reality_target() {
  python3 - "$1" <<'PY'
import ipaddress
import re
import sys

value = sys.argv[1].strip()

def fail(message):
    raise SystemExit(message)

def valid_port(text):
    return text.isdigit() and 1 <= int(text) <= 65535

def valid_host(text):
    if not text or "/" in text:
        return False
    try:
        ascii_host = text.rstrip(".").encode("idna").decode("ascii")
    except UnicodeError:
        return False
    if not ascii_host or len(ascii_host) > 253:
        return False
    return all(re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?", label) for label in ascii_host.split("."))

if not value or any(ch.isspace() for ch in value) or "," in value or "://" in value:
    fail("Reality target 必须是域名或 IP，可选端口；不要填写 URL、空格或逗号列表")
if value.startswith(("@", "/")):
    print(value)
    raise SystemExit(0)
if value.isdigit():
    if not valid_port(value):
        fail("Reality target 端口必须在 1-65535 之间")
    print(value)
    raise SystemExit(0)
try:
    address = ipaddress.ip_address(value)
except ValueError:
    address = None
if address is not None:
    print(f"[{value}]:443" if address.version == 6 else f"{value}:443")
    raise SystemExit(0)
if value.startswith("["):
    match = re.fullmatch(r"\[([^]]+)\](?::([0-9]+))?", value)
    if not match:
        fail("IPv6 Reality target 格式无效")
    try:
        address = ipaddress.ip_address(match.group(1))
    except ValueError:
        fail("IPv6 Reality target 地址无效")
    if address.version != 6:
        fail("方括号只应用于 IPv6 地址")
    port = match.group(2) or "443"
    if not valid_port(port):
        fail("Reality target 端口必须在 1-65535 之间")
    print(f"[{match.group(1)}]:{port}")
    raise SystemExit(0)
if value.count(":") == 0:
    if not valid_host(value):
        fail("Reality target 域名格式无效")
    print(f"{value}:443")
    raise SystemExit(0)
if value.count(":") == 1:
    host, port = value.rsplit(":", 1)
    if not valid_host(host) or not valid_port(port):
        fail("Reality target 必须使用 域名或IP:端口，端口范围 1-65535")
    print(value)
    raise SystemExit(0)
fail("未加方括号的 IPv6 target 只能填写裸地址，脚本会自动补全 [IPv6]:443")
PY
}


port_is_listening() {
  local port="$1"
  ss -ltnH 2>/dev/null | awk -v suffix=":${port}" '$4 ~ suffix "$" {found=1} END {exit !found}'
}


wait_for_port_listening() {
  local port="$1"
  local timeout_seconds="${2:-10}"
  local attempt

  for ((attempt = 0; attempt < timeout_seconds; attempt++)); do
    port_is_listening "${port}" && return 0
    sleep 1
  done
  port_is_listening "${port}"
}


detect_public_address() {
  local address

  address="$(curl -4 -fsS --max-time 6 https://api.ipify.org 2>/dev/null || true)"
  if [[ -z "${address}" ]]; then
    address="$(curl -4 -fsS --max-time 6 https://ifconfig.me 2>/dev/null || true)"
  fi
  if [[ -z "${address}" ]]; then
    address="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi
  printf '%s' "${address:-127.0.0.1}"
}


show_bbr_status() {
  local available
  local current
  local qdisc

  available="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo unknown)"
  current="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
  qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || echo unknown)"
  printf '可用算法: %s\n当前算法: %s\n默认队列: %s\n' "${available}" "${current}" "${qdisc}"
}


enable_bbr() {
  local config="/etc/sysctl.d/99-vps-manager-bbr.conf"
  local backup=""

  require_root
  check_supported_os
  log "检查 BBR"
  show_bbr_status

  if [[ "${DEMO_MODE}" == "1" ]]; then
    printf '\n[演示] 实际运行时会加载 tcp_bbr，并写入：%s\n' "${config}"
    return 0
  fi

  if is_alpine; then
    apk add --no-cache kmod procps >/dev/null
  else
    command -v modprobe >/dev/null 2>&1 || apt_update_safe
    command -v modprobe >/dev/null 2>&1 || apt-get install -y kmod
  fi
  if ! grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
    modprobe tcp_bbr >/dev/null 2>&1 || true
  fi
  if ! grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
    warn "当前内核没有提供 BBR。容器/NAT VPS 无法自行安装宿主机内核模块，需要服务商在宿主机加载 tcp_bbr。"
    printf '未修改拥塞控制配置；当前仍为：%s\n' "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
    return 0
  fi

  if [[ -e "${config}" ]]; then
    backup="$(backup_file "${config}" "bbr")"
  fi

  ensure_work_dir
  : > "${WORK_DIR}/bbr.conf"
  if [[ -e /proc/sys/net/core/default_qdisc ]]; then
    printf '%s\n' 'net.core.default_qdisc=fq' >> "${WORK_DIR}/bbr.conf"
  fi
  printf '%s\n' 'net.ipv4.tcp_congestion_control=bbr' >> "${WORK_DIR}/bbr.conf"
  install -o root -g root -m 644 "${WORK_DIR}/bbr.conf" "${config}"
  sysctl --system >/dev/null

  if [[ "$(sysctl -n net.ipv4.tcp_congestion_control)" != "bbr" ]]; then
    die "BBR 配置未生效。"
  fi

  log "BBR 已启用"
  show_bbr_status
  [[ -n "${backup}" ]] && printf '原配置备份: %s\n' "${backup}"
}


default_ssh_admin_user() {
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]] \
    && id "${SUDO_USER}" >/dev/null 2>&1; then
    printf '%s' "${SUDO_USER}"
  else
    id -un
  fi
}


random_high_port() {
  local candidate

  while true; do
    candidate="$(shuf -i 20000-60000 -n 1)"
    if ! port_is_listening "${candidate}"; then
      printf '%s' "${candidate}"
      return 0
    fi
  done
}


ssh_service_name() {
  if systemctl cat ssh.service >/dev/null 2>&1; then
    printf 'ssh.service'
  elif systemctl cat sshd.service >/dev/null 2>&1; then
    printf 'sshd.service'
  else
    return 1
  fi
}



switch_ssh_socket_to_service() {
  local ssh_service="$1"

  SSH_SOCKET_TRANSITIONED=0
  SSH_SOCKET_WAS_ENABLED=0
  SSH_SOCKET_WAS_ACTIVE=0
  systemctl cat ssh.socket >/dev/null 2>&1 || return 0
  systemctl is-active --quiet ssh.socket || return 0

  SSH_SOCKET_WAS_ACTIVE=1
  if systemctl is-enabled --quiet ssh.socket; then
    SSH_SOCKET_WAS_ENABLED=1
  fi
  SSH_SOCKET_TRANSITIONED=1
  log "Detected ssh.socket with a fixed listener; switching SSH to ssh.service/sshd_config"

  systemctl disable ssh.socket >/dev/null \
    && systemctl stop "${ssh_service}" \
    && systemctl stop ssh.socket \
    && systemctl daemon-reload \
    && systemctl start "${ssh_service}"
}


restore_ssh_socket_state() {
  local ssh_service="$1"
  [[ "${SSH_SOCKET_TRANSITIONED}" == "1" ]] || return 0

  systemctl stop "${ssh_service}" >/dev/null 2>&1 || true
  if [[ "${SSH_SOCKET_WAS_ENABLED}" == "1" ]]; then
    systemctl enable ssh.socket >/dev/null 2>&1 || true
  else
    systemctl disable ssh.socket >/dev/null 2>&1 || true
  fi
  systemctl daemon-reload >/dev/null 2>&1 || true
  if [[ "${SSH_SOCKET_WAS_ACTIVE}" == "1" ]]; then
    systemctl start ssh.socket >/dev/null 2>&1 || return 1
  fi
  systemctl start "${ssh_service}" >/dev/null 2>&1
}


restore_ssh_port_configs() {
  local backup_dir="$1"
  local backup_name target
  [[ -n "${backup_dir}" && -r "${backup_dir}/manifest" ]] || return 0
  while IFS=$'\t' read -r backup_name target; do
    [[ -n "${backup_name}" && "${target}" == /* ]] || continue
    cp -a -- "${backup_dir}/${backup_name}" "${target}"
  done < "${backup_dir}/manifest"
}

backup_and_disable_ssh_ports() {
  local backup_dir path backup_name candidate
  local index=0
  local -a config_files=("${SSHD_MAIN_CONFIG}")
  while IFS= read -r -d '' path; do
    config_files+=("${path}")
  done < <(find "${SSHD_DROPIN_DIR}" -maxdepth 1 -type f -name '*.conf' -print0 2>/dev/null)
  install -d -o root -g root -m 700 "${BACKUP_ROOT}"
  backup_dir="$(mktemp -d "${BACKUP_ROOT}/sshd-port-sources-$(date -u '+%Y%m%dT%H%M%SZ').XXXXXX")"
  chmod 700 "${backup_dir}"
  : > "${backup_dir}/manifest"
  for path in "${config_files[@]}"; do
    [[ -f "${path}" && "${path}" != "${SSHD_MANAGED_CONFIG}" ]] || continue
    grep -Eqi '^[[:space:]]*port[[:space:]]+[0-9]+([[:space:]]*(#.*)?)?$' "${path}" || continue
    if [[ -L "${path}" || "${path}" == *$'\n'* || "${path}" == *$'\t'* ]]; then
      warn "SSH 端口来源文件不安全，未修改：${path}"
      restore_ssh_port_configs "${backup_dir}"
      return 1
    fi
    index=$((index + 1))
    backup_name="$(printf '%04d.conf' "${index}")"
    if ! cp -a -- "${path}" "${backup_dir}/${backup_name}"; then
      restore_ssh_port_configs "${backup_dir}"
      return 1
    fi
    printf '%s\t%s\n' "${backup_name}" "${path}" >> "${backup_dir}/manifest"
    candidate="${WORK_DIR}/sshd-port-source-${index}.new"
    if ! awk '
      /^[[:space:]]*[Pp][Oo][Rr][Tt][[:space:]]+[0-9]+([[:space:]]*(#.*)?)?$/ {
        print "# VPS Manager replaced old SSH port: " $0
        next
      }
      { print }
    ' "${path}" > "${candidate}"; then
      restore_ssh_port_configs "${backup_dir}"
      return 1
    fi
    if ! chmod --reference="${path}" "${candidate}" \
      || ! chown --reference="${path}" "${candidate}"; then
      restore_ssh_port_configs "${backup_dir}"
      return 1
    fi
    if ! mv -f -- "${candidate}" "${path}"; then
      restore_ssh_port_configs "${backup_dir}"
      return 1
    fi
  done
  if (( index == 0 )); then
    rm -f -- "${backup_dir}/manifest"
    rmdir -- "${backup_dir}"
    printf ''
  else
    printf '%s' "${backup_dir}"
  fi
}

rollback_ssh_hardening() {
  local config_existed="$1"
  local config_before="$2"
  local authorized_existed="$3"
  local authorized_before="$4"
  local authorized_keys="$5"
  local admin_user="$6"
  local admin_group="$7"
  local ssh_service="$8"
  local port_config_backup_dir="${9:-}"

  restore_ssh_port_configs "${port_config_backup_dir}"

  if [[ "${config_existed}" == "1" ]]; then
    install -o root -g root -m 644 "${config_before}" "${SSHD_MANAGED_CONFIG}"
  else
    rm -f -- "${SSHD_MANAGED_CONFIG}"
  fi

  if [[ "${authorized_existed}" == "1" ]]; then
    install -o "${admin_user}" -g "${admin_group}" -m 600 \
      "${authorized_before}" "${authorized_keys}"
  else
    rm -f -- "${authorized_keys}"
  fi

  if [[ "${SSH_SOCKET_TRANSITIONED}" == "1" ]]; then
    restore_ssh_socket_state "${ssh_service}" || warn "Failed to restore ssh.socket; keep this session open and check immediately."
  else
  if /usr/sbin/sshd -t; then
    systemctl reload "${ssh_service}" \
      || warn "SSH 配置已恢复，但 reload 失败；请保持当前会话并手动检查。"
  else
    warn "SSH 配置恢复后的语法检查失败；请保持当前会话并立即检查。"
  fi
  fi
}


configure_ssh_hardening() {
  local admin_user
  local admin_home
  local admin_group
  local default_port
  local ssh_port
  local public_key
  local key_check
  local key_type
  local key_blob
  local use_existing_authorized_keys=0
  local private_key_confirmation
  local authorized_keys
  local ssh_service
  local public_address
  local config_existed=0
  local authorized_existed=0
  local config_before
  local authorized_before
  local config_backup_dir=""
  local authorized_backup_dir=""
  local effective
  local effective_ports
  local effective_password
  local effective_kbd
  local effective_pubkey
  local effective_methods
  local host_name
  local port_config_backup_dir=""

  SSH_SOCKET_TRANSITIONED=0
  SSH_SOCKET_WAS_ENABLED=0
  SSH_SOCKET_WAS_ACTIVE=0

  require_root
  check_supported_os

  admin_user="$(default_ssh_admin_user)"
  id "${admin_user}" >/dev/null 2>&1 \
    || die "无法识别启动脚本的用户：${admin_user}"
  printf 'SSH 管理用户：%s（自动取当前登录用户）\n' "${admin_user}"

  admin_home="$(getent passwd "${admin_user}" | cut -d: -f6)"
  admin_group="$(id -gn "${admin_user}")"
  [[ "${admin_home}" == /* && "${admin_home}" != "/" ]] \
    || die "用户主目录不安全或无效：${admin_home}"
  authorized_keys="${admin_home}/.ssh/authorized_keys"

  default_port="$(random_high_port)"
  while true; do
    ssh_port="$(prompt_default "新的 SSH 高位端口（10000-65535）" "${default_port}")"
    if ! validate_port "${ssh_port}" || (( ssh_port < 10000 )); then
      warn "SSH 高位端口必须在 10000-65535 之间。"
      continue
    fi
    if port_is_listening "${ssh_port}"; then
      warn "端口 ${ssh_port} 已被占用，请换一个端口。"
      continue
    fi
    break
  done

  if [[ "${DEMO_MODE}" == "1" ]]; then
    read -r -p "粘贴 SSH 公钥（已有有效 authorized_keys 时可直接回车）: " public_key || true
    log "[预览] SSH 密钥登录配置（不会修改系统）"
    if [[ -n "${public_key}" ]]; then
      printf '将把公钥追加到：%s\n' "${authorized_keys}"
      printf '公钥内容：%s\n' "${public_key}"
    else
      printf '将沿用 %s 中已有的有效公钥。\n' "${authorized_keys}"
    fi
    printf '将停用现有 SSH 配置中的所有显式 Port，并仅保留新端口。\n'
    printf '将写入：%s\n' "${SSHD_MANAGED_CONFIG}"
    cat <<EOF
Port ${ssh_port}
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
AuthenticationMethods publickey
PermitEmptyPasswords no
AuthorizedKeysFile .ssh/authorized_keys
EOF
    printf '\n实际执行时，reload 后必须在第二个终端验证新端口；失败会恢复原配置。\n'
    return 0
  fi

  if [[ ! -x /usr/sbin/sshd ]]; then
    apt_update_safe
    apt-get install -y openssh-server
  fi
  command -v ssh-keygen >/dev/null 2>&1 || die "未找到 ssh-keygen。"
  ssh_service="$(ssh_service_name)" || die "未找到 SSH systemd 服务。"

  grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config.d/\*\.conf' \
    "${SSHD_MAIN_CONFIG}" \
    || die "${SSHD_MAIN_CONFIG} 未包含 sshd_config.d，已停止以避免锁死。"

  ensure_work_dir
  key_check="${WORK_DIR}/key-check.pub"
  [[ ! -L "${admin_home}/.ssh" && ! -L "${authorized_keys}" ]] \
    || die "检测到 .ssh 或 authorized_keys 是符号链接，已停止以避免写错目标。"
  while true; do
    if [[ -s "${authorized_keys}" ]] \
      && ssh-keygen -l -f "${authorized_keys}" >/dev/null 2>&1; then
      read -r -p "粘贴 SSH 公钥（已有有效 authorized_keys，直接回车可沿用）: " public_key
    else
      read -r -p "粘贴 SSH 公钥（以 ssh-ed25519、ecdsa 或 ssh-rsa 开头）: " public_key
    fi
    public_key="${public_key%$'\r'}"

    if [[ -z "${public_key}" ]]; then
      if [[ -s "${authorized_keys}" ]] \
        && ssh-keygen -l -f "${authorized_keys}" >/dev/null 2>&1; then
        use_existing_authorized_keys=1
        key_blob=""
        printf '将沿用 %s 中已有的有效公钥。\n' "${authorized_keys}"
        break
      fi
      warn "当前 authorized_keys 中没有可验证的公钥，必须粘贴一整行 SSH 公钥。"
      continue
    fi

    printf '%s\n' "${public_key}" > "${key_check}"
    chmod 600 "${key_check}"
    key_type="$(awk '{print $1}' "${key_check}")"
    case "${key_type}" in
      ssh-ed25519|ssh-rsa|ecdsa-sha2-*|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-*@openssh.com) ;;
      *)
        warn "公钥类型或格式不正确。请粘贴 .pub 文件中的完整一行。"
        continue
        ;;
    esac
    if ssh-keygen -l -f "${key_check}" >/dev/null 2>&1; then
      key_blob="$(awk '{print $2}' "${key_check}")"
      break
    fi
    warn "ssh-keygen 无法验证该公钥，请重新粘贴。"
  done
  rm -f -- "${key_check}"

  warn "不要关闭当前 SSH 窗口。修改后必须用第二个终端测试，失败时脚本会回滚。"
  printf '请先在云厂商安全组中放行：%s/tcp\n' "${ssh_port}"
  prompt_yes_no "确认云安全组已经放行 ${ssh_port}/tcp" "0" \
    || { printf '已取消 SSH 加固，未修改配置。\n'; return 0; }
  if [[ "${use_existing_authorized_keys}" == "1" ]]; then
    private_key_confirmation="确认你持有 authorized_keys 中至少一把公钥对应的私钥"
  else
    private_key_confirmation="确认你持有该公钥对应的私钥"
  fi
  prompt_yes_no "${private_key_confirmation}" "0" \
    || { printf '已取消 SSH 加固，未修改配置。\n'; return 0; }

  if command -v ufw >/dev/null 2>&1 \
    && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow "${ssh_port}/tcp"
  fi
  if command -v firewall-cmd >/dev/null 2>&1 \
    && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="${ssh_port}/tcp"
    firewall-cmd --reload
  fi

  config_before="${WORK_DIR}/sshd-managed.before"
  authorized_before="${WORK_DIR}/authorized_keys.before"

  if [[ -e "${SSHD_MANAGED_CONFIG}" ]]; then
    config_existed=1
    cp -a -- "${SSHD_MANAGED_CONFIG}" "${config_before}"
    config_backup_dir="$(backup_file "${SSHD_MANAGED_CONFIG}" "sshd-config")"
  fi

  install -d -o "${admin_user}" -g "${admin_group}" -m 700 \
    "${admin_home}/.ssh"
  if [[ -e "${authorized_keys}" ]]; then
    authorized_existed=1
    cp -a -- "${authorized_keys}" "${authorized_before}"
    authorized_backup_dir="$(backup_file "${authorized_keys}" "authorized-keys")"
    chown "${admin_user}:${admin_group}" "${authorized_keys}"
    chmod 600 "${authorized_keys}"
  else
    install -o "${admin_user}" -g "${admin_group}" -m 600 \
      /dev/null "${authorized_keys}"
  fi

  cp -a -- "${authorized_keys}" "${WORK_DIR}/authorized_keys.new"
  if [[ "${use_existing_authorized_keys}" != "1" ]] \
    && ! awk -v blob="${key_blob}" '$2 == blob {found=1} END {exit !found}' \
      "${WORK_DIR}/authorized_keys.new"; then
    printf '%s\n' "${public_key}" >> "${WORK_DIR}/authorized_keys.new"
  fi
  install -o "${admin_user}" -g "${admin_group}" -m 600 \
    "${WORK_DIR}/authorized_keys.new" "${authorized_keys}"

  install -d -o root -g root -m 755 "${SSHD_DROPIN_DIR}"
  if ! port_config_backup_dir="$(backup_and_disable_ssh_ports)"; then
    rollback_ssh_hardening \
      "${config_existed}" "${config_before}" \
      "${authorized_existed}" "${authorized_before}" "${authorized_keys}" \
      "${admin_user}" "${admin_group}" "${ssh_service}" "${port_config_backup_dir}"
    die "无法安全替换现有 SSH Port 配置，已恢复。"
  fi
  cat > "${WORK_DIR}/sshd-hardening.conf" <<EOF
Port ${ssh_port}
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
AuthenticationMethods publickey
PermitEmptyPasswords no
AuthorizedKeysFile .ssh/authorized_keys
EOF
  install -o root -g root -m 644 \
    "${WORK_DIR}/sshd-hardening.conf" "${SSHD_MANAGED_CONFIG}"

  if ! /usr/sbin/sshd -t; then
    rollback_ssh_hardening \
      "${config_existed}" "${config_before}" \
      "${authorized_existed}" "${authorized_before}" "${authorized_keys}" \
      "${admin_user}" "${admin_group}" "${ssh_service}" "${port_config_backup_dir}"
    die "新 SSH 配置语法检查失败，已恢复。"
  fi

  host_name="$(hostname -f 2>/dev/null || hostname)"
  if ! effective="$(/usr/sbin/sshd -T -C \
    "user=${admin_user},host=${host_name},addr=127.0.0.1,laddr=127.0.0.1,lport=${ssh_port}")"; then
    rollback_ssh_hardening \
      "${config_existed}" "${config_before}" \
      "${authorized_existed}" "${authorized_before}" "${authorized_keys}" \
      "${admin_user}" "${admin_group}" "${ssh_service}" "${port_config_backup_dir}"
    die "无法读取 SSH 生效配置，已恢复。"
  fi
  effective_ports="$(printf '%s\n' "${effective}" \
    | awk '$1 == "port" {print $2}' | paste -sd, -)"
  effective_password="$(printf '%s\n' "${effective}" \
    | awk '$1 == "passwordauthentication" {print $2; exit}')"
  effective_kbd="$(printf '%s\n' "${effective}" \
    | awk '$1 == "kbdinteractiveauthentication" {print $2; exit}')"
  effective_pubkey="$(printf '%s\n' "${effective}" \
    | awk '$1 == "pubkeyauthentication" {print $2; exit}')"
  effective_methods="$(printf '%s\n' "${effective}" \
    | awk '$1 == "authenticationmethods" {print $2; exit}')"

  if [[ "${effective_ports}" != "${ssh_port}" \
    || "${effective_password}" != "no" \
    || "${effective_kbd}" != "no" \
    || "${effective_pubkey}" != "yes" \
    || "${effective_methods}" != "publickey" ]]; then
    rollback_ssh_hardening \
      "${config_existed}" "${config_before}" \
      "${authorized_existed}" "${authorized_before}" "${authorized_keys}" \
      "${admin_user}" "${admin_group}" "${ssh_service}" "${port_config_backup_dir}"
    die "SSH 生效配置与预期不一致，已恢复。有效端口：${effective_ports:-未知}"
  fi

  if ! switch_ssh_socket_to_service "${ssh_service}"; then
    rollback_ssh_hardening \
      "${config_existed}" "${config_before}" \
      "${authorized_existed}" "${authorized_before}" "${authorized_keys}" \
      "${admin_user}" "${admin_group}" "${ssh_service}" "${port_config_backup_dir}"
    die "Failed to switch SSH listener mode; previous configuration was restored."
  fi

  if [[ "${SSH_SOCKET_TRANSITIONED}" != "1" ]]; then

  if ! systemctl reload "${ssh_service}"; then
    rollback_ssh_hardening \
      "${config_existed}" "${config_before}" \
      "${authorized_existed}" "${authorized_before}" "${authorized_keys}" \
      "${admin_user}" "${admin_group}" "${ssh_service}" "${port_config_backup_dir}"
    die "SSH reload 失败，已恢复。"
  fi
  fi

  if ! wait_for_port_listening "${ssh_port}" 10; then
    rollback_ssh_hardening \
      "${config_existed}" "${config_before}" \
      "${authorized_existed}" "${authorized_before}" "${authorized_keys}" \
      "${admin_user}" "${admin_group}" "${ssh_service}" "${port_config_backup_dir}"
    die "新 SSH 端口未监听，已恢复原配置。"
  fi

  public_address="$(detect_public_address)"
  printf '\n请保持当前窗口，在第二个终端执行：\n'
  printf 'ssh -p %s %s@%s\n\n' \
    "${ssh_port}" "${admin_user}" "${public_address}"
  if ! prompt_yes_no "是否已经使用对应私钥成功登录新端口" "0"; then
    rollback_ssh_hardening \
      "${config_existed}" "${config_before}" \
      "${authorized_existed}" "${authorized_before}" "${authorized_keys}" \
      "${admin_user}" "${admin_group}" "${ssh_service}" "${port_config_backup_dir}"
    warn "验证未通过，已恢复原 SSH 端口和认证配置。"
    return 0
  fi

  log "SSH 加固完成"
  printf '管理用户：%s\n新端口：%s\n' "${admin_user}" "${ssh_port}"
  printf '密码登录：已关闭\n认证方式：仅公钥\n'
  printf '请同步更新 Termark 中该服务器的端口和登录凭据。\n'
  [[ -n "${config_backup_dir}" ]] \
    && printf '原 SSH 配置备份：%s\n' "${config_backup_dir}"
  [[ -n "${authorized_backup_dir}" ]] \
    && printf '原 authorized_keys 备份：%s\n' "${authorized_backup_dir}"
  [[ -n "${port_config_backup_dir}" ]] \
    && printf '原 SSH Port 来源文件备份：%s\n' "${port_config_backup_dir}"
}


install_base_tools() {
  require_root
  check_supported_os

  if [[ "${DEMO_MODE}" == "1" ]]; then
    log "[预览] 初始化基础工具"
    printf '将安装：ca-certificates curl wget vim unzip python3 python3-yaml openssl iproute2 openssh-client\n'
    return 0
  fi
  if is_alpine; then
    log "安装 Alpine 基础工具"
    apk add --no-cache bash ca-certificates curl wget vim unzip python3 py3-yaml openssl iproute2 openssh-client procps
    return 0
  fi
  repair_debian_bullseye_apt_sources

  log "安装基础工具"
  export DEBIAN_FRONTEND=noninteractive
  apt_update_safe
  apt-get install -y --no-install-recommends \
    ca-certificates curl wget vim unzip python3 python3-yaml openssl iproute2 openssh-client
}


install_or_upgrade_xray() {
  local installer archive stage alpine_arch archive_name checksum_file expected_sha256

  require_root
  check_supported_os

  if [[ "${DEMO_MODE}" == "1" ]]; then
    log "[预览] 安装或升级 Xray"
    printf '将使用 XTLS 官方安装器：\n%s\n' "${XRAY_INSTALL_URL}"
    printf '配置路径：%s\n' "${XRAY_CONFIG}"
    return 0
  fi

  if is_alpine; then
    log "安装 Alpine Xray 依赖"
    apk add --no-cache bash ca-certificates curl unzip python3 py3-yaml openssl shadow su-exec
    alpine_arch="$(apk --print-arch)"
    case "${alpine_arch}" in
      x86_64) archive_name="Xray-linux-64.zip" ;;
      aarch64) archive_name="Xray-linux-arm64-v8a.zip" ;;
      *) die "Alpine Xray 自动安装仅支持 x86_64 和 aarch64；当前为 ${alpine_arch}." ;;
    esac
    ensure_work_dir
    archive="${WORK_DIR}/xray.zip"
    checksum_file="${WORK_DIR}/xray.zip.dgst"
    stage="${WORK_DIR}/xray"
    mkdir -p "${stage}"
    curl -fL --retry 3 --connect-timeout 10 -o "${archive}" \
      "https://github.com/XTLS/Xray-core/releases/latest/download/${archive_name}"
    curl -fL --retry 3 --connect-timeout 10 -o "${checksum_file}" \
      "https://github.com/XTLS/Xray-core/releases/latest/download/${archive_name}.dgst"
    expected_sha256="$(awk -F'= ' '/^SHA2-256= / {print $2; exit}' "${checksum_file}")"
    [[ "${expected_sha256}" =~ ^[0-9a-f]{64}$ ]] || die "无法读取 Xray 官方 SHA-256。"
    printf '%s  %s\n' "${expected_sha256}" "${archive}" | sha256sum -c -
    unzip -tq "${archive}" >/dev/null || die "Xray 官方压缩包校验失败。"
    unzip -q "${archive}" -d "${stage}"
    [[ -x "${stage}/xray" ]] || die "Xray 压缩包中缺少可执行文件。"
    "${stage}/xray" version >/dev/null \
      || die "Xray 候选文件无法在当前 ${alpine_arch} 系统执行，未替换现有文件。"
    getent group xray >/dev/null 2>&1 || addgroup -S xray
    id xray >/dev/null 2>&1 || adduser -S -D -H -h /var/empty -s /sbin/nologin -G xray xray
    install -d -m 755 /usr/local/bin /usr/local/share/xray /usr/local/etc/xray
    install -m 755 "${stage}/xray" "${XRAY_BIN}"
    [[ ! -f "${stage}/geoip.dat" ]] || install -m 644 "${stage}/geoip.dat" /usr/local/share/xray/geoip.dat
    [[ ! -f "${stage}/geosite.dat" ]] || install -m 644 "${stage}/geosite.dat" /usr/local/share/xray/geosite.dat
    cat > /etc/init.d/xray <<'EOF'
#!/sbin/openrc-run
description="Xray Service"
command="/usr/local/bin/xray"
command_args="run -config /usr/local/etc/xray/config.json"
command_user="xray:xray"
supervisor="supervise-daemon"
respawn_delay=5
respawn_max=0
depend() { need net; after firewall; }
EOF
    chmod 755 /etc/init.d/xray
    log "Alpine Xray ${alpine_arch} 已安装"
    "${XRAY_BIN}" version | head -n 3
    return 0
  fi

  log "安装 Xray 所需依赖"
  export DEBIAN_FRONTEND=noninteractive
  apt_update_safe
  apt-get install -y --no-install-recommends ca-certificates curl unzip python3 openssl

  ensure_work_dir
  installer="${WORK_DIR}/install-xray.sh"
  curl -fL --retry 3 --connect-timeout 10 -o "${installer}" "${XRAY_INSTALL_URL}"
  chmod 700 "${installer}"
  bash -n "${installer}"

  log "使用 XTLS 官方安装器安装或升级 Xray"
  bash "${installer}" install

  [[ -x "${XRAY_BIN}" ]] || die "Xray 安装完成后未找到 ${XRAY_BIN}。"
  "${XRAY_BIN}" version | head -n 3
}


collect_proxy_outbounds() {
  local index=1
  local name
  local link

  CFG_PROXY_NAMES=()
  CFG_PROXY_LINKS=()
  printf '\n出口代理支持 socks5://、http://、https:// 和 ss://。\n'
  printf 'SOCKS5/HTTP/HTTPS 标准格式：协议://用户名:密码@IP或域名:端口\n'
  printf '示例：socks5://user:pass@1.2.3.4:1080\n'
  printf '兼容旧格式：协议:IP或域名:端口@用户名:密码\n'
  printf 'Shadowsocks 标准格式：ss://BASE64(加密方式:密码)@IP或域名:端口\n'
  printf 'SS 旧格式：ss:IP或域名:端口@加密方式:密码\n'
  printf 'SOCKS5 会在生成配置时自动检测远程域名解析能力；异常时启用 IPv4 兜底。\n'
  printf '直接回车跳过，即只生成本机原生出口。\n'

  while prompt_yes_no "是否添加第 ${index} 个 ISP 出口代理" "0"; do
    name="$(prompt_default "出口名称" "isp-${index}")"
    link="$(prompt_secret "粘贴代理链接（输入不会显示）")"
    [[ -n "${link}" ]] || {
      warn "代理链接不能为空，本条未添加。"
      continue
    }
    CFG_PROXY_NAMES+=("${name}")
    CFG_PROXY_LINKS+=("${link}")
    printf '已接收出口：%s\n' "${name}"
    index=$((index + 1))
  done
}


collect_optional_inbounds() {
  local default_password

  CFG_ENABLE_SOCKS=0
  CFG_ENABLE_SS=0

  if prompt_yes_no "是否开启 SOCKS5 入站端口" "0"; then
    CFG_ENABLE_SOCKS=1
    CFG_SOCKS_LISTEN="$(prompt_default "SOCKS5 监听地址（127.0.0.1 仅本机）" "127.0.0.1")"
    while true; do
      CFG_SOCKS_PORT="$(prompt_default "SOCKS5 端口" "21625")"
      validate_port "${CFG_SOCKS_PORT}" && break
      warn "端口必须在 1-65535 之间。"
    done
    CFG_SOCKS_USER="$(prompt_default "SOCKS5 用户名" "xray-socks")"
    default_password="$(random_password)"
    CFG_SOCKS_PASS="$(prompt_default "SOCKS5 密码" "${default_password}")"
    if [[ "${CFG_SOCKS_LISTEN}" == "0.0.0.0" ]]; then
      warn "SOCKS5 本身不加密，请只允许可信 IP 访问该端口。"
    fi
  fi

  if prompt_yes_no "是否开启 Shadowsocks 入站端口" "0"; then
    CFG_ENABLE_SS=1
    CFG_SS_LISTEN="$(prompt_default "Shadowsocks 监听地址" "0.0.0.0")"
    while true; do
      CFG_SS_PORT="$(prompt_default "Shadowsocks 端口" "21626")"
      validate_port "${CFG_SS_PORT}" && break
      warn "端口必须在 1-65535 之间。"
    done
    CFG_SS_METHOD="$(prompt_default "Shadowsocks 加密方式" "2022-blake3-aes-128-gcm")"
    default_password="$(shadowsocks_password_for_method "${CFG_SS_METHOD}")"
    CFG_SS_PASS="$(prompt_secret "Shadowsocks 密码/PSK（留空自动生成）")"
    [[ -n "${CFG_SS_PASS}" ]] || CFG_SS_PASS="${default_password}"
  fi
}


collect_xray_configuration() {
  local default_name

  default_name="$(hostname)"
  CFG_NODE_NAME="$(prompt_default "节点名称（用于生成 AWS YAML）" "${default_name}")"
  CFG_PUBLIC_ADDRESS="$(detect_public_address)"
  printf '自动检测到节点地址：%s（仅用于生成 AWS YAML）\n' "${CFG_PUBLIC_ADDRESS}"

  while true; do
    CFG_REALITY_PORT="$(prompt_default "VLESS-Reality 端口" "58403")"
    validate_port "${CFG_REALITY_PORT}" && break
    warn "端口必须在 1-65535 之间。"
  done

  local raw_reality_target normalized_reality_target
  raw_reality_target="$(prompt_default "Reality target（裸域名/IP 自动补全 :443）" "www.example.com:443")"
  normalized_reality_target="$(normalize_reality_target "${raw_reality_target}")" \
    || die "Reality target 格式不正确。"
  if [[ "${normalized_reality_target}" != "${raw_reality_target}" ]]; then
    printf '已自动补全 Reality target：%s\n' "${normalized_reality_target}"
  fi
  CFG_REALITY_DEST="${normalized_reality_target}"
  CFG_SERVER_NAMES="$(prompt_default "Reality serverNames（逗号分隔）" "www.example.com,example.com")"
  [[ -n "${CFG_SERVER_NAMES}" ]] || die "Reality serverNames 不能为空。"

  if port_is_listening "${CFG_REALITY_PORT}"; then
    warn "端口 ${CFG_REALITY_PORT} 当前已有程序监听。"
    prompt_yes_no "仍然继续生成配置" "0" || die "已取消配置。"
  fi

  collect_proxy_outbounds
  collect_optional_inbounds

  local ports=("${CFG_REALITY_PORT}")
  [[ "${CFG_ENABLE_SOCKS}" == "1" ]] && ports+=("${CFG_SOCKS_PORT}")
  [[ "${CFG_ENABLE_SS}" == "1" ]] && ports+=("${CFG_SS_PORT}")
  if [[ "$(printf '%s\n' "${ports[@]}" | sort -u | wc -l)" -ne "${#ports[@]}" ]]; then
    die "VLESS、SOCKS5 和 Shadowsocks 端口不能重复。"
  fi
}


write_proxy_input_file() {
  local destination="$1"
  local index
  local encoded_name
  local encoded_link

  : > "${destination}"
  chmod 600 "${destination}"
  for ((index = 0; index < ${#CFG_PROXY_NAMES[@]}; index++)); do
    encoded_name="$(printf '%s' "${CFG_PROXY_NAMES[index]}" | base64 | tr -d '\n')"
    encoded_link="$(printf '%s' "${CFG_PROXY_LINKS[index]}" | base64 | tr -d '\n')"
    printf '%s\t%s\n' "${encoded_name}" "${encoded_link}" >> "${destination}"
  done
}


generate_xray_files_once() {
  local private_key="$1"
  local public_key="$2"
  local short_id="$3"
  local proxy_input="$4"
  local generated_config="$5"
  local generated_state="$6"
  local generated_info="$7"
  local generated_yaml="$8"
  local pending_model="${9:-}"
  local allow_failed_socks="${10:-0}"
  local probe_failure_marker="${11:-}"

  CFG_NODE_NAME="${CFG_NODE_NAME}" \
  CFG_PUBLIC_ADDRESS="${CFG_PUBLIC_ADDRESS}" \
  CFG_REALITY_PORT="${CFG_REALITY_PORT}" \
  CFG_REALITY_DEST="${CFG_REALITY_DEST}" \
  CFG_SERVER_NAMES="${CFG_SERVER_NAMES}" \
  CFG_PRIVATE_KEY="${private_key}" \
  CFG_PUBLIC_KEY="${public_key}" \
  CFG_SHORT_ID="${short_id}" \
  CFG_ENABLE_SOCKS="${CFG_ENABLE_SOCKS}" \
  CFG_SOCKS_LISTEN="${CFG_SOCKS_LISTEN}" \
  CFG_SOCKS_PORT="${CFG_SOCKS_PORT}" \
  CFG_SOCKS_USER="${CFG_SOCKS_USER}" \
  CFG_SOCKS_PASS="${CFG_SOCKS_PASS}" \
  CFG_ENABLE_SS="${CFG_ENABLE_SS}" \
  CFG_SS_LISTEN="${CFG_SS_LISTEN}" \
  CFG_SS_PORT="${CFG_SS_PORT}" \
  CFG_SS_METHOD="${CFG_SS_METHOD}" \
  CFG_SS_PASS="${CFG_SS_PASS}" \
  CFG_PENDING_MODEL="${pending_model}" \
  python3 - "${proxy_input}" "${generated_config}" "${generated_state}" "${generated_info}" "${generated_yaml}" "${allow_failed_socks}" "${probe_failure_marker}" <<'PY'
from __future__ import annotations

import base64
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import unquote, urlsplit
import uuid


proxy_input = Path(sys.argv[1])
config_path = Path(sys.argv[2])
allow_failed_socks = sys.argv[6] == "1"
probe_failure_marker = sys.argv[7]
state_path = Path(sys.argv[3])
info_path = Path(sys.argv[4])
yaml_path = Path(sys.argv[5])


def env(name: str, default: str = "") -> str:
    return os.environ.get(name, default)


SOCKS_PROBE_TARGETS = [
    ("IPLark", "https://iplark.com/"),
    ("Cloudflare", "https://cp.cloudflare.com/generate_204"),
    ("Google", "https://www.gstatic.com/generate_204"),
]


def decode_urlsafe(value: str) -> str:
    value += "=" * (-len(value) % 4)
    return base64.urlsafe_b64decode(value.encode()).decode()


def parse_host_port(server: str) -> tuple[str, int]:
    parsed = urlsplit("dummy://" + server)
    if not parsed.hostname or parsed.port is None:
        raise ValueError("缺少代理地址或端口")
    if not (1 <= parsed.port <= 65535):
        raise ValueError("代理端口超出范围")
    return parsed.hostname, parsed.port


def parse_shadowsocks(link: str) -> dict:
    payload = link.split("://", 1)[1]
    payload = payload.split("#", 1)[0].split("?", 1)[0]

    if "@" not in payload:
        try:
            payload = decode_urlsafe(payload)
        except Exception as error:
            raise ValueError("无法解析 Shadowsocks Base64 链接") from error

    if "@" not in payload:
        raise ValueError("Shadowsocks 链接缺少服务器部分")

    userinfo, server = payload.rsplit("@", 1)
    if ":" not in userinfo:
        try:
            userinfo = decode_urlsafe(userinfo)
        except Exception as error:
            raise ValueError("无法解析 Shadowsocks 用户信息") from error

    if ":" not in userinfo:
        raise ValueError("Shadowsocks 链接缺少加密方式或密码")
    method, password = userinfo.split(":", 1)
    method = unquote(method)
    password = unquote(password)
    host, port = parse_host_port(server)
    if not method or not password:
        raise ValueError("Shadowsocks 加密方式和密码不能为空")
    return {
        "scheme": "ss",
        "host": host,
        "port": port,
        "method": method,
        "password": password,
    }


def parse_proxy_link(link: str) -> dict:
    link = link.strip()
    legacy = re.fullmatch(
        r"(socks5|socks|http|https|ss):([^:]+):([0-9]+)@([^:]*):(.*)",
        link,
        flags=re.IGNORECASE,
    )
    if legacy:
        scheme, host, port, first, second = legacy.groups()
        scheme = scheme.lower()
        port_number = int(port)
        if not (1 <= port_number <= 65535):
            raise ValueError("代理端口超出范围")
        if scheme == "ss":
            return {
                "scheme": "ss",
                "host": host,
                "port": port_number,
                "method": first,
                "password": second,
            }
        return {
            "scheme": "socks5" if scheme == "socks" else scheme,
            "host": host,
            "port": port_number,
            "username": first,
            "password": second,
        }

    if "://" not in link:
        raise ValueError("代理链接必须包含协议")
    scheme = link.split("://", 1)[0].lower()
    if scheme == "ss":
        return parse_shadowsocks(link)
    if scheme not in {"socks", "socks5", "http", "https"}:
        raise ValueError(f"暂不支持代理协议：{scheme}")

    parsed = urlsplit(link)
    if not parsed.hostname or parsed.port is None:
        raise ValueError("代理链接缺少地址或端口")
    if not (1 <= parsed.port <= 65535):
        raise ValueError("代理端口超出范围")
    return {
        "scheme": "socks5" if scheme == "socks" else scheme,
        "host": parsed.hostname,
        "port": parsed.port,
        "username": unquote(parsed.username or ""),
        "password": unquote(parsed.password or ""),
    }


def proxy_endpoint(host: str, port: int) -> str:
    if ":" in host and not host.startswith("["):
        host = f"[{host}]"
    return f"{host}:{port}"


def probe_with_curl(parsed: dict, url: str, remote_dns: bool) -> dict:
    username = parsed.get("username", "")
    password = parsed.get("password", "")
    if ":" in username:
        raise ValueError("SOCKS5 用户名不能包含冒号")
    if any(ord(character) < 32 or ord(character) == 127 for character in username + password):
        raise ValueError("SOCKS5 用户名和密码不能包含控制字符")

    curl_config = ""
    if username or password:
        curl_config = (
            "proxy-user = "
            + json.dumps(f"{username}:{password}", ensure_ascii=False)
            + "\n"
        )

    dns_option = "--socks5-hostname" if remote_dns else "--socks5"
    command = [
        "curl",
        "--disable",
        "--config",
        "-",
        "--silent",
        "--show-error",
        "--output",
        "/dev/null",
        "--noproxy",
        "",
        "--connect-timeout",
        "5",
        "--max-time",
        "12",
        "--ipv4",
        "--write-out",
        "%{http_code}",
        "--socks5-basic",
        dns_option,
        proxy_endpoint(parsed["host"], parsed["port"]),
        url,
    ]
    completed = subprocess.run(
        command,
        input=curl_config,
        text=True,
        capture_output=True,
        check=False,
    )
    status = completed.stdout.strip()[-3:]
    if not status.isdigit():
        status = "000"
    return {
        "ok": completed.returncode == 0,
        "exitCode": completed.returncode,
        "httpStatus": status,
    }


def probe_socks_resolution(parsed: dict, name: str) -> dict:
    checked_at = (
        datetime.now(timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z")
    )
    attempts = []
    print(
        f"[出口检测] {name}: 正在对照检测远程域名与本地 IPv4 连接...",
        file=sys.stderr,
    )

    for target_name, target_url in SOCKS_PROBE_TARGETS:
        remote = probe_with_curl(parsed, target_url, remote_dns=True)
        attempt = {
            "target": target_name,
            "remoteDomain": remote,
        }
        attempts.append(attempt)
        if remote["ok"]:
            summary = f"SOCKS 远程解析正常（{target_name}）"
            print(f"[出口检测] {name}: {summary}，保持 AsIs。", file=sys.stderr)
            return {
                "result": "remote-ok",
                "mode": "remote-domain",
                "targetStrategy": "AsIs",
                "checkedAt": checked_at,
                "summary": summary,
                "attempts": attempts,
            }

        local = probe_with_curl(parsed, target_url, remote_dns=False)
        attempt["localIPv4"] = local
        if not local["ok"]:
            continue

        # 同一目标再验证一次，避免瞬时网络错误导致误判。
        confirm_remote = probe_with_curl(parsed, target_url, remote_dns=True)
        confirm_local = probe_with_curl(parsed, target_url, remote_dns=False)
        attempt["confirmation"] = {
            "remoteDomain": confirm_remote,
            "localIPv4": confirm_local,
        }
        if not confirm_remote["ok"] and confirm_local["ok"]:
            summary = f"远程域名异常，Xray 先解析 IPv4（{target_name}）"
            print(
                f"[出口检测] {name}: {summary}，启用 UseIPv4 兜底。",
                file=sys.stderr,
            )
            return {
                "result": "fallback-ipv4",
                "mode": "xray-ipv4",
                "targetStrategy": "UseIPv4",
                "checkedAt": checked_at,
                "summary": summary,
                "attempts": attempts,
            }
        if confirm_remote["ok"]:
            summary = f"SOCKS 远程解析正常（{target_name}，首次检测为瞬时失败）"
            print(f"[出口检测] {name}: {summary}，保持 AsIs。", file=sys.stderr)
            return {
                "result": "remote-ok",
                "mode": "remote-domain",
                "targetStrategy": "AsIs",
                "checkedAt": checked_at,
                "summary": summary,
                "attempts": attempts,
            }

    failure = (
        f"出口「{name}」的 SOCKS 域名模式和 IPv4 模式均未通过 HTTPS 检测；"
        "请检查地址、端口、认证或代理服务状态。"
    )
    if not allow_failed_socks:
        if probe_failure_marker:
            Path(probe_failure_marker).write_text(failure, encoding="utf-8")
        raise RuntimeError(failure)

    summary = "检测失败，用户已确认忽略风险并强制写入（保持 AsIs）"
    print(f"[出口检测] {name}: {summary}。", file=sys.stderr)
    return {
        "result": "forced-unverified",
        "mode": "remote-domain",
        "targetStrategy": "AsIs",
        "checkedAt": checked_at,
        "summary": summary,
        "attempts": attempts,
    }


def proxy_outbound(parsed: dict, tag: str, resolution_check: dict | None) -> dict:
    scheme = parsed["scheme"]
    if scheme == "socks5":
        settings = {
            "address": parsed["host"],
            "port": parsed["port"],
        }
        if parsed["username"] or parsed["password"]:
            settings["user"] = parsed["username"]
            settings["pass"] = parsed["password"]
        outbound = {"protocol": "socks", "tag": tag, "settings": settings}
        if resolution_check and resolution_check["targetStrategy"] == "UseIPv4":
            outbound["targetStrategy"] = "UseIPv4"
        return outbound

    if scheme in {"http", "https"}:
        settings = {
            "address": parsed["host"],
            "port": parsed["port"],
        }
        if parsed["username"] or parsed["password"]:
            settings["user"] = parsed["username"]
            settings["pass"] = parsed["password"]
        outbound = {"protocol": "http", "tag": tag, "settings": settings}
        if scheme == "https":
            outbound["streamSettings"] = {
                "security": "tls",
                "tlsSettings": {
                    "serverName": parsed["host"],
                    "allowInsecure": False,
                },
            }
        return outbound

    if scheme == "ss":
        return {
            "protocol": "shadowsocks",
            "tag": tag,
            "settings": {
                "address": parsed["host"],
                "port": parsed["port"],
                "method": parsed["method"],
                "password": parsed["password"],
            },
        }
    raise ValueError(f"不支持的代理协议：{scheme}")


def yaml_scalar(value: str) -> str:
    return json.dumps(str(value), ensure_ascii=False)


pending_model_path = env("CFG_PENDING_MODEL")
pending_model = None
if pending_model_path:
    try:
        pending_model = json.loads(Path(pending_model_path).read_text())
    except Exception as error:
        raise SystemExit(f"无法读取待更新模型：{error}")
    if pending_model.get("version") != 3 or pending_model.get("managedBy") != "vps-manager":
        raise SystemExit("待更新模型不是 VPS Manager v3 受管结构")

if pending_model:
    node_name = str(pending_model["nodeName"])
    public_address = str(pending_model["publicAddress"])
    reality = pending_model["reality"]
    reality_port = int(reality["port"])
    reality_dest = str(reality["dest"])
    server_names = list(
        dict.fromkeys(
            str(value).strip()
            for value in reality["serverNames"]
            if str(value).strip()
        )
    )
    private_key = str(reality["privateKey"])
    public_key = str(reality["publicKey"])
    short_id = str(reality["shortId"])
    guard = reality.get("guard", {"enabled": True})
    guard_enabled = bool(guard.get("enabled", True))
    guard_port = int(guard.get("port", 39000))
else:
    node_name = env("CFG_NODE_NAME")
    public_address = env("CFG_PUBLIC_ADDRESS")
    reality_port = int(env("CFG_REALITY_PORT"))
    reality_dest = env("CFG_REALITY_DEST")
    server_names = list(
        dict.fromkeys(
            value.strip()
            for value in env("CFG_SERVER_NAMES").split(",")
            if value.strip()
        )
    )
    private_key = env("CFG_PRIVATE_KEY")
    public_key = env("CFG_PUBLIC_KEY")
    short_id = env("CFG_SHORT_ID")
    guard_enabled = True
    guard_port = 39000

if not server_names:
    raise SystemExit("Reality serverNames 不能为空")
server_name = server_names[0]

proxy_entries = []
if pending_model:
    for index, item in enumerate(pending_model.get("proxies", []), 1):
        try:
            if item.get("sourceLink"):
                parsed = parse_proxy_link(str(item["sourceLink"]))
            else:
                parsed = dict(item["proxy"])
            resolution_check = item.get("resolutionCheck")
            if parsed["scheme"] == "socks5" and item.get("needsProbe"):
                resolution_check = probe_socks_resolution(parsed, str(item["name"]))
            proxy_entries.append({
                "name": str(item["name"]), "parsed": parsed,
                "resolutionCheck": resolution_check,
                "identity": {key: str(item[key]) for key in ("id", "tag", "email", "uuid")},
            })
        except Exception as error:
            raise SystemExit(f"第 {index} 个出口代理处理失败：{error}")
else:
    for line_number, line in enumerate(proxy_input.read_text().splitlines(), 1):
        if not line:
            continue
        try:
            encoded_name, encoded_link = line.split("\t", 1)
            name = base64.b64decode(encoded_name).decode()
            link = base64.b64decode(encoded_link).decode()
            parsed = parse_proxy_link(link)
        except Exception as error:
            raise SystemExit(f"第 {line_number} 个出口代理解析失败：{error}")
        resolution_check = None
        if parsed["scheme"] == "socks5":
            try:
                resolution_check = probe_socks_resolution(parsed, name)
            except Exception as error:
                raise SystemExit(f"第 {line_number} 个出口代理检测失败：{error}")
        proxy_entries.append({
            "name": name, "parsed": parsed,
            "resolutionCheck": resolution_check, "identity": None,
        })

needs_shared_dns = any(
    entry["resolutionCheck"]
    and entry["resolutionCheck"]["targetStrategy"] == "UseIPv4"
    for entry in proxy_entries
)

clients = []
routing_rules = []
outbounds = [
    {
        "protocol": "freedom",
        "tag": "direct",
        "settings": {"domainStrategy": "UseIPv4"},
    }
]

managed_ports = {reality_port}
if pending_model:
    managed_ports.update(
        int(item["port"])
        for item in pending_model.get("optionalInbounds", {}).values()
    )
else:
    if env("CFG_ENABLE_SOCKS") == "1":
        managed_ports.add(int(env("CFG_SOCKS_PORT")))
    if env("CFG_ENABLE_SS") == "1":
        managed_ports.add(int(env("CFG_SS_PORT")))
if guard_enabled:
    if not 39000 <= guard_port <= 59999 or guard_port in managed_ports:
        guard_port = next(
            (port for port in range(39000, 60000) if port not in managed_ports),
            0,
        )
    if not guard_port:
        raise SystemExit("没有可用的 Reality 防偷本地端口")
    outbounds.append({"protocol": "blackhole", "tag": "reality-guard-block"})

native_identity = pending_model.get("native", {}) if pending_model else {}
local_email = str(native_identity.get("email", "local@vps-manager.local"))
local_uuid = str(native_identity.get("uuid") or uuid.uuid4())
local_name = str(native_identity.get("name", "native"))
clients.append(
    {
        "id": local_uuid,
        "flow": "xtls-rprx-vision",
        "email": local_email,
    }
)
routing_rules.append(
    {"type": "field", "user": [local_email], "outboundTag": "direct"}
)

state_proxies = []
display_clients = [
    {
        "name": local_name,
        "uuid": local_uuid,
        "email": local_email,
        "outbound": "direct",
        "resolution": "VPS 本机 IPv4 解析",
    }
]

for index, entry in enumerate(proxy_entries, 1):
    identity = entry.get("identity") or {}
    tag = str(identity.get("tag") or f"proxy_{index}")
    email = str(identity.get("email") or f"proxy-{index}@vps-manager.local")
    client_uuid = str(identity.get("uuid") or uuid.uuid4())
    stable_id = str(identity.get("id") or uuid.uuid4())
    clients.append(
        {
            "id": client_uuid,
            "flow": "xtls-rprx-vision",
            "email": email,
        }
    )
    outbounds.append(
        proxy_outbound(entry["parsed"], tag, entry["resolutionCheck"])
    )
    routing_rules.append(
        {"type": "field", "user": [email], "outboundTag": tag}
    )
    display_clients.append(
        {
            "name": entry["name"],
            "uuid": client_uuid,
            "email": email,
            "outbound": tag,
            "resolution": (
                entry["resolutionCheck"]["summary"]
                if entry["resolutionCheck"]
                else "由上游代理解析域名"
            ),
        }
    )
    parsed = entry["parsed"]
    state_proxies.append(
        {
            "id": stable_id,
            "name": entry["name"],
            "protocol": parsed["scheme"],
            "address": parsed["host"],
            "port": parsed["port"],
            "tag": tag,
            "email": email,
            "uuid": client_uuid,
            "proxy": parsed,
            "resolutionCheck": entry["resolutionCheck"],
        }
    )

reality_runtime_target = (
    f"127.0.0.1:{guard_port}" if guard_enabled else reality_dest
)
inbounds = [
    {
        "port": reality_port,
        "protocol": "vless",
        "settings": {
            "clients": clients,
            "decryption": "none",
        },
        "streamSettings": {
            "network": "tcp",
            "security": "reality",
            "realitySettings": {
                "show": False,
                "dest": reality_runtime_target,
                "xver": 0,
                "serverNames": server_names,
                "privateKey": private_key,
                "shortIds": [short_id],
            },
        },
    }
]

if guard_enabled:
    target_host, target_port = parse_host_port(reality_dest)
    inbounds.append(
        {
            "tag": "reality-guard-in",
            "listen": "127.0.0.1",
            "port": guard_port,
            "protocol": "dokodemo-door",
            "settings": {
                "address": target_host,
                "port": target_port,
                "network": "tcp",
            },
            "sniffing": {
                "enabled": True,
                "destOverride": ["tls"],
                "routeOnly": True,
            },
        }
    )
    routing_rules[0:0] = [
        {
            "type": "field",
            "inboundTag": ["reality-guard-in"],
            "domain": [f"full:{name}" for name in server_names],
            "outboundTag": "direct",
        },
        {
            "type": "field",
            "inboundTag": ["reality-guard-in"],
            "outboundTag": "reality-guard-block",
        },
    ]

optional_inbounds = {}
pending_optional = pending_model.get("optionalInbounds", {}) if pending_model else {}
socks_input = pending_optional.get("socks5") if pending_model else None
if socks_input or (not pending_model and env("CFG_ENABLE_SOCKS") == "1"):
    socks_port = int(socks_input["port"]) if socks_input else int(env("CFG_SOCKS_PORT"))
    socks_user = str(socks_input["username"]) if socks_input else env("CFG_SOCKS_USER")
    socks_pass = str(socks_input["password"]) if socks_input else env("CFG_SOCKS_PASS")
    socks_listen = str(socks_input["listen"]) if socks_input else env("CFG_SOCKS_LISTEN")
    inbounds.append(
        {
            "tag": "socks-in",
            "listen": socks_listen,
            "port": socks_port,
            "protocol": "socks",
            "settings": {
                "auth": "password",
                "users": [{"user": socks_user, "pass": socks_pass}],
                "udp": False,
            },
        }
    )
    routing_rules.append(
        {"type": "field", "inboundTag": ["socks-in"], "outboundTag": "direct"}
    )
    optional_inbounds["socks5"] = {
        "listen": socks_listen,
        "port": socks_port,
        "username": socks_user,
        "password": socks_pass,
    }

ss_input = pending_optional.get("shadowsocks") if pending_model else None
if ss_input or (not pending_model and env("CFG_ENABLE_SS") == "1"):
    ss_port = int(ss_input["port"]) if ss_input else int(env("CFG_SS_PORT"))
    ss_method = str(ss_input["method"]) if ss_input else env("CFG_SS_METHOD")
    ss_pass = str(ss_input["password"]) if ss_input else env("CFG_SS_PASS")
    ss_listen = str(ss_input["listen"]) if ss_input else env("CFG_SS_LISTEN")
    inbounds.append(
        {
            "tag": "shadowsocks-in",
            "listen": ss_listen,
            "port": ss_port,
            "protocol": "shadowsocks",
            "settings": {
                "network": "tcp,udp",
                "method": ss_method,
                "password": ss_pass,
            },
        }
    )
    routing_rules.append(
        {
            "type": "field",
            "inboundTag": ["shadowsocks-in"],
            "outboundTag": "direct",
        }
    )
    optional_inbounds["shadowsocks"] = {
        "listen": ss_listen,
        "port": ss_port,
        "method": ss_method,
        "password": ss_pass,
    }

config = {"log": {"loglevel": "warning"}}
if needs_shared_dns:
    config["dns"] = {
        "servers": ["https+local://1.1.1.1/dns-query"],
        "queryStrategy": "UseIPv4",
    }
config.update(
    {
        "inbounds": inbounds,
        "outbounds": outbounds,
        "routing": {"domainStrategy": "AsIs", "rules": routing_rules},
    }
)
config_text = json.dumps(config, ensure_ascii=False, indent=2) + "\n"
config_path.write_text(config_text)

yaml_lines = []
for client in display_clients:
    label = f"{node_name}-{client['name']}"
    yaml_lines.extend(
        [
            f"- name: {yaml_scalar(label)}",
            "  type: vless",
            f"  server: {yaml_scalar(public_address)}",
            f"  port: {reality_port}",
            f"  uuid: {yaml_scalar(client['uuid'])}",
            "  udp: false",
            "  tls: true",
            "  flow: xtls-rprx-vision",
            f"  servername: {yaml_scalar(server_name)}",
            "  reality-opts:",
            f"    public-key: {yaml_scalar(public_key)}",
            f"    short-id: {yaml_scalar(short_id)}",
            "  client-fingerprint: chrome",
            "  network: tcp",
        ]
    )

state = {
    "version": 3,
    "managedBy": "vps-manager",
    "configSha256": hashlib.sha256(config_text.encode()).hexdigest(),
    "nodeName": node_name,
    "publicAddress": public_address,
    "reality": {
        "port": reality_port,
        "dest": reality_dest,
        "serverNames": server_names,
        "privateKey": private_key,
        "publicKey": public_key,
        "shortId": short_id,
        "guard": {"enabled": guard_enabled, "port": guard_port},
    },
    "native": {
        "name": local_name,
        "uuid": local_uuid,
        "email": local_email,
        "outbound": "direct",
    },
    "clients": display_clients,
    "proxies": state_proxies,
    "dnsFallback": {
        "enabled": needs_shared_dns,
        "server": (
            "https+local://1.1.1.1/dns-query"
            if needs_shared_dns
            else None
        ),
        "route": "VPS direct",
    },
    "optionalInbounds": optional_inbounds,
}
state_path.write_text(
    json.dumps(state, ensure_ascii=False, indent=2) + "\n"
)

lines = [
    f"节点名称: {node_name}",
    f"自动检测地址: {public_address}:{reality_port}",
    f"Reality dest: {reality_dest}",
    f"Reality serverNames: {', '.join(server_names)}",
    f"Reality 防偷: {'开启' if guard_enabled else '关闭'}"
    + (f"（127.0.0.1:{guard_port}，full: 精确匹配）" if guard_enabled else ""),
    f"YAML servername: {server_name}",
    f"Reality PrivateKey: {private_key}",
    f"Reality PublicKey/Password: {public_key}",
    f"Reality Short ID: {short_id}",
    "",
    "VLESS 客户端:",
]
for client in display_clients:
    lines.extend(
        [
            f"- {client['name']}",
            f"  UUID: {client['uuid']}",
            f"  出口: {client['outbound']}",
            f"  域名处理: {client['resolution']}",
        ]
    )

if needs_shared_dns:
    lines.extend(
        [
            "",
            "共享 IPv4 DNS 兜底:",
            "  DoH: https+local://1.1.1.1/dns-query",
            "  路径: VPS 直连（供本配置中所有 UseIPv4 出站解析域名）",
        ]
    )

if "socks5" in optional_inbounds:
    item = optional_inbounds["socks5"]
    lines.extend(
        [
            "",
            "SOCKS5 入站:",
            f"  监听: {item['listen']}:{item['port']}",
            f"  用户名: {item['username']}",
            f"  密码: {item['password']}",
        ]
    )
    if item["listen"] not in {"127.0.0.1", "::1"}:
        yaml_lines.extend(
            [
                f"- name: {yaml_scalar(f'{node_name}-socks5')}",
                "  type: socks5",
                f"  server: {yaml_scalar(public_address)}",
                f"  port: {item['port']}",
                f"  username: {yaml_scalar(item['username'])}",
                f"  password: {yaml_scalar(item['password'])}",
                "  udp: false",
            ]
        )
    else:
        lines.append("  提示: 仅监听本机，因此不生成 AWS YAML 节点。")

if "shadowsocks" in optional_inbounds:
    item = optional_inbounds["shadowsocks"]
    lines.extend(
        [
            "",
            "Shadowsocks 入站:",
            f"  监听: {item['listen']}:{item['port']}",
            f"  加密: {item['method']}",
            f"  密码: {item['password']}",
        ]
    )
    yaml_lines.extend(
        [
            f"- name: {yaml_scalar(f'{node_name}-ss')}",
            "  type: ss",
            f"  server: {yaml_scalar(public_address)}",
            f"  port: {item['port']}",
            f"  cipher: {yaml_scalar(item['method'])}",
            f"  password: {yaml_scalar(item['password'])}",
            "  udp: true",
        ]
    )

lines.extend(
    [
        "",
        "提醒: 云厂商安全组端口需要单独开放。",
    ]
)
info_path.write_text("\n".join(lines) + "\n")
yaml_path.write_text("\n".join(yaml_lines) + "\n")
PY
}


generate_xray_files() {
  local private_key="$1"
  local public_key="$2"
  local short_id="$3"
  local proxy_input="$4"
  local generated_config="$5"
  local generated_state="$6"
  local generated_info="$7"
  local generated_yaml="$8"
  local pending_model="${9:-}"
  local failure_marker="${generated_config}.socks-probe-failed"
  local failure_message=""

  rm -f -- "${failure_marker}"
  if generate_xray_files_once "${private_key}" "${public_key}" "${short_id}" "${proxy_input}" "${generated_config}" "${generated_state}" "${generated_info}" "${generated_yaml}" "${pending_model}" "0" "${failure_marker}"; then
    rm -f -- "${failure_marker}"
    return 0
  fi
  [[ -s "${failure_marker}" ]] || return 1
  failure_message="$(cat "${failure_marker}")"
  warn "${failure_message}"
  prompt_yes_no "仍要忽略风险并写入失败的 SOCKS 出口（节点可能完全无法连接）" "0" || { rm -f -- "${failure_marker}"; return 1; }
  rm -f -- "${generated_config}" "${generated_state}" "${generated_info}" "${generated_yaml}"
  if generate_xray_files_once "${private_key}" "${public_key}" "${short_id}" "${proxy_input}" "${generated_config}" "${generated_state}" "${generated_info}" "${generated_yaml}" "${pending_model}" "1" "${failure_marker}"; then
    rm -f -- "${failure_marker}"
    return 0
  fi
  rm -f -- "${failure_marker}"
  return 1
}


generate_reality_keys() {
  local key_output
  local private_key
  local public_key

  key_output="$("${XRAY_BIN}" x25519)"
  private_key="$(printf '%s\n' "${key_output}" | sed -n 's/^PrivateKey:[[:space:]]*//p' | head -n 1)"
  public_key="$(printf '%s\n' "${key_output}" | sed -n 's/^Password (PublicKey):[[:space:]]*//p' | head -n 1)"
  if [[ -z "${public_key}" ]]; then
    public_key="$(printf '%s\n' "${key_output}" | sed -n -E 's/^(PublicKey|Public key):[[:space:]]*//p' | head -n 1)"
  fi
  [[ -n "${private_key}" && -n "${public_key}" ]] \
    || die "无法解析 Xray x25519 输出。"
  printf '%s\t%s' "${private_key}" "${public_key}"
}


xray_service_user() {
  local user
  if is_alpine; then printf 'xray'; return 0; fi
  user="$(systemctl show xray.service --property=User --value 2>/dev/null || true)"
  printf '%s' "${user:-root}"
}


validate_xray_config() {
  local path="$1"
  local service_user

  service_user="$(xray_service_user)"
  if [[ "${service_user}" == "root" ]]; then
    "${XRAY_BIN}" run -test -config "${path}"
  elif is_alpine; then
    su-exec "${service_user}" "${XRAY_BIN}" run -test -config "${path}"
  else
    runuser -u "${service_user}" -- "${XRAY_BIN}" run -test -config "${path}"
  fi
}


rollback_xray_config() {
  local backup_file="$1"

  if [[ -n "${backup_file}" && -f "${backup_file}" ]]; then
    cp -a -- "${backup_file}" "${XRAY_CONFIG}"
    service_restart xray || true
    warn "新配置启动失败，已恢复原配置。"
  else
    warn "新配置启动失败，且没有可恢复的旧配置。"
  fi
}


maybe_open_ufw_port() {
  local port="$1"
  local protocol="$2"

  command -v ufw >/dev/null 2>&1 || return 0
  ufw status 2>/dev/null | grep -q '^Status: active' || return 0
  if prompt_yes_no "检测到 UFW，是否开放 ${port}/${protocol}" "1"; then
    ufw allow "${port}/${protocol}"
  fi
}


configure_xray() {
  local key_pair
  local private_key
  local public_key
  local short_id
  local proxy_input
  local generated_config
  local generated_state
  local generated_info
  local generated_yaml
  local service_user
  local service_group
  local staged_config="" staged_state="" staged_info="" staged_yaml=""
  local bundle=""
  local failed=0

  require_root
  check_supported_os
  command -v python3 >/dev/null 2>&1 || die "需要 python3。"
  command -v openssl >/dev/null 2>&1 || die "需要 openssl。"
  command -v curl >/dev/null 2>&1 || die "需要 curl 来检测 SOCKS5 出站兼容性。"

  if [[ "${DEMO_MODE}" != "1" && ! -x "${XRAY_BIN}" ]]; then
    die "尚未安装 Xray，请先选择“安装或升级 Xray”。"
  fi

  log "收集 Xray 配置"
  collect_xray_configuration
  ensure_work_dir
  proxy_input="${WORK_DIR}/proxies.tsv"
  generated_config="${WORK_DIR}/config.json"
  generated_state="${WORK_DIR}/state.json"
  generated_info="${WORK_DIR}/last-install.txt"
  generated_yaml="${WORK_DIR}/proxies.yaml"
  write_proxy_input_file "${proxy_input}"

  if [[ "${DEMO_MODE}" == "1" ]]; then
    private_key="DEMO_PRIVATE_KEY"
    public_key="DEMO_PUBLIC_KEY"
    short_id="0123456789abcdef"
  else
    key_pair="$(generate_reality_keys)"
    private_key="${key_pair%%$'\t'*}"
    public_key="${key_pair#*$'\t'}"
    short_id="$(openssl rand -hex 8)"
  fi

  generate_xray_files \
    "${private_key}" \
    "${public_key}" \
    "${short_id}" \
    "${proxy_input}" \
    "${generated_config}" \
    "${generated_state}" \
    "${generated_info}" \
    "${generated_yaml}"

  if [[ "${DEMO_MODE}" == "1" ]]; then
    DEMO_CONFIG_FILE="${generated_config}"
    DEMO_STATE_FILE="${generated_state}"
    DEMO_INFO_FILE="${generated_info}"
    DEMO_YAML_FILE="${generated_yaml}"
    log "[预览] 完整 config.json（不会写入系统）"
    cat "${DEMO_CONFIG_FILE}"
    return 0
  fi

  service_user="$(xray_service_user)"
  id "${service_user}" >/dev/null 2>&1 || die "Xray 服务用户不存在：${service_user}"
  service_group="$(id -gn "${service_user}")"
  install -d -o root -g root -m 755 "$(dirname "${XRAY_CONFIG}")"
  install -d -o root -g root -m 700 "${STATE_DIR}"

  staged_config="$(mktemp_json "$(dirname "${XRAY_CONFIG}")" .config)"
  staged_state="$(mktemp "${STATE_DIR}/.state.json.XXXXXX")"
  staged_info="$(mktemp "${STATE_DIR}/.last-install.txt.XXXXXX")"
  staged_yaml="$(mktemp "${STATE_DIR}/.proxies.yaml.XXXXXX")"
  if ! install -o root -g "${service_group}" -m 640 "${generated_config}" "${staged_config}" \
    || ! install -o root -g root -m 600 "${generated_state}" "${staged_state}" \
    || ! install -o root -g root -m 600 "${generated_info}" "${staged_info}" \
    || ! install -o root -g root -m 600 "${generated_yaml}" "${staged_yaml}"; then
    rm -f -- "${staged_config}" "${staged_state}" "${staged_info}" "${staged_yaml}"
    die "候选文件暂存失败，系统配置没有变化。"
  fi

  log "使用 Xray 服务用户校验新配置"
  if ! validate_xray_config "${staged_config}"; then
    rm -f -- "${staged_config}" "${staged_state}" "${staged_info}" "${staged_yaml}"
    die "候选 Xray 配置校验失败，系统配置没有变化。"
  fi
  if ! bundle="$(backup_xray_bundle)" || [[ -z "${bundle}" || ! -d "${bundle}" ]]; then
    rm -f -- "${staged_config}" "${staged_state}" "${staged_info}" "${staged_yaml}"
    die "统一备份失败，拒绝替换系统配置。"
  fi

  mv -f -- "${staged_config}" "${XRAY_CONFIG}" || failed=1
  [[ "${failed}" != 0 ]] || mv -f -- "${staged_state}" "${STATE_FILE}" || failed=1
  [[ "${failed}" != 0 ]] || mv -f -- "${staged_info}" "${INFO_FILE}" || failed=1
  [[ "${failed}" != 0 ]] || mv -f -- "${staged_yaml}" "${YAML_FILE}" || failed=1
  [[ "${failed}" != 0 ]] || validate_xray_config "${XRAY_CONFIG}" || failed=1
  if [[ "${failed}" == 0 && ! is_alpine ]]; then systemctl daemon-reload || failed=1; fi
  [[ "${failed}" != 0 ]] || service_enable_start xray || failed=1
  [[ "${failed}" != 0 ]] || service_restart xray || failed=1
  [[ "${failed}" != 0 ]] || service_is_active xray || failed=1
  if [[ "${failed}" != 0 ]]; then
    rm -f -- "${staged_config}" "${staged_state}" "${staged_info}" "${staged_yaml}"
    if ! rollback_xray_bundle "${bundle}"; then
      die "完整配置失败，且统一备份未能恢复，请立即检查 ${bundle}。"
    fi
    die "完整配置失败，已恢复原配置和服务。"
  fi

  maybe_open_ufw_port "${CFG_REALITY_PORT}" "tcp"
  if [[ "${CFG_ENABLE_SOCKS}" == "1" && "${CFG_SOCKS_LISTEN}" != "127.0.0.1" && "${CFG_SOCKS_LISTEN}" != "::1" ]]; then
    maybe_open_ufw_port "${CFG_SOCKS_PORT}" "tcp"
  fi
  if [[ "${CFG_ENABLE_SS}" == "1" ]]; then
    maybe_open_ufw_port "${CFG_SS_PORT}" "tcp"
    maybe_open_ufw_port "${CFG_SS_PORT}" "udp"
  fi

  log "Xray 配置完成"
  printf '连接参数已保存：%s\n' "${INFO_FILE}"
  printf 'AWS YAML 节点已保存：%s\n' "${YAML_FILE}"
  printf '统一备份：%s\n' "${bundle}"
}


load_xray_model_from_paths() {
  local config_source="$1" state_source="$2" destination="$3" mode="${4:-strict}" public_key_override="${5:-}"
  python3 - "${config_source}" "${state_source}" "${destination}" "${mode}" "${public_key_override}" <<'PY'
from __future__ import annotations
from collections import Counter
import hashlib, json, os, sys, uuid
from pathlib import Path

config_path, state_path, destination = map(Path, sys.argv[1:4])
mode, public_key_override = sys.argv[4:6]
adopt_live = mode == "adopt-live"
if mode not in {"strict", "adopt-live"}: raise SystemExit("未知配置加载模式")
def stop(message): raise SystemExit(f"无法更新：{message}")
try:
    config_text = config_path.read_text(); config = json.loads(config_text)
    state = json.loads(state_path.read_text())
except Exception as error: stop(f"读取现有配置失败：{error}")
version = state.get("version")
if version not in (2, 3): stop("state.json 版本不受支持")
if version == 3:
    if state.get("managedBy") != "vps-manager": stop("state.json 不是 VPS Manager 受管状态")
    if not adopt_live and state.get("configSha256") and state["configSha256"] != hashlib.sha256(config_text.encode()).hexdigest():
        stop("config.json 已在脚本外修改，状态指纹不一致")
if not isinstance(config, dict) or set(config) - {"log","dns","inbounds","outbounds","routing"}: stop("config.json 包含非脚本管理的顶层配置")
if config.get("log") != {"loglevel":"warning"}: stop("log 配置不符合脚本管理结构")
inbounds, outbounds, routing = (config.get(x) for x in ("inbounds","outbounds","routing"))
if not isinstance(inbounds,list) or not isinstance(outbounds,list) or not isinstance(routing,dict): stop("缺少 inbounds/outbounds/routing")
if routing.get("domainStrategy") != "AsIs" or set(routing) != {"domainStrategy","rules"} or not isinstance(routing.get("rules"),list): stop("routing 不是脚本管理结构")
reality_list=[x for x in inbounds if x.get("protocol")=="vless" and x.get("streamSettings",{}).get("security")=="reality"]
if len(reality_list)!=1: stop("必须且只能存在一个受管 VLESS-Reality 入站")
reality_inbound=reality_list[0]
if set(reality_inbound)!={"port","protocol","settings","streamSettings"}: stop("VLESS-Reality 入站包含非脚本管理字段")
settings=reality_inbound.get("settings",{}); stream=reality_inbound.get("streamSettings",{}); rs=stream.get("realitySettings",{})
target_fields=set(rs)&{"target","dest"}
if len(target_fields)!=1: stop("Reality 必须且只能包含 target 或 dest")
target_field=next(iter(target_fields))
if set(settings)!={"clients","decryption"} or settings.get("decryption")!="none" or stream.get("network")!="tcp" or set(stream)!={"network","security","realitySettings"} or set(rs)!={"show",target_field,"xver","serverNames","privateKey","shortIds"} or rs.get("show") is not False or rs.get("xver")!=0: stop("VLESS-Reality 内容不是脚本生成结构")
if len(rs.get("shortIds",[]))!=1: stop("更新器只管理一个 Reality Short ID")
guard_inbounds=[x for x in inbounds if x.get("tag")=="reality-guard-in"]
if len(guard_inbounds)>1: stop("Reality 防偷辅助入站重复")
guard_inbound=guard_inbounds[0] if guard_inbounds else None
guard_enabled=guard_inbound is not None
guard_port=None
original_target=str(rs[target_field])
if guard_enabled:
    guard_port=int(guard_inbound.get("port",0)); gs=guard_inbound.get("settings",{})
    expected_guard={"tag":"reality-guard-in","listen":"127.0.0.1","port":guard_port,"protocol":"dokodemo-door","settings":gs,"sniffing":{"enabled":True,"destOverride":["tls"],"routeOnly":True}}
    if guard_inbound!=expected_guard or set(gs)!={"address","port","network"} or gs.get("network")!="tcp" or not 39000<=guard_port<=59999: stop("Reality 防偷辅助入站不是脚本管理结构")
    if original_target!=f"127.0.0.1:{guard_port}": stop("Reality target 未指向防偷辅助入站")
    host=str(gs.get("address","")); port=int(gs.get("port",0))
    original_target=f"[{host}]:{port}" if ":" in host else f"{host}:{port}"
state_clients=state.get("clients"); state_proxies=state.get("proxies")
if not isinstance(state_clients,list) or not isinstance(state_proxies,list): stop("state.json 缺少 clients/proxies")
by_tag={}
for x in outbounds:
    tag=x.get("tag")
    if not isinstance(tag,str) or not tag or tag in by_tag: stop("出口 tag 缺失或重复")
    by_tag[tag]=x
managed_special={"direct","reality-guard-block"} if guard_enabled else {"direct"}
proxy_tags=sorted(set(by_tag)-managed_special) if adopt_live else [str(x.get("tag","")) for x in state_proxies]
if not all(proxy_tags) or len(set(proxy_tags))!=len(proxy_tags): stop("state.json 的 ISP tag 无效")
if set(by_tag)!={*managed_special,*proxy_tags}: stop("发现 state.json 未登记出口，或受管出口缺失")
if by_tag["direct"]!={"protocol":"freedom","tag":"direct","settings":{"domainStrategy":"UseIPv4"}}: stop("direct 出口不是脚本管理结构")
if guard_enabled and by_tag["reality-guard-block"]!={"protocol":"blackhole","tag":"reality-guard-block"}: stop("Reality 防偷 block 出口不是脚本管理结构")
runtime=settings.get("clients")
if not isinstance(runtime,list): stop("VLESS clients 格式错误")
runtime_by_email={}
for c in runtime:
    if set(c)!={"id","flow","email"} or c.get("flow")!="xtls-rprx-vision": stop("发现非脚本管理 VLESS client")
    try: uuid.UUID(str(c.get("id")))
    except Exception: stop("VLESS client UUID 无效")
    email=c.get("email")
    if not isinstance(email,str) or email in runtime_by_email: stop("VLESS client email 缺失或重复")
    runtime_by_email[email]=c
state_meta_by_outbound={}
for c in state_clients:
    tag=c.get("outbound")
    if not isinstance(tag,str) or tag in state_meta_by_outbound: stop("state clients 出口缺失或重复")
    state_meta_by_outbound[tag]=c
if adopt_live:
    route_email_by_outbound={}
    for rule in routing["rules"]:
        users=rule.get("user"); tag=rule.get("outboundTag")
        if users is None: continue
        if not isinstance(users,list) or len(users)!=1 or not isinstance(tag,str) or tag in route_email_by_outbound:
            stop("外部修改后的 user 路由无法唯一映射到出口")
        route_email_by_outbound[tag]=str(users[0])
    if set(route_email_by_outbound)!={"direct",*proxy_tags}: stop("外部修改后的 client 与出口路由不完整")
    if set(route_email_by_outbound.values())!=set(runtime_by_email): stop("外部修改后的 client 与路由用户不一致")
    old_records={str(x.get("tag","")):x for x in state_proxies}
    meta_by_outbound={}
    for tag,email in route_email_by_outbound.items():
        old=state_meta_by_outbound.get(tag,{})
        record=old_records.get(tag,{})
        default_name="native" if tag=="direct" else tag
        meta_by_outbound[tag]={"name":str(old.get("name") or record.get("name") or default_name),"uuid":str(runtime_by_email[email]["id"]),"email":email,"outbound":tag,"resolution":old.get("resolution")}
else:
    meta_by_outbound=state_meta_by_outbound
    if set(meta_by_outbound)!={"direct",*proxy_tags}: stop("state clients 与受管出口不一致")
    if set(runtime_by_email)!={str(x.get("email","")) for x in state_clients}: stop("live VLESS clients 与 state clients 不一致")
if version==3 and not adopt_live:
    for tag,meta in meta_by_outbound.items():
        email=str(meta.get("email","")); live=runtime_by_email.get(email)
        if live is None or str(meta.get("uuid",""))!=str(live["id"]): stop(f"v3 state client {tag} 与 live UUID 不一致")

def parse_proxy(outbound):
    protocol=outbound.get("protocol"); keys=set(outbound); s=outbound.get("settings")
    if not isinstance(s,dict): stop("ISP 出口 settings 无效")
    if protocol=="socks":
        if keys-{"protocol","tag","settings","targetStrategy"} or set(s)-{"address","port","user","pass"}: stop("SOCKS 出口包含非脚本管理字段")
        strategy=outbound.get("targetStrategy","AsIs")
        if strategy not in {"AsIs","UseIPv4"}: stop("SOCKS targetStrategy 不受支持")
        return {"scheme":"socks5","host":s.get("address"),"port":s.get("port"),"username":s.get("user",""),"password":s.get("pass","")},strategy
    if protocol=="http":
        if keys-{"protocol","tag","settings","streamSettings"} or set(s)-{"address","port","user","pass"}: stop("HTTP 出口包含非脚本管理字段")
        scheme="http"
        if "streamSettings" in outbound:
            expected={"security":"tls","tlsSettings":{"serverName":s.get("address"),"allowInsecure":False}}
            if outbound.get("streamSettings")!=expected: stop("HTTPS TLS 配置不是脚本管理结构")
            scheme="https"
        return {"scheme":scheme,"host":s.get("address"),"port":s.get("port"),"username":s.get("user",""),"password":s.get("pass","")},"AsIs"
    if protocol=="shadowsocks":
        if keys!={"protocol","tag","settings"} or set(s)!={"address","port","method","password"}: stop("Shadowsocks 出口不是脚本管理结构")
        return {"scheme":"ss","host":s.get("address"),"port":s.get("port"),"method":s.get("method"),"password":s.get("password")},"AsIs"
    stop(f"出口协议 {protocol!r} 不受更新器管理")

model_proxies=[]
if adopt_live:
    old_records={str(x.get("tag","")):x for x in state_proxies}
    records_to_load=[]
    for tag in proxy_tags:
        record=dict(old_records.get(tag,{}))
        record.setdefault("tag",tag); record.setdefault("name",meta_by_outbound[tag]["name"]); record.setdefault("id",str(uuid.uuid4())); record.setdefault("resolutionCheck",None)
        records_to_load.append(record)
else:
    records_to_load=state_proxies
for record in records_to_load:
    tag=str(record["tag"]); meta=meta_by_outbound[tag]; email=str(meta.get("email","")); live=runtime_by_email.get(email)
    if live is None: stop(f"出口 {tag} 找不到对应 live client")
    proxy,strategy=parse_proxy(by_tag[tag])
    if not isinstance(proxy.get("host"),str) or not proxy["host"]: stop("ISP 地址为空")
    try: proxy["port"]=int(proxy.get("port"))
    except Exception: stop("ISP 端口无效")
    if not 1<=proxy["port"]<=65535: stop("ISP 端口超出范围")
    resolution=record.get("resolutionCheck")
    if proxy["scheme"]=="socks5" and (not isinstance(resolution,dict) or resolution.get("targetStrategy")!=strategy):
        resolution={"result":"imported-live-config","mode":"xray-ipv4" if strategy=="UseIPv4" else "remote-domain","targetStrategy":strategy,"checkedAt":None,"summary":"从现有 Xray 配置迁移，未重新检测","attempts":[]}
    elif proxy["scheme"]!="socks5": resolution=None
    if version==3 and not adopt_live:
        if record.get("email")!=email or record.get("uuid")!=live["id"] or record.get("name")!=meta.get("name"): stop(f"v3 状态中 {tag} 的稳定身份与 live config 不一致")
        stable_id=record.get("id")
    elif adopt_live: stable_id=record.get("id") or str(uuid.uuid4())
    else: stable_id=f"legacy-{tag}"
    if not isinstance(stable_id,str) or not stable_id: stop(f"出口 {tag} 缺少稳定 ID")
    model_proxies.append({"id":stable_id,"name":str(record.get("name","")),"tag":tag,"email":email,"uuid":str(live["id"]),"proxy":proxy,"resolutionCheck":resolution,"needsProbe":False})
native_meta=meta_by_outbound["direct"]; native_email=str(native_meta.get("email","")); native_live=runtime_by_email.get(native_email)
if native_live is None: stop("找不到 native live client")
if version==3 and not adopt_live:
    native_state=state.get("native")
    expected_native={"name":str(native_meta.get("name","native")),"uuid":str(native_live["id"]),"email":native_email,"outbound":"direct"}
    if native_state!=expected_native: stop("v3 state.native 与 state.clients/live config 不一致")
optional={}
for inbound in inbounds:
    if inbound is reality_inbound or inbound is guard_inbound: continue
    tag=inbound.get("tag"); s=inbound.get("settings",{})
    if tag=="socks-in" and inbound.get("protocol")=="socks":
        users=s.get("users")
        if set(inbound)!={"tag","listen","port","protocol","settings"} or set(s)!={"auth","users","udp"} or s.get("auth")!="password" or s.get("udp") is not False or not isinstance(users,list) or len(users)!=1 or set(users[0])!={"user","pass"}: stop("SOCKS5 入站不是脚本管理结构")
        optional["socks5"]={"listen":str(inbound.get("listen")),"port":int(inbound.get("port")),"username":str(users[0]["user"]),"password":str(users[0]["pass"])}
    elif tag=="shadowsocks-in" and inbound.get("protocol")=="shadowsocks":
        if set(inbound)!={"tag","listen","port","protocol","settings"} or set(s)!={"network","method","password"} or s.get("network")!="tcp,udp": stop("Shadowsocks 入站不是脚本管理结构")
        optional["shadowsocks"]={"listen":str(inbound.get("listen")),"port":int(inbound.get("port")),"method":str(s.get("method")),"password":str(s.get("password"))}
    else: stop("发现非脚本管理的额外入站")
expected=[{"type":"field","user":[str(c["email"])],"outboundTag":str(c["outbound"])} for c in meta_by_outbound.values()]
if guard_enabled:
    expected[0:0]=[
        {"type":"field","inboundTag":["reality-guard-in"],"domain":[f"full:{x}" for x in rs["serverNames"]],"outboundTag":"direct"},
        {"type":"field","inboundTag":["reality-guard-in"],"outboundTag":"reality-guard-block"},
    ]
if "socks5" in optional: expected.append({"type":"field","inboundTag":["socks-in"],"outboundTag":"direct"})
if "shadowsocks" in optional: expected.append({"type":"field","inboundTag":["shadowsocks-in"],"outboundTag":"direct"})
norm=lambda x:json.dumps(x,ensure_ascii=False,sort_keys=True)
if Counter(map(norm,routing["rules"]))!=Counter(map(norm,expected)): stop("routing.rules 与受管 clients/inbounds 不一致")
needs_dns=any((x.get("resolutionCheck") or {}).get("targetStrategy")=="UseIPv4" for x in model_proxies)
expected_dns={"servers":["https+local://1.1.1.1/dns-query"],"queryStrategy":"UseIPv4"}
if needs_dns and config.get("dns")!=expected_dns: stop("UseIPv4 出口需要的共享 DNS 已漂移")
if not needs_dns and "dns" in config: stop("发现非脚本管理 DNS 配置")
sr=state.get("reality",{}); live_reality={"port":int(reality_inbound["port"]),"dest":original_target,"serverNames":[str(x) for x in rs["serverNames"]],"privateKey":str(rs["privateKey"]),"publicKey":str(public_key_override if adopt_live else sr.get("publicKey","")),"shortId":str(rs["shortIds"][0]),"guard":{"enabled":guard_enabled,"port":guard_port or int(sr.get("guard",{}).get("port",39000))}}
if not live_reality["publicKey"]: stop("state.json 缺少 Reality publicKey")
if not adopt_live:
    for field in ("port","dest","serverNames","shortId"):
        if sr.get(field)!=live_reality[field]: stop(f"Reality {field} 在 state 与 live config 间不一致")
    state_guard=sr.get("guard",{"enabled":False,"port":39000})
    if bool(state_guard.get("enabled",False))!=guard_enabled or (guard_enabled and int(state_guard.get("port",0))!=guard_port): stop("Reality 防偷状态在 state 与 live config 间不一致")
    if version==3 and sr.get("privateKey")!=live_reality["privateKey"]: stop("Reality privateKey 在 v3 state 与 live config 间不一致")
names=[str(x.get("name","")) for x in model_proxies]
if not all(names) or len(set(names))!=len(names): stop("ISP 名称为空或重复")
model={"version":3,"managedBy":"vps-manager","nodeName":str(state.get("nodeName","")),"publicAddress":str(state.get("publicAddress","")),"reality":live_reality,"native":{"name":str(native_meta.get("name","native")),"uuid":str(native_live["id"]),"email":native_email,"outbound":"direct"},"proxies":model_proxies,"optionalInbounds":optional}
if not model["nodeName"] or not model["publicAddress"]: stop("state.json 缺少节点名称或客户端连接地址")
destination.write_text(json.dumps(model,ensure_ascii=False,indent=2)+"\n"); os.chmod(destination,0o600)
PY
}


pending_model_query() {
  local path="$1"
  python3 - "${XRAY_PENDING_MODEL}" "${path}" <<'PY'
import json, sys
value=json.load(open(sys.argv[1]))
for part in sys.argv[2].split("."): value=value[int(part)] if isinstance(value,list) else value[part]
if isinstance(value,bool): print("1" if value else "0")
elif value is None: print("")
elif isinstance(value,(dict,list)): print(json.dumps(value,ensure_ascii=False))
else: print(value)
PY
}

pending_model_mutate() {
  local action="$1"; shift
  if python3 - "${XRAY_PENDING_MODEL}" "${action}" "$@" <<'PY'
from __future__ import annotations
import json, os, re, sys, uuid
from pathlib import Path
path=Path(sys.argv[1]); action=sys.argv[2]; args=sys.argv[3:]; model=json.loads(path.read_text())
def unique_name(name,skip=None):
    if not name: raise SystemExit("ISP 名称不能为空")
    if any(i!=skip and x["name"]==name for i,x in enumerate(model["proxies"])): raise SystemExit("ISP 名称不能重复")
if action=="set":
    field,value=args
    allowed={"nodeName","publicAddress","reality.port","reality.dest","reality.serverNames","reality.privateKey","reality.publicKey","reality.shortId"}
    if field not in allowed: raise SystemExit("不允许更新该字段")
    if field=="nodeName": model["nodeName"]=value
    elif field=="publicAddress": model["publicAddress"]=value
    elif field=="reality.port": model["reality"]["port"]=int(value)
    elif field=="reality.serverNames":
        values=list(dict.fromkeys(x.strip() for x in value.split(",") if x.strip()))
        if not values: raise SystemExit("serverNames 不能为空")
        model["reality"]["serverNames"]=values
    else: model["reality"][field.split(".",1)[1]]=value
elif action=="proxy-add":
    name,link=args; unique_name(name); used=[]
    for item in model["proxies"]:
        m=re.fullmatch(r"proxy_([0-9]+)",item["tag"])
        if m: used.append(int(m.group(1)))
    number=max(used,default=0)+1
    model["proxies"].append({"id":str(uuid.uuid4()),"name":name,"tag":f"proxy_{number}","email":f"proxy-{number}@vps-manager.local","uuid":str(uuid.uuid4()),"sourceLink":link,"resolutionCheck":None,"needsProbe":True})
elif action=="proxy-name":
    index,name=int(args[0]),args[1]; unique_name(name,index); model["proxies"][index]["name"]=name
elif action=="proxy-link":
    index,link=int(args[0]),args[1]; item=model["proxies"][index]; item.pop("proxy",None); item["sourceLink"]=link; item["resolutionCheck"]=None; item["needsProbe"]=True
elif action=="proxy-delete": del model["proxies"][int(args[0])]
elif action=="proxy-retest":
    item=model["proxies"][int(args[0])]
    if item.get("proxy",{}).get("scheme")!="socks5" and not item.get("sourceLink"): raise SystemExit("只有 SOCKS5 出口需要域名能力检测")
    item["needsProbe"]=True
elif action=="inbound-enable":
    kind=args[0]
    if kind=="socks5": model["optionalInbounds"][kind]={"listen":args[1],"port":int(args[2]),"username":args[3],"password":args[4]}
    elif kind=="shadowsocks": model["optionalInbounds"][kind]={"listen":args[1],"port":int(args[2]),"method":args[3],"password":args[4]}
    else: raise SystemExit("未知入站类型")
elif action=="inbound-set":
    kind,field,value=args
    if kind not in model["optionalInbounds"]: raise SystemExit("该入站尚未开启")
    model["optionalInbounds"][kind][field]=int(value) if field=="port" else value
elif action=="inbound-disable": model["optionalInbounds"].pop(args[0],None)
elif action=="rotate-uuid":
    if args[0]=="native": model["native"]["uuid"]=str(uuid.uuid4())
    else: model["proxies"][int(args[0])]["uuid"]=str(uuid.uuid4())
elif action=="reality-key": model["reality"].update({"privateKey":args[0],"publicKey":args[1]})
elif action=="short-id": model["reality"]["shortId"]=args[0]
elif action=="reality-guard":
    guard=model["reality"].setdefault("guard",{"enabled":True,"port":39000})
    guard["enabled"]=args[0]=="1"
else: raise SystemExit("未知模型操作")
tmp=path.with_name(path.name+".new"); tmp.write_text(json.dumps(model,ensure_ascii=False,indent=2)+"\n"); os.chmod(tmp,0o600); os.replace(tmp,path)
PY
  then
    XRAY_UPDATE_DIRTY=1
    XRAY_CANDIDATE_READY=0
  else
    warn "输入无效，待更新配置没有变化。"
  fi
  return 0
}

validate_pending_model() {
  python3 - "${XRAY_PENDING_MODEL}" <<'PY'
import json,re,sys,uuid
model=json.load(open(sys.argv[1]))
if model.get("version")!=3 or model.get("managedBy")!="vps-manager": raise SystemExit("待更新模型不是 v3 受管结构")
for field in ("nodeName","publicAddress"):
    if not isinstance(model.get(field),str) or not model[field].strip(): raise SystemExit(f"{field} 不能为空")
r=model.get("reality",{})
for field in ("dest","privateKey","publicKey","shortId"):
    if not isinstance(r.get(field),str) or not r[field]: raise SystemExit(f"Reality {field} 不能为空")
if " " in r["dest"]: raise SystemExit("Reality dest 不能包含空格")
if not isinstance(r.get("serverNames"),list) or not all(isinstance(x,str) and x for x in r["serverNames"]): raise SystemExit("Reality serverNames 无效")
if not re.fullmatch(r"[0-9a-fA-F]+",r["shortId"]) or len(r["shortId"])%2: raise SystemExit("Reality Short ID 必须是偶数长度十六进制")
try: ports=[int(r.get("port"))]
except Exception: raise SystemExit("Reality 端口无效")
if not 1<=ports[0]<=65535: raise SystemExit("Reality 端口超出范围")
guard=r.get("guard",{"enabled":True,"port":39000})
if not isinstance(guard,dict) or not isinstance(guard.get("enabled"),bool): raise SystemExit("Reality 防偷状态无效")
try: guard_port=int(guard.get("port",39000))
except Exception: raise SystemExit("Reality 防偷端口无效")
if not 39000<=guard_port<=59999: raise SystemExit("Reality 防偷端口必须在 39000-59999")
if guard.get("enabled"): ports.append(guard_port)
ids={k:[] for k in ("tag","email","uuid","id")}; names=[]
for item in model.get("proxies",[]):
    names.append(item.get("name"))
    for key in ids: ids[key].append(item.get(key))
    if not item.get("sourceLink") and not isinstance(item.get("proxy"),dict): raise SystemExit("ISP 出口缺少受管输入")
for key,values in ids.items():
    if not all(isinstance(x,str) and x for x in values) or len(set(values))!=len(values): raise SystemExit(f"ISP {key} 缺失或重复")
for value in [model["native"]["uuid"],*ids["uuid"]]:
    try: uuid.UUID(value)
    except Exception: raise SystemExit("client UUID 无效")
if not all(isinstance(x,str) and x for x in names) or len(set(names))!=len(names): raise SystemExit("ISP 名称为空或重复")
for kind,item in model.get("optionalInbounds",{}).items():
    if kind not in {"socks5","shadowsocks"}: raise SystemExit("存在未知可选入站")
    try: port=int(item.get("port",0))
    except Exception: raise SystemExit(f"{kind} 端口无效")
    if not 1<=port<=65535: raise SystemExit(f"{kind} 端口无效")
    ports.append(port)
    if not item.get("listen") or not item.get("password"): raise SystemExit(f"{kind} 监听地址或密码为空")
    if kind=="socks5" and not item.get("username"): raise SystemExit("SOCKS5 用户名为空")
    if kind=="shadowsocks" and not item.get("method"): raise SystemExit("Shadowsocks 加密方式为空")
if len(ports)!=len(set(ports)): raise SystemExit("Reality、防偷辅助入站、SOCKS5 和 Shadowsocks 端口不能重复")
PY
}

show_pending_xray_summary() {
  python3 - "${XRAY_PENDING_MODEL}" <<'PY'
import json,sys
m=json.load(open(sys.argv[1])); r=m["reality"]; o=m["optionalInbounds"]
print(f"节点：{m['nodeName']}  客户端地址：{m['publicAddress']}")
print(f"Reality：{r['port']} -> {r['dest']}  serverNames={','.join(r['serverNames'])}")
g=r.get('guard',{'enabled':True,'port':39000})
print("Reality 防偷："+(f"开启（127.0.0.1:{g['port']}，full: 精确匹配）" if g.get('enabled') else "关闭"))
print(f"ISP 出口：{len(m['proxies'])} 个")
print("SOCKS5 入站："+(f"{o['socks5']['listen']}:{o['socks5']['port']}" if "socks5" in o else "关闭"))
print("Shadowsocks 入站："+(f"{o['shadowsocks']['listen']}:{o['shadowsocks']['port']}" if "shadowsocks" in o else "关闭"))
PY
}

list_pending_proxies() {
  python3 - "${XRAY_PENDING_MODEL}" <<'PY'
import json,sys
m=json.load(open(sys.argv[1]))
if not m["proxies"]: print("  （无 ISP 出口）")
for i,item in enumerate(m["proxies"],1):
    p=item.get("proxy") or {}; print(f"  {i}) {item['name']} [{p.get('scheme','待解析')}] {p.get('host','新链接')}:{p.get('port','')} tag={item['tag']}")
PY
}


update_node_info_menu() {
  local choice current value
  while true; do
    printf '\n节点与客户端 YAML 信息：\n  1) 节点名称：%s\n  2) 客户端连接地址：%s\n  0) 返回\n' "$(pending_model_query nodeName)" "$(pending_model_query publicAddress)"
    read -r -p "请选择 [0]: " choice
    case "${choice:-0}" in
      1) current="$(pending_model_query nodeName)"; value="$(prompt_default "新节点名称" "${current}")"; [[ "${value}" == "${current}" ]] || pending_model_mutate set nodeName "${value}" ;;
      2) current="$(pending_model_query publicAddress)"; value="$(prompt_default "新公网 IP 或域名（仅用于客户端 YAML）" "${current}")"; [[ "${value}" == "${current}" ]] || pending_model_mutate set publicAddress "${value}" ;;
      0) return 0;; *) warn "未知选项。";;
    esac
  done
}

update_reality_menu() {
  local choice current value normalized_value key_pair private_key public_key guard_label
  while true; do
    current="$(pending_model_query reality.guard.enabled 2>/dev/null || printf 1)"
    [[ "${current}" == 1 ]] && guard_label="开启" || guard_label="关闭"
    printf '\nReality 更新：\n  1) 端口：%s\n  2) target：%s\n  3) serverNames\n  4) 轮换密钥对\n  5) 轮换 Short ID\n  6) 切换 Reality 防偷（当前：%s）\n  0) 返回\n' "$(pending_model_query reality.port)" "$(pending_model_query reality.dest)" "${guard_label}"
    read -r -p "请选择 [0]: " choice
    case "${choice:-0}" in
      1) current="$(pending_model_query reality.port)"; while true; do value="$(prompt_default "新 Reality 端口" "${current}")"; validate_port "${value}" && break; warn "端口必须在 1-65535 之间。"; done; [[ "${value}" == "${current}" ]] || pending_model_mutate set reality.port "${value}";;
      2) current="$(pending_model_query reality.dest)"; value="$(prompt_default "新 Reality target（裸域名/IP 自动补全 :443）" "${current}")"; if ! normalized_value="$(normalize_reality_target "${value}")"; then warn "Reality target 格式无效。"; continue; fi; [[ "${normalized_value}" == "${value}" ]] || printf '已自动补全 Reality target：%s\n' "${normalized_value}"; [[ "${normalized_value}" == "${current}" ]] || pending_model_mutate set reality.dest "${normalized_value}";;
      3) current="$(python3 - "${XRAY_PENDING_MODEL}" <<'PY'
import json,sys
print(",".join(json.load(open(sys.argv[1]))["reality"]["serverNames"]))
PY
)"; value="$(prompt_default "新 serverNames（逗号分隔）" "${current}")"; [[ "${value}" == "${current}" ]] || pending_model_mutate set reality.serverNames "${value}";;
      4) prompt_yes_no "轮换密钥会要求所有客户端更新，确认继续" "0" || continue; [[ "${DEMO_MODE}" == 1 ]] && { warn "预览模式不生成真实 Reality 密钥。"; continue; }; key_pair="$(generate_reality_keys)"; private_key="${key_pair%%$'\t'*}"; public_key="${key_pair#*$'\t'}"; pending_model_mutate reality-key "${private_key}" "${public_key}";;
      5) prompt_yes_no "轮换 Short ID 会要求所有客户端更新，确认继续" "0" || continue; pending_model_mutate short-id "$(openssl rand -hex 8)";;
      6) current="$(pending_model_query reality.guard.enabled 2>/dev/null || printf 1)"; [[ "${current}" == 1 ]] && pending_model_mutate reality-guard 0 || pending_model_mutate reality-guard 1;;
      0) return 0;; *) warn "未知选项。";;
    esac
  done
}

manage_isp_outbounds_menu() {
  local choice selected index subchoice name link current count
  while true; do
    printf '\nISP 出口：\n'; list_pending_proxies
    printf '  a) 增加出口\n  e) 编辑出口\n  d) 删除出口\n  r) 重新检测 SOCKS5 出口\n  0) 返回\n'
    read -r -p "请选择 [0]: " choice
    case "${choice:-0}" in
      a|A) count="$(python3 - "${XRAY_PENDING_MODEL}" <<'PY'
import json,sys
print(len(json.load(open(sys.argv[1]))["proxies"])+1)
PY
)"; name="$(prompt_default "出口名称" "isp-${count}")"; link="$(prompt_secret "粘贴代理链接")"; [[ -n "${link}" ]] || { warn "代理链接不能为空。"; continue; }; pending_model_mutate proxy-add "${name}" "${link}";;
      e|E)
        read -r -p "要编辑的编号: " selected; [[ "${selected}" =~ ^[0-9]+$ ]] || { warn "编号无效。"; continue; }; index=$((selected-1)); name="$(pending_model_query "proxies.${index}.name" 2>/dev/null || true)"; [[ -n "${name}" ]] || { warn "编号不存在。"; continue; }
        printf '  1) 修改名称（保留 UUID/tag/email）\n  2) 替换链接（保留 UUID/tag/email）\n  0) 返回\n'; read -r -p "请选择 [0]: " subchoice
        case "${subchoice:-0}" in
          1) current="${name}"; name="$(prompt_default "新出口名称" "${current}")"; [[ "${name}" == "${current}" ]] || pending_model_mutate proxy-name "${index}" "${name}";;
          2) link="$(prompt_secret "粘贴新的代理链接")"; [[ -n "${link}" ]] || { warn "链接为空，保持原样。"; continue; }; pending_model_mutate proxy-link "${index}" "${link}";;
        esac;;
      d|D) read -r -p "要删除的编号: " selected; [[ "${selected}" =~ ^[0-9]+$ ]] || { warn "编号无效。"; continue; }; index=$((selected-1)); name="$(pending_model_query "proxies.${index}.name" 2>/dev/null || true)"; [[ -n "${name}" ]] || { warn "编号不存在。"; continue; }; prompt_yes_no "确认删除出口 ${name}；其他出口身份不会改变" 0 && pending_model_mutate proxy-delete "${index}";;
      r|R) read -r -p "要重新检测的编号: " selected; [[ "${selected}" =~ ^[0-9]+$ ]] || { warn "编号无效。"; continue; }; index=$((selected-1)); name="$(pending_model_query "proxies.${index}.name" 2>/dev/null || true)"; [[ -n "${name}" ]] || { warn "编号不存在。"; continue; }; pending_model_mutate proxy-retest "${index}";;
      0) return 0;; *) warn "未知选项。";;
    esac
  done
}

manage_socks_inbound_menu() {
  local choice current value listen port user password
  while true; do
    if ! current="$(pending_model_query optionalInbounds.socks5.port 2>/dev/null)"; then
      printf '\nSOCKS5 入站当前关闭。\n  1) 开启\n  0) 返回\n'; read -r -p "请选择 [0]: " choice
      case "${choice:-0}" in 1) listen="$(prompt_default "监听地址" 127.0.0.1)"; while true; do port="$(prompt_default "端口" 21625)"; validate_port "${port}" && break; warn "端口无效。"; done; user="$(prompt_default "用户名" xray-socks)"; password="$(prompt_secret "密码（留空自动生成）")"; [[ -n "${password}" ]] || password="$(random_password)"; pending_model_mutate inbound-enable socks5 "${listen}" "${port}" "${user}" "${password}";; 0) return 0;; esac; continue
    fi
    printf '\nSOCKS5 入站：\n  1) 监听地址\n  2) 端口\n  3) 用户名\n  4) 替换密码\n  5) 关闭\n  0) 返回\n'; read -r -p "请选择 [0]: " choice
    case "${choice:-0}" in
      1) current="$(pending_model_query optionalInbounds.socks5.listen)"; value="$(prompt_default "监听地址" "${current}")"; [[ "${value}" == "${current}" ]] || pending_model_mutate inbound-set socks5 listen "${value}";;
      2) current="$(pending_model_query optionalInbounds.socks5.port)"; while true; do value="$(prompt_default "端口" "${current}")"; validate_port "${value}" && break; warn "端口无效。"; done; [[ "${value}" == "${current}" ]] || pending_model_mutate inbound-set socks5 port "${value}";;
      3) current="$(pending_model_query optionalInbounds.socks5.username)"; value="$(prompt_default "用户名" "${current}")"; [[ "${value}" == "${current}" ]] || pending_model_mutate inbound-set socks5 username "${value}";;
      4) value="$(prompt_secret "新密码（留空保持原样）")"; [[ -z "${value}" ]] || pending_model_mutate inbound-set socks5 password "${value}";;
      5) prompt_yes_no "确认关闭 SOCKS5 入站" 0 && pending_model_mutate inbound-disable socks5;; 0) return 0;; *) warn "未知选项。";;
    esac
  done
}

manage_ss_inbound_menu() {
  local choice current value listen port method password
  while true; do
    if ! current="$(pending_model_query optionalInbounds.shadowsocks.port 2>/dev/null)"; then
      printf '\nShadowsocks 入站当前关闭。\n  1) 开启\n  0) 返回\n'; read -r -p "请选择 [0]: " choice
      case "${choice:-0}" in 1) listen="$(prompt_default "监听地址" 0.0.0.0)"; while true; do port="$(prompt_default "端口" 21626)"; validate_port "${port}" && break; warn "端口无效。"; done; method="$(prompt_default "加密方式" 2022-blake3-aes-128-gcm)"; password="$(prompt_secret "密码/PSK（留空自动生成）")"; [[ -n "${password}" ]] || password="$(shadowsocks_password_for_method "${method}")"; pending_model_mutate inbound-enable shadowsocks "${listen}" "${port}" "${method}" "${password}";; 0) return 0;; esac; continue
    fi
    printf '\nShadowsocks 入站：\n  1) 监听地址\n  2) 端口\n  3) 加密方式\n  4) 替换密码\n  5) 关闭\n  0) 返回\n'; read -r -p "请选择 [0]: " choice
    case "${choice:-0}" in
      1) current="$(pending_model_query optionalInbounds.shadowsocks.listen)"; value="$(prompt_default "监听地址" "${current}")"; [[ "${value}" == "${current}" ]] || pending_model_mutate inbound-set shadowsocks listen "${value}";;
      2) current="$(pending_model_query optionalInbounds.shadowsocks.port)"; while true; do value="$(prompt_default "端口" "${current}")"; validate_port "${value}" && break; warn "端口无效。"; done; [[ "${value}" == "${current}" ]] || pending_model_mutate inbound-set shadowsocks port "${value}";;
      3) current="$(pending_model_query optionalInbounds.shadowsocks.method)"; value="$(prompt_default "加密方式" "${current}")"; if [[ "${value}" != "${current}" ]]; then password="$(prompt_secret "新密码/PSK（留空按新加密方式自动生成）")"; [[ -n "${password}" ]] || password="$(shadowsocks_password_for_method "${value}")"; pending_model_mutate inbound-set shadowsocks method "${value}"; pending_model_mutate inbound-set shadowsocks password "${password}"; fi;;
      4) value="$(prompt_secret "新密码（留空保持原样）")"; [[ -z "${value}" ]] || pending_model_mutate inbound-set shadowsocks password "${value}";;
      5) prompt_yes_no "确认关闭 Shadowsocks 入站" 0 && pending_model_mutate inbound-disable shadowsocks;; 0) return 0;; *) warn "未知选项。";;
    esac
  done
}

manage_xray_credentials_menu() {
  local choice selected index name key_pair private_key public_key
  while true; do
    printf '\n高级凭据：\n  1) 轮换 native UUID\n  2) 轮换指定 ISP UUID\n  3) 轮换 Reality 密钥对\n  4) 轮换 Reality Short ID\n  0) 返回\n'; read -r -p "请选择 [0]: " choice
    case "${choice:-0}" in
      1) prompt_yes_no "确认轮换 native UUID" 0 && pending_model_mutate rotate-uuid native;;
      2) list_pending_proxies; read -r -p "要轮换 UUID 的编号: " selected; [[ "${selected}" =~ ^[0-9]+$ ]] || { warn "编号无效。"; continue; }; index=$((selected-1)); name="$(pending_model_query "proxies.${index}.name" 2>/dev/null || true)"; [[ -n "${name}" ]] || { warn "编号不存在。"; continue; }; prompt_yes_no "确认轮换 ${name} 的 UUID" 0 && pending_model_mutate rotate-uuid "${index}";;
      3) prompt_yes_no "确认轮换 Reality 密钥；所有 YAML 节点都需要更新" 0 || continue; [[ "${DEMO_MODE}" == 1 ]] && { warn "预览模式不生成真实 Reality 密钥。"; continue; }; key_pair="$(generate_reality_keys)"; private_key="${key_pair%%$'\t'*}"; public_key="${key_pair#*$'\t'}"; pending_model_mutate reality-key "${private_key}" "${public_key}";;
      4) prompt_yes_no "确认轮换 Short ID；所有 YAML 节点都需要更新" 0 && pending_model_mutate short-id "$(openssl rand -hex 8)";;
      0) return 0;; *) warn "未知选项。";;
    esac
  done
}


prepare_xray_candidate() {
  local proxy_input generated

  if [[ "${XRAY_CANDIDATE_READY}" == 1 ]]; then
    for generated in "${XRAY_CANDIDATE_CONFIG}" "${XRAY_CANDIDATE_STATE}" "${XRAY_CANDIDATE_INFO}" "${XRAY_CANDIDATE_YAML}"; do
      [[ -s "${generated}" ]] || XRAY_CANDIDATE_READY=0
    done
    [[ "${XRAY_CANDIDATE_READY}" == 1 ]] && return 0
  fi

  validate_pending_model || return 1
  proxy_input="${WORK_DIR}/update-empty-proxies.tsv"
  install -m 600 /dev/null "${proxy_input}" || return 1
  rm -f -- "${XRAY_CANDIDATE_CONFIG}" "${XRAY_CANDIDATE_STATE}" "${XRAY_CANDIDATE_INFO}" "${XRAY_CANDIDATE_YAML}"
  if ! generate_xray_files "" "" "" "${proxy_input}" \
    "${XRAY_CANDIDATE_CONFIG}" "${XRAY_CANDIDATE_STATE}" \
    "${XRAY_CANDIDATE_INFO}" "${XRAY_CANDIDATE_YAML}" \
    "${XRAY_PENDING_MODEL}"; then
    warn "候选配置生成失败，系统配置没有变化。"
    return 1
  fi
  for generated in "${XRAY_CANDIDATE_CONFIG}" "${XRAY_CANDIDATE_STATE}" "${XRAY_CANDIDATE_INFO}" "${XRAY_CANDIDATE_YAML}"; do
    [[ -s "${generated}" ]] || {
      warn "候选文件不完整：${generated}"
      return 1
    }
  done
  install -m 600 "${XRAY_CANDIDATE_STATE}" "${XRAY_PENDING_MODEL}" || return 1
  XRAY_CANDIDATE_READY=1
}

validate_candidate_as_service_user() {
  local service_user service_group staged=""
  [[ "${DEMO_MODE}" == 1 ]] && return 0
  service_user="$(xray_service_user)" || return 1
  id "${service_user}" >/dev/null 2>&1 || {
    warn "Xray 服务用户不存在：${service_user}"
    return 1
  }
  service_group="$(id -gn "${service_user}")" || return 1
  staged="$(mktemp_json "$(dirname "${XRAY_CONFIG}")" .vps-manager-check)" || return 1
  if ! install -o root -g "${service_group}" -m 640 "${XRAY_CANDIDATE_CONFIG}" "${staged}"; then
    rm -f -- "${staged}"
    return 1
  fi
  if ! validate_xray_config "${staged}"; then
    rm -f -- "${staged}"
    return 1
  fi
  rm -f -- "${staged}" || return 1
}

preview_xray_candidate() {
  prepare_xray_candidate || return 1
  validate_candidate_as_service_user || return 1
  warn "以下是完整 config.json，包含 privateKey 和代理密码，请勿公开。"
  printf '\n----- 完整候选 config.json -----\n'
  cat "${XRAY_CANDIDATE_CONFIG}" || return 1
  printf '%s\n' '----- 候选 config.json 结束 -----'
}

backup_xray_bundle() {
  local timestamp destination key target
  install -d -m 700 "${BACKUP_ROOT}" || return 1
  timestamp="$(date -u '+%Y%m%dT%H%M%SZ')" || return 1
  destination="$(mktemp -d "${BACKUP_ROOT}/xray-bundle-${timestamp}.XXXXXX")" || return 1
  chmod 700 "${destination}" || return 1
  while IFS='|' read -r key target; do
    if [[ -e "${target}" ]]; then
      cp -a -- "${target}" "${destination}/${key}" || return 1
    else
      install -m 600 /dev/null "${destination}/.missing-${key}" || return 1
    fi
  done <<EOF
config|${XRAY_CONFIG}
state|${STATE_FILE}
info|${INFO_FILE}
yaml|${YAML_FILE}
EOF
  printf '%s' "${destination}"
}

rollback_xray_bundle() {
  local bundle="$1" key target restore_failed=0
  while IFS='|' read -r key target; do
    if [[ -e "${bundle}/${key}" ]]; then
      cp -a -- "${bundle}/${key}" "${target}" || restore_failed=1
    elif [[ -e "${bundle}/.missing-${key}" ]]; then
      rm -f -- "${target}" || restore_failed=1
    else
      restore_failed=1
    fi
  done <<EOF
config|${XRAY_CONFIG}
state|${STATE_FILE}
info|${INFO_FILE}
yaml|${YAML_FILE}
EOF
  if [[ "${restore_failed}" != 0 ]]; then
    warn "严重错误：统一备份恢复不完整，请立即检查 ${bundle}。"
    return 1
  fi
  if service_restart xray && service_is_active xray; then
    warn "应用失败，已恢复 config/state/info/yaml，旧 Xray 服务已恢复 active。"
    return 0
  fi
  warn "严重错误：文件已恢复，但旧 Xray 服务未恢复 active，请立即检查。"
  return 1
}

apply_xray_candidate() {
  local service_user service_group bundle="" failed=0
  local staged_config="" staged_state="" staged_info="" staged_yaml=""
  local reality_port socks_port socks_listen ss_port

  preview_xray_candidate || {
    warn "候选预览或校验失败，系统配置没有变化。"
    return 1
  }
  if [[ "${DEMO_MODE}" == 1 ]]; then
    DEMO_CONFIG_FILE="${XRAY_CANDIDATE_CONFIG}"; DEMO_STATE_FILE="${XRAY_CANDIDATE_STATE}"; DEMO_INFO_FILE="${XRAY_CANDIDATE_INFO}"; DEMO_YAML_FILE="${XRAY_CANDIDATE_YAML}"
    printf '\n[预览] 不会覆盖系统配置或重启 Xray。\n'; XRAY_UPDATE_DIRTY=0; return 0
  fi
  printf '\n将统一替换以下文件：\n  %s\n  %s\n  %s\n  %s\n' "${XRAY_CONFIG}" "${STATE_FILE}" "${INFO_FILE}" "${YAML_FILE}"
  prompt_yes_no "确认应用以上候选配置并重启 Xray" 0 || { printf '已取消应用；系统配置没有变化，待编辑内容仍保留在当前会话。\n'; return 0; }

  service_user="$(xray_service_user)" || return 1
  service_group="$(id -gn "${service_user}")" || return 1
  install -d -o root -g root -m 700 "${STATE_DIR}" || return 1
  staged_config="$(mktemp_json "$(dirname "${XRAY_CONFIG}")" .config)" || return 1
  staged_state="$(mktemp "${STATE_DIR}/.state.json.XXXXXX")" || { rm -f -- "${staged_config}"; return 1; }
  staged_info="$(mktemp "${STATE_DIR}/.last-install.txt.XXXXXX")" || { rm -f -- "${staged_config}" "${staged_state}"; return 1; }
  staged_yaml="$(mktemp "${STATE_DIR}/.proxies.yaml.XXXXXX")" || { rm -f -- "${staged_config}" "${staged_state}" "${staged_info}"; return 1; }

  if ! install -o root -g "${service_group}" -m 640 "${XRAY_CANDIDATE_CONFIG}" "${staged_config}" \
    || ! install -o root -g root -m 600 "${XRAY_CANDIDATE_STATE}" "${staged_state}" \
    || ! install -o root -g root -m 600 "${XRAY_CANDIDATE_INFO}" "${staged_info}" \
    || ! install -o root -g root -m 600 "${XRAY_CANDIDATE_YAML}" "${staged_yaml}"; then
    rm -f -- "${staged_config}" "${staged_state}" "${staged_info}" "${staged_yaml}"
    warn "候选文件暂存失败，系统配置没有变化。"
    return 1
  fi
  if ! validate_xray_config "${staged_config}"; then
    rm -f -- "${staged_config}" "${staged_state}" "${staged_info}" "${staged_yaml}"
    return 1
  fi
  if ! bundle="$(backup_xray_bundle)" || [[ -z "${bundle}" || ! -d "${bundle}" ]]; then
    rm -f -- "${staged_config}" "${staged_state}" "${staged_info}" "${staged_yaml}"
    warn "统一备份失败，拒绝替换系统配置。"
    return 1
  fi

  mv -f -- "${staged_config}" "${XRAY_CONFIG}" || failed=1
  [[ "${failed}" != 0 ]] || mv -f -- "${staged_state}" "${STATE_FILE}" || failed=1
  [[ "${failed}" != 0 ]] || mv -f -- "${staged_info}" "${INFO_FILE}" || failed=1
  [[ "${failed}" != 0 ]] || mv -f -- "${staged_yaml}" "${YAML_FILE}" || failed=1
  if [[ "${failed}" == 0 ]] && ! service_restart xray; then failed=1; fi
  if [[ "${failed}" == 0 ]] && ! service_is_active xray; then failed=1; fi
  if [[ "${failed}" != 0 ]]; then
    rm -f -- "${staged_config}" "${staged_state}" "${staged_info}" "${staged_yaml}"
    if ! rollback_xray_bundle "${bundle}"; then
      warn "严重错误：候选配置应用失败，且统一备份恢复未完成。"
    fi
    return 1
  fi

  XRAY_UPDATE_DIRTY=0
  log "Xray 更新配置已应用"
  printf '统一备份：%s\n连接参数：%s\nAWS YAML：%s\n' "${bundle}" "${INFO_FILE}" "${YAML_FILE}"
  reality_port="$(pending_model_query reality.port)"
  maybe_open_ufw_port "${reality_port}" "tcp"
  if socks_port="$(pending_model_query optionalInbounds.socks5.port 2>/dev/null)"; then
    socks_listen="$(pending_model_query optionalInbounds.socks5.listen)"
    if [[ "${socks_listen}" != "127.0.0.1" && "${socks_listen}" != "::1" ]]; then
      maybe_open_ufw_port "${socks_port}" "tcp"
    fi
  fi
  if ss_port="$(pending_model_query optionalInbounds.shadowsocks.port 2>/dev/null)"; then
    maybe_open_ufw_port "${ss_port}" "tcp"
    maybe_open_ufw_port "${ss_port}" "udp"
  fi
  warn "若关闭或修改了旧入站端口，已有 UFW 放行规则不会自动删除。"
}

derive_reality_public_key_from_config() {
  local config_source="$1" private_key output public_key
  private_key="$(python3 - "${config_source}" <<'PY'
import json,sys
config=json.load(open(sys.argv[1]))
items=[x for x in config.get("inbounds",[]) if x.get("protocol")=="vless" and x.get("streamSettings",{}).get("security")=="reality"]
if len(items)!=1: raise SystemExit(1)
print(items[0]["streamSettings"]["realitySettings"]["privateKey"])
PY
)" || return 1
  [[ -n "${private_key}" ]] || return 1
  output="$("${XRAY_BIN}" x25519 -i "${private_key}" 2>&1)" || return 1
  public_key="$(printf '%s\n' "${output}" | sed -n -e 's/^Password (PublicKey):[[:space:]]*//p' -e 's/^Public key:[[:space:]]*//p' | head -n 1)"
  [[ -n "${public_key}" ]] || return 1
  printf '%s' "${public_key}"
}

latest_matching_xray_bundle() {
  python3 - "${BACKUP_ROOT}" <<'PY'
import hashlib,json,sys
from pathlib import Path
root=Path(sys.argv[1])
for bundle in sorted(root.glob("xray-bundle-*"),reverse=True):
    config,state=bundle/"config",bundle/"state"
    if not config.is_file() or not state.is_file(): continue
    try:
        text=config.read_text(); metadata=json.loads(state.read_text())
    except Exception: continue
    if metadata.get("configSha256")==hashlib.sha256(text.encode()).hexdigest():
        print(bundle); break
PY
}

xray_update_workflow() {
  local choice source_config source_state update_dir recovery_choice bundle="" public_key=""
  require_root; check_supported_os; command -v python3 >/dev/null 2>&1 || die "需要 python3。"; command -v curl >/dev/null 2>&1 || die "需要 curl。"
  if [[ "${DEMO_MODE}" == 1 ]]; then
    [[ -r "${DEMO_CONFIG_FILE}" && -r "${DEMO_STATE_FILE}" ]] || die "预览模式下请先在当前会话生成一次 Xray 配置。"
    source_config="${DEMO_CONFIG_FILE}"
    source_state="${DEMO_STATE_FILE}"
    update_dir="$(mktemp -d "${WORK_DIR}/update.XXXXXX")" || die "无法创建 demo 更新目录。"
  else
    [[ -r "${XRAY_CONFIG}" ]] || die "未找到现有 Xray 配置。"; [[ -r "${STATE_FILE}" ]] || die "未找到 VPS Manager state.json；拒绝更新非受管配置。"; [[ -x "${XRAY_BIN}" ]] || die "尚未安装 Xray。"
    source_config="${XRAY_CONFIG}"
    source_state="${STATE_FILE}"
    ensure_work_dir
    update_dir="${WORK_DIR}"
  fi
  XRAY_PENDING_MODEL="${update_dir}/pending-model.json"; XRAY_CANDIDATE_CONFIG="${update_dir}/candidate-config.json"; XRAY_CANDIDATE_STATE="${update_dir}/candidate-state.json"; XRAY_CANDIDATE_INFO="${update_dir}/candidate-info.txt"; XRAY_CANDIDATE_YAML="${update_dir}/candidate-proxies.yaml"; XRAY_CANDIDATE_READY=0; XRAY_UPDATE_DIRTY=0
  if ! load_xray_model_from_paths "${source_config}" "${source_state}" "${XRAY_PENDING_MODEL}"; then
    if [[ "${DEMO_MODE}" == 1 ]]; then
      warn "预览配置未通过受管结构检查，无法进入更新模式。"
      return 0
    fi
    printf '\n检测到 config.json 与 VPS Manager 状态不一致。\n'
    printf '  1) 找回最近一份指纹匹配的旧受管配置\n'
    printf '  2) 保留当前 config.json，严格校验后以它为新基线\n'
    printf '  0) 取消，不修改任何文件\n'
    read -r -p "请选择 [0]: " recovery_choice
    case "${recovery_choice:-0}" in
      1)
        bundle="$(latest_matching_xray_bundle)"
        if [[ -z "${bundle}" || ! -d "${bundle}" ]]; then
          warn "没有找到 config/state 指纹匹配的完整旧备份，无法自动恢复。"
          return 0
        fi
        printf '将恢复：%s\n' "${bundle}"
        prompt_yes_no "确认恢复旧 config/state/info/yaml 并重启 Xray" 0 || return 0
        rollback_xray_bundle "${bundle}" || return 1
        load_xray_model_from_paths "${XRAY_CONFIG}" "${STATE_FILE}" "${XRAY_PENDING_MODEL}" || {
          warn "旧备份已恢复，但仍未通过受管结构检查。"
          return 1
        }
        ;;
      2)
        validate_xray_config "${XRAY_CONFIG}" || {
          warn "当前 config.json 未通过 Xray 校验，不能接管。"
          return 0
        }
        public_key="$(derive_reality_public_key_from_config "${XRAY_CONFIG}")" || {
          warn "无法从当前 Reality privateKey 派生公钥，不能接管。"
          return 0
        }
        bundle="$(backup_xray_bundle)" || {
          warn "接管前统一备份失败，当前配置没有变化。"
          return 1
        }
        if ! load_xray_model_from_paths "${XRAY_CONFIG}" "${STATE_FILE}" "${XRAY_PENDING_MODEL}" adopt-live "${public_key}"; then
          warn "当前 config.json 不符合可安全接管的脚本结构；已保留原文件，备份位于 ${bundle}。"
          return 0
        fi
        warn "已将当前 live config 载入为更新基线；应用候选配置后才会刷新 state/info/yaml。"
        printf '接管前备份：%s\n' "${bundle}"
        ;;
      0) return 0;;
      *) warn "未知选项，未修改任何文件。"; return 0;;
    esac
  fi
  while true; do
    printf '\n当前待更新配置：\n'; show_pending_xray_summary
    printf '\n  1) 节点名称与客户端地址\n  2) Reality 配置\n  3) ISP 出口增删改\n  4) SOCKS5 入站\n  5) Shadowsocks 入站\n  6) UUID/密钥高级操作\n  7) 预览完整 JSON\n  8) 应用配置\n  0) 返回\n'; read -r -p "请选择 [0]: " choice
    case "${choice:-0}" in
      1) update_node_info_menu;;
      2) update_reality_menu;;
      3) manage_isp_outbounds_menu;;
      4) manage_socks_inbound_menu;;
      5) manage_ss_inbound_menu;;
      6) manage_xray_credentials_menu;;
      7) preview_xray_candidate || warn "候选预览失败，仍可继续修改。";;
      8)
        if apply_xray_candidate; then
          [[ "${XRAY_UPDATE_DIRTY}" == 0 ]] && return 0
        else
          warn "候选配置未应用，仍可继续修改或返回。"
        fi
        ;;
      0)
        if [[ "${XRAY_UPDATE_DIRTY}" == 1 ]]; then
          prompt_yes_no "存在未应用修改，确认丢弃并返回" 0 || continue
        fi
        return 0
        ;;
      *) warn "未知选项。";;
    esac
  done
}

xray_management_menu() {
  local choice
  while true; do
    printf '\nXray 管理：\n  1) 安装或升级 Xray（不改配置）\n  2) 首次生成并应用完整配置\n  3) 更新现有受管配置\n  4) 显示连接参数与 AWS YAML\n  5) 查看 Xray 状态并校验配置\n  0) 返回\n'; read -r -p "请选择 [0]: " choice
    case "${choice:-0}" in
      1) install_or_upgrade_xray;;
      2) if [[ "${DEMO_MODE}" != 1 && -e "${XRAY_CONFIG}" ]]; then prompt_yes_no "现有配置将被完整重建，是否继续" 0 || continue; fi; configure_xray; prompt_yes_no "是否立即显示连接参数和 AWS YAML" 1 && show_connection_info;;
      3) xray_update_workflow;; 4) show_connection_info;;
      5) if [[ -r "${XRAY_CONFIG}" && "${DEMO_MODE}" != 1 ]]; then validate_xray_config "${XRAY_CONFIG}" || true; service_status_text xray | sed -n '1,60p' || true; else warn "当前没有可校验的系统 Xray 配置。"; fi;;
      0) return 0;; *) warn "未知选项。";;
    esac
  done
}


show_connection_info() {
  require_root
  if [[ "${DEMO_MODE}" == "1" ]]; then
    [[ -r "${DEMO_INFO_FILE}" && -r "${DEMO_YAML_FILE}" ]] \
      || die "尚未生成预览配置。"
    cat "${DEMO_INFO_FILE}"
    printf '\n以下内容可直接粘贴到 AWS YAML 的 proxies: 列表：\n\n'
    cat "${DEMO_YAML_FILE}"
    return 0
  fi
  [[ -r "${INFO_FILE}" ]] || die "尚未找到连接信息，请先生成 Xray 配置。"
  [[ -r "${YAML_FILE}" ]] || die "尚未找到 YAML 节点文件，请重新生成 Xray 配置。"
  cat "${INFO_FILE}"
  printf '\n以下内容可直接粘贴到 AWS YAML 的 proxies: 列表：\n\n'
  cat "${YAML_FILE}"
}


add_ssh_public_key() {
  local admin_user admin_home admin_group authorized_keys public_key key_file key_type key_blob
  local fingerprint candidate staged="" backup_dir=""

  require_root
  admin_user="$(default_ssh_admin_user)"
  id "${admin_user}" >/dev/null 2>&1 \
    || { warn "无法识别当前管理用户：${admin_user}"; return 1; }

  admin_home="$(getent passwd "${admin_user}" 2>/dev/null | cut -d: -f6)"
  admin_group="$(id -gn "${admin_user}")"
  [[ "${admin_home}" == /* && "${admin_home}" != "/" ]] \
    || { warn "用户主目录不安全或无效：${admin_home}"; return 1; }
  authorized_keys="${admin_home}/.ssh/authorized_keys"

  read -r -p "粘贴要添加的 SSH 公钥完整一行: " public_key
  public_key="${public_key%$'\r'}"
  ensure_work_dir
  key_file="${WORK_DIR}/public-key-to-add.pub"
  printf '%s\n' "${public_key}" > "${key_file}"
  chmod 600 "${key_file}"

  command -v ssh-keygen >/dev/null 2>&1 \
    || { warn "缺少 ssh-keygen，请先运行初始化安装基础工具。"; return 1; }
  key_type="$(awk '{print $1}' "${key_file}")"
  case "${key_type}" in
    ssh-ed25519|ssh-rsa|ecdsa-sha2-*|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-*@openssh.com) ;;
    *)
      warn "公钥类型或格式不正确，请粘贴 .pub 文件中的完整一行。"
      return 1
      ;;
  esac
  if ! fingerprint="$(ssh-keygen -l -f "${key_file}" 2>/dev/null)"; then
    warn "ssh-keygen 无法验证该公钥。"
    return 1
  fi
  key_blob="$(awk '{print $2}' "${key_file}")"

  printf '管理用户：%s\n写入文件：%s\n公钥指纹：%s\n' \
    "${admin_user}" "${authorized_keys}" "${fingerprint}"
  if [[ "${DEMO_MODE}" == "1" ]]; then
    log "[预览] 将把该公钥添加到 authorized_keys；不会修改端口或登录方式。"
    return 0
  fi

  [[ ! -L "${admin_home}/.ssh" && ! -L "${authorized_keys}" ]] \
    || { warn "检测到 .ssh 或 authorized_keys 是符号链接，已停止以避免写错目标。"; return 1; }

  if [[ -f "${authorized_keys}" ]] \
    && awk -v blob="${key_blob}" '$2 == blob { found=1 } END { exit !found }' "${authorized_keys}"; then
    printf '该公钥已存在，无需重复写入。\n'
    return 0
  fi
  prompt_yes_no "确认把该公钥添加到 ${admin_user} 的 authorized_keys" "0" \
    || { printf '已取消，系统没有变化。\n'; return 0; }

  install -d -o "${admin_user}" -g "${admin_group}" -m 700 "${admin_home}/.ssh" \
    || { warn "无法创建或修正 ${admin_home}/.ssh。"; return 1; }
  candidate="${WORK_DIR}/authorized_keys.new"
  if [[ -f "${authorized_keys}" ]]; then
    cp -a -- "${authorized_keys}" "${candidate}" \
      || { warn "无法读取现有 authorized_keys。"; return 1; }
    backup_dir="$(backup_file "${authorized_keys}" "authorized-keys")" \
      || { warn "无法备份现有 authorized_keys。"; return 1; }
  else
    : > "${candidate}"
  fi
  printf '%s\n' "${public_key}" >> "${candidate}"

  staged="$(mktemp "${admin_home}/.ssh/.authorized_keys.XXXXXX")" \
    || { warn "无法创建 authorized_keys 临时文件。"; return 1; }
  if ! install -o "${admin_user}" -g "${admin_group}" -m 600 "${candidate}" "${staged}"; then
    rm -f -- "${staged}"
    warn "无法准备新的 authorized_keys。"
    return 1
  fi
  if ! mv -f -- "${staged}" "${authorized_keys}"; then
    rm -f -- "${staged}"
    warn "无法替换 authorized_keys，原文件未改变。"
    return 1
  fi

  log "公钥已添加到 ${authorized_keys}"
  [[ -n "${backup_dir}" ]] && printf '原文件备份：%s\n' "${backup_dir}"
}

generate_local_ssh_key() {
  local admin_user admin_home admin_group key_suffix key_name key_comment
  local private_key public_key ssh_config shortcut_name shortcut_host shortcut_user shortcut_port
  local candidate staged
  local -a keygen_cmd

  admin_user="$(default_ssh_admin_user)"
  id "${admin_user}" >/dev/null 2>&1 \
    || { warn "无法识别当前管理用户：${admin_user}"; return 1; }
  admin_home="$(getent passwd "${admin_user}" 2>/dev/null | cut -d: -f6)"
  admin_group="$(id -gn "${admin_user}")"
  [[ "${admin_home}" == /* && "${admin_home}" != "/" ]] \
    || { warn "用户主目录不安全或无效：${admin_home}"; return 1; }

  key_suffix="$(prompt_default "密钥文件名后缀（将生成 id_ed25519_后缀）" "vps-manager")"
  key_comment="$(prompt_default "密钥备注" "vps-manager")"
  if [[ ! "${key_suffix}" =~ ^[A-Za-z0-9._-]+$ \
    || "${key_suffix}" == "." || "${key_suffix}" == ".." ]] \
    || (( ${#key_suffix} > 80 )); then
    warn "密钥文件名后缀无效。只能使用英文字母、数字、点、下划线和连字符，最长 80 个字符。"
    return 1
  fi

  key_name="id_ed25519_${key_suffix}"
  private_key="${admin_home}/.ssh/${key_name}"
  public_key="${private_key}.pub"
  if [[ -e "${private_key}" || -e "${public_key}" ]]; then
    warn "密钥文件已经存在，为避免覆盖已停止：${private_key}"
    return 1
  fi
  command -v ssh-keygen >/dev/null 2>&1 \
    || { warn "缺少 ssh-keygen，请先运行初始化安装基础工具。"; return 1; }

  if [[ "${EUID}" -eq 0 ]]; then
    install -d -o "${admin_user}" -g "${admin_group}" -m 700 "${admin_home}/.ssh"
  else
    mkdir -p "${admin_home}/.ssh"
    chmod 700 "${admin_home}/.ssh"
  fi

  keygen_cmd=(ssh-keygen -t ed25519 -a 64 -f "${private_key}" -C "${key_comment}")
  if prompt_yes_no "是否为私钥设置密码" "0"; then
    printf '接下来由 ssh-keygen 询问并确认私钥密码。\n'
  else
    keygen_cmd+=(-N "")
  fi

  if [[ "${EUID}" -eq 0 && "${admin_user}" != "root" ]]; then
    command -v runuser >/dev/null 2>&1 \
      || { warn "缺少 runuser，无法以 ${admin_user} 身份生成密钥。"; return 1; }
    runuser -u "${admin_user}" -- "${keygen_cmd[@]}" \
      || { warn "ssh-keygen 执行失败。"; return 1; }
  else
    "${keygen_cmd[@]}" || { warn "ssh-keygen 执行失败。"; return 1; }
  fi

  [[ -f "${private_key}" && -f "${public_key}" ]] \
    || { warn "ssh-keygen 没有生成预期的公钥和私钥。"; return 1; }
  printf '\nSSH 密钥生成完成。\n私钥：%s\n公钥：%s\n\n公钥内容：\n' \
    "${private_key}" "${public_key}"
  cat "${public_key}"
  warn "私钥不要发送给任何人；需要提供给服务器的只能是 .pub 公钥。"

  if ! prompt_yes_no "是否配置本机 SSH 快捷名称（以后可使用 ssh 名称连接）" "0"; then
    return 0
  fi
  ssh_config="${admin_home}/.ssh/config"
  [[ ! -L "${ssh_config}" ]] \
    || { warn "${ssh_config} 是符号链接，为避免写错目标已停止。"; return 1; }
  while true; do
    shortcut_name="$(prompt_default "SSH 快捷名称" "${key_suffix}")"
    if [[ ! "${shortcut_name}" =~ ^[A-Za-z0-9._-]+$ \
      || "${shortcut_name}" == "." || "${shortcut_name}" == ".." ]]; then
      warn "SSH 快捷名称无效。只能使用英文字母、数字、点、下划线和连字符。"
      continue
    fi
    if [[ -f "${ssh_config}" ]] \
      && awk -v target="${shortcut_name}" '
        tolower($1) == "host" {
          for (i = 2; i <= NF; i++) {
            if (tolower($i) == tolower(target)) found = 1
          }
        }
        END { exit !found }
      ' "${ssh_config}"; then
      warn "SSH 快捷名称 ${shortcut_name} 已存在，不会覆盖已有 Host。"
      if prompt_yes_no "是否重新输入其他快捷名称" "1"; then
        continue
      fi
      printf '已取消写入 SSH 快捷配置，现有配置没有变化。\n'
      return 0
    fi
    break
  done
  while true; do
    read -r -p "服务器 IP 或域名: " shortcut_host
    if [[ -n "${shortcut_host}" \
      && "${shortcut_host}" != *[[:space:]]* \
      && "${shortcut_host}" != *"/"* ]]; then
      break
    fi
    warn "服务器地址不能为空，也不能包含空格或斜杠。"
  done
  shortcut_user="$(prompt_default "SSH 用户名" "root")"
  [[ "${shortcut_user}" =~ ^[A-Za-z0-9._-]+$ ]] \
    || { warn "SSH 用户名无效，未写入配置。"; return 1; }
  while true; do
    shortcut_port="$(prompt_default "SSH 端口" "22")"
    validate_port "${shortcut_port}" && break
    warn "SSH 端口必须在 1-65535 之间。"
  done

  ensure_work_dir
  candidate="${WORK_DIR}/ssh-config.new"
  if [[ -f "${ssh_config}" ]]; then
    cp -a -- "${ssh_config}" "${candidate}"
    [[ ! -s "${candidate}" ]] || printf '\n' >> "${candidate}"
  else
    : > "${candidate}"
  fi
  cat >> "${candidate}" <<EOF
Host ${shortcut_name}
    HostName ${shortcut_host}
    User ${shortcut_user}
    Port ${shortcut_port}
    IdentityFile ~/.ssh/${key_name}
    IdentitiesOnly yes
EOF

  staged="$(mktemp "${admin_home}/.ssh/.config.XXXXXX")" \
    || { warn "无法创建 SSH config 临时文件。"; return 1; }
  if [[ "${EUID}" -eq 0 ]]; then
    install -o "${admin_user}" -g "${admin_group}" -m 600 "${candidate}" "${staged}"
  else
    install -m 600 "${candidate}" "${staged}"
  fi
  if ! mv -f -- "${staged}" "${ssh_config}"; then
    rm -f -- "${staged}"
    warn "无法写入 ${ssh_config}。"
    return 1
  fi
  printf 'SSH 快捷名称已写入：%s\n以后可以直接连接：ssh %s\n' \
    "${ssh_config}" "${shortcut_name}"
}

ssh_key_helper_menu() {
  local choice public_key key_file admin_user admin_home authorized_keys
  while true; do
    printf '\nSSH 密钥与加固管理：\n  1) 本机 Linux 生成密钥并可配置快捷名称\n  2) 校验 SSH 公钥并显示指纹\n  3) 配置 SSH 高位端口和仅密钥登录\n  4) 添加公钥到当前管理用户 authorized_keys\n  5) 查看当前管理用户 authorized_keys\n  0) 返回\n'
    read -r -p "请选择 [0]: " choice
    case "${choice:-0}" in
      1)
        generate_local_ssh_key || true
        ;;
      2)
        read -r -p "粘贴 SSH 公钥完整一行: " public_key
        public_key="${public_key%$'\r'}"; ensure_work_dir; key_file="${WORK_DIR}/public-key.pub"
        printf '%s\n' "${public_key}" > "${key_file}"; chmod 600 "${key_file}"
        command -v ssh-keygen >/dev/null 2>&1 || { warn "缺少 ssh-keygen，请先初始化基础工具。"; continue; }
        ssh-keygen -l -f "${key_file}" && printf '公钥有效，可粘贴到 SSH 加固流程。\n' || warn "公钥格式无效。"
        ;;
      3)
        configure_ssh_hardening || true
        ;;
      4)
        add_ssh_public_key || true
        ;;
      5)
        admin_user="$(default_ssh_admin_user)"; admin_home="$(getent passwd "${admin_user}" 2>/dev/null | cut -d: -f6)"
        authorized_keys="${admin_home}/.ssh/authorized_keys"
        printf '管理用户：%s\n文件：%s\n\n' "${admin_user}" "${authorized_keys}"
        [[ -r "${authorized_keys}" ]] && cat "${authorized_keys}" || warn "文件不存在或当前用户无权读取。"
        ;;
      0) return 0 ;;
      *) warn "未知选项。" ;;
    esac
  done
}

ensure_yaml_module() {
  python3 -c 'import yaml' >/dev/null 2>&1 && return 0
  [[ "${DEMO_MODE}" == 1 ]] && { warn "YAML 管理需要 python3-yaml，请先运行初始化。"; return 1; }
  require_root; log "安装 YAML 安全解析组件"; apt_update_safe
  apt-get install -y --no-install-recommends python3-yaml
}


yaml_manager_python() {
  python3 - "$@" <<'PY'
from __future__ import annotations
import base64, copy, re, sys
from pathlib import Path
import yaml

cmd=sys.argv[1]
class Dumper(yaml.SafeDumper):
    def ignore_aliases(self,data): return True
def stop(msg): raise SystemExit(msg)
def load(path):
    try:
        text=Path(path).read_text(encoding="utf-8"); data=yaml.safe_load(text)
    except Exception as exc: stop(f"YAML 读取失败：{exc}")
    if not isinstance(data,dict): stop("YAML 顶层必须是映射")
    return text,data
def check(data):
    ps=data.get("proxies"); gs=data.get("proxy-groups")
    if not isinstance(ps,list) or not isinstance(gs,list): stop("必须包含 proxies 和 proxy-groups 列表")
    pn=[]; gn=[]
    for p in ps:
        if not isinstance(p,dict) or not isinstance(p.get("name"),str) or not p["name"]: stop("存在无效节点")
        pn.append(p["name"])
    if len(pn)!=len(set(pn)): stop("存在重复节点名称")
    for g in gs:
        if not isinstance(g,dict) or not isinstance(g.get("name"),str) or not g["name"]: stop("存在无效分组")
        gn.append(g["name"]); members=g.get("proxies")
        if members is not None and (not isinstance(members,list) or not all(isinstance(x,str) for x in members)): stop(f"分组 {g['name']} 的 proxies 无效")
    if len(gn)!=len(set(gn)): stop("存在重复分组名称")
    known=set(pn)|set(gn)|{"DIRECT","REJECT","REJECT-DROP","PASS","GLOBAL","COMPATIBLE"}
    for g in gs:
        for member in g.get("proxies",[]):
            if member not in known: stop(f"分组 {g['name']} 引用了不存在的项目：{member}")
    return ps,gs
def eligible(gs): return [g for g in gs if isinstance(g.get("proxies"),list)]
def snippet(path):
    try: value=yaml.safe_load(Path(path).read_text(encoding="utf-8"))
    except Exception as exc: stop(f"节点内容解析失败：{exc}")
    nodes=value.get("proxies") if isinstance(value,dict) else value
    if not isinstance(nodes,list) or not nodes: stop("节点内容必须是非空列表或包含 proxies 列表")
    names=[]
    for node in nodes:
        if not isinstance(node,dict) or not isinstance(node.get("name"),str) or not node["name"]: stop("节点 name 无效")
        names.append(node["name"])
    if len(names)!=len(set(names)): stop("待导入节点名称重复")
    return nodes
def replace(text,key,value):
    head=re.search(rf"(?m)^{re.escape(key)}:[^\n]*(?:\n|$)",text)
    if not head: stop(f"缺少顶层 {key}")
    nxt=re.search(r"(?m)^[A-Za-z0-9_.-]+:[^\n]*(?:\n|$)",text[head.end():])
    end=head.end()+nxt.start() if nxt else len(text)
    block=yaml.dump({key:value},Dumper=Dumper,allow_unicode=True,sort_keys=False,width=4096)
    return text[:head.start()]+block+text[end:]
def write(path,text,ps,gs):
    out=replace(replace(text,"proxies",ps),"proxy-groups",gs)
    Path(path).write_text(out,encoding="utf-8",newline="\n")
    _,data=load(path); check(data)
def dec(v): return base64.b64decode(v).decode()

if cmd=="validate":
    _,d=load(sys.argv[2]); ps,gs=check(d); print(f"YAML 有效：{len(ps)} 个节点，{len(gs)} 个分组")
elif cmd=="summary":
    _,d=load(sys.argv[2]); ps,gs=check(d); print(f"节点：{len(ps)}")
    for i,p in enumerate(ps,1): print(f"  {i}) {p['name']}")
    print(f"分组：{len(gs)}")
    for i,g in enumerate(gs,1): print(f"  {i}) {g['name']} ({len(g.get('proxies',[]))} 项)")
elif cmd in {"groups","nodes"}:
    _,d=load(sys.argv[2]); ps,gs=check(d); values=eligible(gs) if cmd=="groups" else ps
    for i,item in enumerate(values,1): print(f"{i}\t{item['name']}")
elif cmd=="snippet-names":
    for node in snippet(sys.argv[2]): print(node["name"])
elif cmd=="recommend":
    _,d=load(sys.argv[2]); _,gs=check(d); gs=eligible(gs); new,old=sys.argv[3:5]
    kind="IDC" if "IDC" in new.upper() else ("ISP" if "ISP" in new.upper() else "")
    suffix=new.rsplit("·",1)[-1] if "·" in new else ""; chosen=[]
    for i,g in enumerate(gs,1):
        if old in g["proxies"] or new in g["proxies"] or (kind and kind in g["name"].upper()) or (suffix and suffix in g["name"]): chosen.append(str(i))
    print(",".join(chosen))
elif cmd=="import":
    target,src,mapfile,out=sys.argv[2:6]; text,d=load(target); ps,gs=check(d); incoming=snippet(src); gl=eligible(gs); maps=[]
    for line in Path(mapfile).read_text(encoding="utf-8").splitlines():
        a,b,c=line.split("\t"); ids=[] if not c else [int(x) for x in c.split(",")]
        if any(x<1 or x>len(gl) for x in ids): stop("分组编号超出范围")
        maps.append((dec(a),dec(b),ids))
    if len(maps)!=len(incoming): stop("节点映射数量不一致")
    for node,(old,new,ids) in zip(incoming,maps):
        if not new: stop("节点名称不能为空")
        positions=[i for i,x in enumerate(ps) if x["name"] in {old,new}]
        if len(positions)>1: stop(f"旧名和新名同时存在：{old} / {new}")
        node=copy.deepcopy(node); node["name"]=new
        if positions: ps[positions[0]]=node
        else: ps.append(node)
        selected_groups={id(gl[i-1]) for i in ids}
        for g in gl:
            g["proxies"]=[new if x==old else x for x in g["proxies"]]
            if id(g) in selected_groups:
                if new not in g["proxies"]: g["proxies"].append(new)
            else: g["proxies"]=[x for x in g["proxies"] if x!=new]
    check(d); write(out,text,ps,gs)
elif cmd=="rename":
    target,num,new,out=sys.argv[2:6]; text,d=load(target); ps,gs=check(d); idx=int(num)-1
    if not 0<=idx<len(ps): stop("节点编号不存在")
    old=ps[idx]["name"]
    if new!=old and any(x["name"]==new for x in ps): stop("新名称已存在")
    ps[idx]["name"]=new
    for g in eligible(gs): g["proxies"]=[new if x==old else x for x in g["proxies"]]
    check(d); write(out,text,ps,gs)
elif cmd=="set-groups":
    target,num,chosen,out=sys.argv[2:6]; text,d=load(target); ps,gs=check(d); idx=int(num)-1; gl=eligible(gs)
    if not 0<=idx<len(ps): stop("节点编号不存在")
    ids=[] if not chosen else [int(x) for x in chosen.split(",")]
    if any(x<1 or x>len(gl) for x in ids): stop("分组编号超出范围")
    name=ps[idx]["name"]; selected_groups={id(gl[i-1]) for i in ids}
    for g in gl:
        if id(g) in selected_groups:
            if name not in g["proxies"]: g["proxies"].append(name)
        else: g["proxies"]=[x for x in g["proxies"] if x!=name]
    check(d); write(out,text,ps,gs)
else: stop("未知 YAML 管理操作")
PY
}


yaml_choose_target() {
  local default_path="${YAML_MANAGER_TARGET}" input resolved candidate
  printf '\n检测到的订阅 YAML：\n'
  if [[ -d /var/www/share/config ]]; then
    while IFS= read -r candidate; do printf '  %s\n' "${candidate}"; [[ -n "${default_path}" ]] || default_path="${candidate}"; done < <(find /var/www/share/config -maxdepth 1 -type f \( -name '*.yaml' -o -name '*.yml' \) -print 2>/dev/null | sort)
  fi
  input="$(prompt_default "目标 YAML 文件路径" "${default_path}")"
  [[ -n "${input}" && -f "${input}" ]] || { warn "目标文件不存在。"; return 1; }
  resolved="$(readlink -f -- "${input}")" || return 1
  ensure_yaml_module || return 1; yaml_manager_python validate "${resolved}" || { warn "该文件不适合由本工具管理。"; return 1; }
  YAML_MANAGER_TARGET="${resolved}"; printf '已选择：%s\n' "${YAML_MANAGER_TARGET}"
}

yaml_require_target() { [[ -n "${YAML_MANAGER_TARGET}" && -r "${YAML_MANAGER_TARGET}" ]] || yaml_choose_target; }


yaml_preview_and_apply() {
  local candidate="$1" backup_dir timestamp target_dir staged
  yaml_manager_python validate "${candidate}" || return 1
  printf '\n----- YAML 变更预览 -----\n'; diff -u -- "${YAML_MANAGER_TARGET}" "${candidate}" || true; printf '%s\n' '----- 预览结束 -----'
  prompt_yes_no "确认写入 ${YAML_MANAGER_TARGET}" 0 || { printf '已取消，原 YAML 没有变化。\n'; return 0; }
  [[ "${DEMO_MODE}" == 1 ]] && { printf '[预览] 不会写入目标 YAML。\n'; return 0; }
  require_root; install -d -m 700 "${BACKUP_ROOT}"; timestamp="$(date -u '+%Y%m%dT%H%M%SZ')"
  backup_dir="$(mktemp -d "${BACKUP_ROOT}/yaml-${timestamp}.XXXXXX")" || return 1; chmod 700 "${backup_dir}"
  cp -a -- "${YAML_MANAGER_TARGET}" "${backup_dir}/original.yaml" || return 1
  target_dir="$(dirname "${YAML_MANAGER_TARGET}")"; staged="$(mktemp "${target_dir}/.vps-manager-yaml.XXXXXX")" || return 1
  cp -a -- "${YAML_MANAGER_TARGET}" "${staged}" || { rm -f -- "${staged}"; return 1; }
  if ! cp -- "${candidate}" "${staged}" || ! yaml_manager_python validate "${staged}"; then rm -f -- "${staged}"; warn "候选复检失败，原文件没有变化。"; return 1; fi
  mv -f -- "${staged}" "${YAML_MANAGER_TARGET}" || return 1
  log "YAML 已原子更新"; printf '备份：%s\n' "${backup_dir}/original.yaml"
}


yaml_import_nodes() {
  local source_choice snippet source_file mapping candidate old new recommended selected old64 new64 line
  local -a names=(); yaml_require_target || return 0; ensure_work_dir
  snippet="${WORK_DIR}/nodes.yaml"; mapping="${WORK_DIR}/mapping.tsv"; candidate="${WORK_DIR}/candidate.yaml"
  printf '\n节点来源：\n  1) 本机最近输出 %s\n  2) 粘贴节点 YAML\n  3) 指定文件\n  0) 返回\n' "${YAML_FILE}"; read -r -p "请选择 [0]: " source_choice
  case "${source_choice:-0}" in
    1) [[ -r "${YAML_FILE}" ]] || { warn "尚无 Xray 节点输出。"; return 0; }; cp -- "${YAML_FILE}" "${snippet}" ;;
    2) printf '粘贴节点列表或 proxies: 内容；单独输入 __END__ 结束：\n'; : > "${snippet}"; while IFS= read -r line; do [[ "${line}" == __END__ ]] && break; printf '%s\n' "${line}" >> "${snippet}"; done ;;
    3) source_file="$(prompt_default "节点 YAML 文件路径" "")"; [[ -r "${source_file}" ]] || { warn "文件不可读。"; return 0; }; cp -- "${source_file}" "${snippet}" ;;
    0) return 0 ;; *) warn "未知选项。"; return 0 ;;
  esac
  mapfile -t names < <(yaml_manager_python snippet-names "${snippet}") || return 0
  ((${#names[@]} > 0)) || { warn "没有读取到节点。"; return 0; }
  printf '\n可用分组（多个编号用逗号分隔）：\n'; yaml_manager_python groups "${YAML_MANAGER_TARGET}"; : > "${mapping}"
  for old in "${names[@]}"; do
    new="$(prompt_default "节点名称" "${old}")"; recommended="$(yaml_manager_python recommend "${YAML_MANAGER_TARGET}" "${new}" "${old}")"
    selected="$(prompt_default "${new} 应属于的全部分组编号" "${recommended}")"
    old64="$(printf '%s' "${old}" | base64 | tr -d '\n')"; new64="$(printf '%s' "${new}" | base64 | tr -d '\n')"
    printf '%s\t%s\t%s\n' "${old64}" "${new64}" "${selected}" >> "${mapping}"
  done
  yaml_manager_python import "${YAML_MANAGER_TARGET}" "${snippet}" "${mapping}" "${candidate}" || { warn "候选 YAML 生成失败。"; return 0; }
  yaml_preview_and_apply "${candidate}"
}


yaml_rename_node() {
  local num old new candidate; yaml_require_target || return 0; ensure_work_dir; candidate="${WORK_DIR}/candidate.yaml"
  yaml_manager_python nodes "${YAML_MANAGER_TARGET}"; read -r -p "要重命名的节点编号: " num
  [[ "${num}" =~ ^[0-9]+$ ]] || { warn "编号无效。"; return 0; }
  old="$(yaml_manager_python nodes "${YAML_MANAGER_TARGET}" | awk -F '\t' -v n="${num}" '$1==n {print $2}')"; [[ -n "${old}" ]] || { warn "编号不存在。"; return 0; }
  new="$(prompt_default "新节点名称" "${old}")"; [[ "${new}" != "${old}" ]] || { printf '名称没有变化。\n'; return 0; }
  yaml_manager_python rename "${YAML_MANAGER_TARGET}" "${num}" "${new}" "${candidate}" && yaml_preview_and_apply "${candidate}"
}


yaml_update_node_groups() {
  local num name current chosen candidate; yaml_require_target || return 0; ensure_work_dir; candidate="${WORK_DIR}/candidate.yaml"
  yaml_manager_python nodes "${YAML_MANAGER_TARGET}"; read -r -p "要调整分组的节点编号: " num
  [[ "${num}" =~ ^[0-9]+$ ]] || { warn "编号无效。"; return 0; }
  name="$(yaml_manager_python nodes "${YAML_MANAGER_TARGET}" | awk -F '\t' -v n="${num}" '$1==n {print $2}')"; [[ -n "${name}" ]] || { warn "编号不存在。"; return 0; }
  printf '\n可用分组：\n'; yaml_manager_python groups "${YAML_MANAGER_TARGET}"; current="$(yaml_manager_python recommend "${YAML_MANAGER_TARGET}" "${name}" "${name}")"
  chosen="$(prompt_default "该节点应属于的全部分组编号" "${current}")"
  yaml_manager_python set-groups "${YAML_MANAGER_TARGET}" "${num}" "${chosen}" "${candidate}" && yaml_preview_and_apply "${candidate}"
}


yaml_view_full() {
  yaml_require_target || return 0
  if command -v vim >/dev/null 2>&1 && [[ -t 0 && -t 1 ]] && prompt_yes_no "使用 vim 只读打开" 1; then vim -R "${YAML_MANAGER_TARGET}"; else cat "${YAML_MANAGER_TARGET}"; fi
}


yaml_management_menu() {
  local choice; ensure_yaml_module || return 0
  while true; do
    printf '\nYAML 管理：%s\n  1) 选择/切换 YAML 文件\n  2) 查看节点与分组摘要\n  3) 查看完整 YAML（vim 只读）\n  4) 导入或更新 Xray 输出节点\n  5) 重命名节点并同步分组引用\n  6) 更新节点分组\n  7) 校验 YAML\n  0) 返回\n' "${YAML_MANAGER_TARGET:-未选择}"
    read -r -p "请选择 [0]: " choice
    case "${choice:-0}" in
      1) yaml_choose_target || true ;; 2) yaml_require_target && yaml_manager_python summary "${YAML_MANAGER_TARGET}" || true ;;
      3) yaml_view_full ;; 4) yaml_import_nodes ;; 5) yaml_rename_node ;; 6) yaml_update_node_groups ;;
      7) yaml_require_target && yaml_manager_python validate "${YAML_MANAGER_TARGET}" || true ;; 0) return 0 ;; *) warn "未知选项。" ;;
    esac
  done
}


komari_target_home() {
  local user="${SUDO_USER:-}" result=""
  if [[ -n "${user}" && "${user}" != root ]] && command -v getent >/dev/null 2>&1; then result="$(getent passwd "${user}" | cut -d: -f6)"; fi
  if [[ -z "${result}" ]] && command -v getent >/dev/null 2>&1; then result="$(getent passwd | awk -F: '$3>=1000 && $3<60000 && $1!="nobody" && $6~"^/home/" {print $6; exit}')"; fi
  printf '%s' "${result:-/root}"
}


komari_agent_arch() {
  case "$(uname -m)" in
    x86_64|amd64) printf 'amd64' ;;
    aarch64|arm64) printf 'arm64' ;;
    *) return 1 ;;
  esac
}


komari_local_agent_candidate() {
  local home="$1" arch candidate=""
  arch="$(komari_agent_arch)" || return 1
  if [[ -n "${KOMARI_LOCAL_AGENT:-}" ]]; then
    candidate="${KOMARI_LOCAL_AGENT}"
  elif [[ -f "${home}/komari-agent-linux-${arch}" ]]; then
    candidate="${home}/komari-agent-linux-${arch}"
  elif [[ "${home}" != /root && -f "/root/komari-agent-linux-${arch}" ]]; then
    candidate="/root/komari-agent-linux-${arch}"
  fi
  [[ -n "${candidate}" && -f "${candidate}" && ! -L "${candidate}" && -s "${candidate}" ]] || return 1
  printf '%s' "${candidate}"
}


komari_host_is_ipv6_only() {
  command -v ip >/dev/null 2>&1 || return 1
  ip -6 route show default 2>/dev/null | awk 'NF { found=1 } END { exit !found }' || return 1
  ip -4 -o addr show scope global 2>/dev/null \
    | awk '$2 != "CloudflareWARP" { found=1 } END { exit !found }' && return 1
  return 0
}


komari_show_ipv6_only_agent_notice() {
  local home="$1" endpoint="$2" arch download_url upload_path menu_path
  arch="$(komari_agent_arch)" || {
    warn "当前 CPU 架构没有对应的 Komari Agent 自动提示，请手动查看官方 Release。"
    return 0
  }
  download_url="https://github.com/komari-monitor/komari-agent/releases/latest/download/komari-agent-linux-${arch}"
  upload_path="${home}/komari-agent-linux-${arch}"
  if is_alpine; then
    menu_path="主菜单 3) Komari + WARP 管理 -> 1) 配置/修复 WARP 私网，并安装/重装 Agent"
  elif [[ "${endpoint}" == "${KOMARI_DEFAULT_PRIVATE_URL}" || "${endpoint}" == *'.internal'* ]]; then
    menu_path="主菜单 5) 安装/管理 Komari Agent -> 1) 配置/修复 WARP 私网，并可继续安装 Agent"
  else
    menu_path="主菜单 5) 安装/管理 Komari Agent -> 2) 安装/重装普通公网 Agent"
  fi
  printf '\n[提示] 检测到当前服务器为 IPv6-only，无法保证直接访问 GitHub Releases。\n'
  printf '请先在其他设备手动下载 Komari Agent：\n  %s\n' "${download_url}"
  printf '然后将文件上传到当前服务器：\n  %s\n' "${upload_path}"
  printf '上传完成后重新运行本脚本，并选择：\n  %s\n\n' "${menu_path}"
  printf '脚本检测到该本地文件后会校验并优先使用，不会再次下载 GitHub Release。\n'
}


komari_write_local_runner() {
  local runner="$1" agent="$2" endpoint="$3" token="$4" day="$5"
  local disable_ssh="$6" gpu="$7" public_ip="$8"
  {
    printf '#!/usr/bin/env bash\nexec '
    printf '%q ' "${agent}" -e "${endpoint}" -t "${token}" --month-rotate "${day}"
    [[ "${disable_ssh}" == 1 ]] && printf '%q ' --disable-web-ssh
    [[ "${gpu}" == 1 ]] && printf '%q ' --gpu
    [[ -n "${public_ip}" ]] && printf '%q ' --custom-ipv4 "${public_ip}"
    printf '\n'
  } > "${runner}"
  chmod 700 "${runner}"
}


komari_install_local_agent() {
  local source="$1" endpoint="$2" token="$3" install_dir="$4" day="$5"
  local disable_ssh="$6" gpu="$7" public_ip="$8"
  local agent="${install_dir}/agent" runner="${install_dir}/run-agent.sh"
  local service_file backup_agent="" backup_runner="" backup_service="" require_warp=0
  local warp_dependency="" warp_after="" warp_requires=""
  [[ "${endpoint}" == "${KOMARI_DEFAULT_PRIVATE_URL}" || "${endpoint}" == *'.internal'* ]] && require_warp=1
  if [[ "${require_warp}" == 1 ]]; then
    warp_dependency=" warp-svc"
    warp_after=" warp-svc.service"
    warp_requires="Requires=warp-svc.service"
  fi
  ensure_work_dir
  install -m 700 "${source}" "${WORK_DIR}/komari-agent"
  "${WORK_DIR}/komari-agent" --help >/dev/null 2>&1 \
    || { warn "本地 Komari Agent 无法正常执行 --help，已停止安装。"; return 1; }
  log "本地 Komari Agent SHA-256: $(sha256sum "${WORK_DIR}/komari-agent" | awk '{print $1}')"
  install -d -m 700 "${install_dir}"
  [[ ! -e "${agent}" ]] || backup_agent="$(backup_file "${agent}" komari-agent-local)"
  [[ ! -e "${runner}" ]] || backup_runner="$(backup_file "${runner}" komari-runner)"
  if is_alpine; then service_file="/etc/init.d/komari-agent"; else service_file="/etc/systemd/system/komari-agent.service"; fi
  [[ ! -e "${service_file}" ]] || backup_service="$(backup_file "${service_file}" komari-service)"
  if service_is_active komari-agent; then
    if is_alpine; then rc-service komari-agent stop; else systemctl stop komari-agent.service; fi
  fi
  install -m 700 "${WORK_DIR}/komari-agent" "${agent}"
  komari_write_local_runner "${runner}" "${agent}" "${endpoint}" "${token}" "${day}" \
    "${disable_ssh}" "${gpu}" "${public_ip}"
  if is_alpine; then
    cat > "${service_file}" <<EOF
#!/sbin/openrc-run
name="Komari Agent Service"
description="Komari monitoring agent"
command="${runner}"
command_user="root"
directory="${install_dir}"
pidfile="/run/komari-agent.pid"
retry="SIGTERM/30"
supervisor=supervise-daemon

depend() {
    need net${warp_dependency}
    after network${warp_dependency}
}
EOF
    chmod 700 "${service_file}"
  else
    cat > "${service_file}" <<EOF
[Unit]
Description=Komari Agent Service
Wants=network-online.target
After=network-online.target${warp_after}
${warp_requires}

[Service]
Type=simple
ExecStart="${runner}"
WorkingDirectory="${install_dir}"
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF
    chmod 600 "${service_file}"
    systemctl daemon-reload
  fi
  if ! service_enable_start komari-agent || ! service_is_active komari-agent; then
    warn "本地 Agent 已写入但服务启动失败。备份位置: ${backup_agent:-无旧 Agent} ${backup_runner:-无旧启动器} ${backup_service:-无旧服务}"
    return 1
  fi
  log "已使用本地文件安装 Komari Agent: ${source}"
  service_status_text komari-agent | sed -n '1,60p' || true
}


komari_install_agent() {
  local endpoint="$1" token home install_dir day installer checksum public_ip local_agent=""
  local disable_ssh=1 gpu=1 detect_ip=1
  local -a args=()
  home="$(komari_target_home)"
  local_agent="$(komari_local_agent_candidate "${home}" || true)"
  if [[ -z "${local_agent}" ]] && komari_host_is_ipv6_only; then
    komari_show_ipv6_only_agent_notice "${home}" "${endpoint}"
    return 0
  fi
  endpoint="$(prompt_default "Komari 连接地址" "${endpoint}")"
  token="$(prompt_secret "Komari Client Token")"
  [[ -n "${token}" ]] || { warn "Komari Token 不能为空。"; return 1; }
  install_dir="$(prompt_default "Agent 安装目录" "${home}/scripts/komari-agent")"
  [[ "${install_dir}" == /* ]] || install_dir="$(pwd -P)/${install_dir}"
  day="$(prompt_default "流量统计重置日" "11")"
  [[ "${day}" =~ ^([1-9]|[12][0-9]|3[01])$ ]] || { warn "重置日必须是 1-31。"; return 1; }
  prompt_yes_no "是否禁用 Web SSH" 1 || disable_ssh=0
  prompt_yes_no "是否启用 GPU 监控" 1 || gpu=0
  prompt_yes_no "是否自动记录公网 IPv4" 1 || detect_ip=0
  printf '\nAgent 配置预览：\n  Endpoint: %s\n  安装目录: %s\n  重置日: %s\n  Token: <已隐藏>\n' "${endpoint}" "${install_dir}" "${day}"
  [[ -z "${local_agent}" ]] || printf '  本地 Agent: %s\n' "${local_agent}"
  if [[ "${DEMO_MODE}" == 1 ]]; then
    if [[ -n "${local_agent}" ]]; then printf '[演示] 将校验并优先使用本地 Komari Agent：%s\n' "${local_agent}"
    else printf '[演示] 将校验并调用 Komari 官方安装器：%s\n' "${KOMARI_INSTALL_URL}"
    fi
    return 0
  fi
  prompt_yes_no "确认安装或重装 Komari Agent" 0 || return 0
  if [[ -n "${local_agent}" ]] && prompt_yes_no "是否优先使用检测到的本地 Agent（跳过 GitHub Release 下载）" 1; then
    if [[ "${detect_ip}" == 1 ]]; then
      public_ip="$(curl -4 -fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)"
      [[ -n "${public_ip}" ]] || warn "公网 IPv4 探测失败。"
    fi
    komari_install_local_agent "${local_agent}" "${endpoint}" "${token}" "${install_dir}" "${day}" \
      "${disable_ssh}" "${gpu}" "${public_ip:-}"
    return $?
  fi
  ensure_work_dir; installer="${WORK_DIR}/install-komari-agent.sh"
  curl -fL --retry 3 --connect-timeout 10 -o "${installer}" "${KOMARI_INSTALL_URL}"
  chmod 700 "${installer}"; bash -n "${installer}"
  checksum="$(sha256sum "${installer}" | awk '{print $1}')"; log "Komari 官方安装器 SHA-256: ${checksum}"
  args=(-e "${endpoint}" -t "${token}" --install-dir "${install_dir}" --month-rotate "${day}")
  [[ "${disable_ssh}" == 1 ]] && args+=(--disable-web-ssh)
  [[ "${gpu}" == 1 ]] && args+=(--gpu)
  if [[ "${detect_ip}" == 1 ]]; then
    public_ip="$(curl -4 -fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)"
    [[ -n "${public_ip}" ]] && args+=(--custom-ipv4 "${public_ip}") || warn "公网 IPv4 探测失败。"
  fi
  bash "${installer}" "${args[@]}"
  service_status_text komari-agent | sed -n '1,60p' || true
}


komari_load_cf_token() {
  local line key value
  if [[ -r "${KOMARI_TOKEN_ENV_FILE}" ]]; then
    while IFS= read -r line || [[ -n "${line}" ]]; do
      line="${line%$'\r'}"; [[ "${line}" == *=* ]] || continue
      key="${line%%=*}"; value="${line#*=}"; value="${value%\"}"; value="${value#\"}"; value="${value%\'}"; value="${value#\'}"
      case "${key}" in
        CF_ACCESS_CLIENT_ID) [[ -n "${CF_ACCESS_CLIENT_ID:-}" ]] || CF_ACCESS_CLIENT_ID="${value}" ;;
        CF_ACCESS_CLIENT_SECRET) [[ -n "${CF_ACCESS_CLIENT_SECRET:-}" ]] || CF_ACCESS_CLIENT_SECRET="${value}" ;;
      esac
    done < "${KOMARI_TOKEN_ENV_FILE}"
  fi
  [[ -n "${CF_ACCESS_CLIENT_ID:-}" ]] || CF_ACCESS_CLIENT_ID="$(prompt_secret "Cloudflare Access Client ID")"
  [[ -n "${CF_ACCESS_CLIENT_SECRET:-}" ]] || CF_ACCESS_CLIENT_SECRET="$(prompt_secret "Cloudflare Access Client Secret")"
  [[ -n "${CF_ACCESS_CLIENT_ID}" && -n "${CF_ACCESS_CLIENT_SECRET}" ]] || { warn "Cloudflare Access 凭据不能为空。"; return 1; }
}


komari_check_warp_disk() {
  local root_total_kib root_free_kib root_total_mib root_free_mib
  read -r root_total_kib root_free_kib < <(df -Pk / | awk 'NR == 2 {print $2, $4}')
  [[ "${root_total_kib:-}" =~ ^[0-9]+$ && "${root_free_kib:-}" =~ ^[0-9]+$ ]] \
    || { warn "无法读取根分区容量，为避免安装中途写满，已停止安装 WARP。"; return 1; }
  root_total_mib=$((root_total_kib / 1024))
  root_free_mib=$((root_free_kib / 1024))

  if (( root_total_mib < KOMARI_WARP_MIN_ROOT_MIB \
    || root_free_mib < KOMARI_WARP_MIN_FREE_MIB )); then
    warn "当前根分区共 ${root_total_mib} MiB、可用 ${root_free_mib} MiB，不满足官方 WARP 客户端的安装空间要求。"
    printf 'Cloudflare WARP 当前会强制安装 WebKit/GTK 等大型依赖。\n'
    printf '脚本要求：根分区至少 %s MiB、可用空间至少 %s MiB；建议扩容到 4 GiB 以上。\n' \
      "${KOMARI_WARP_MIN_ROOT_MIB}" "${KOMARI_WARP_MIN_FREE_MIB}"
    printf '如果是 Debian 11/12 或 Ubuntu 22.04/24.04/26.04 amd64 且至少还有 400 MiB 可用空间，脚本可以改装对应发行版的 Cloudflare 官方旧版轻量客户端并锁定版本。\n'
    return 1
  fi
}

komari_install_warp_legacy() {
  local os_id os_version codename arch root_free_kib root_free_mib package_file installed_version backup=""
  local package_url package_sha256
  # shellcheck disable=SC1091
  . /etc/os-release
  os_id="${ID:-}"
  os_version="${VERSION_ID:-}"
  codename="${VERSION_CODENAME:-}"
  arch="$(dpkg --print-architecture)"
  if [[ "${arch}" != "amd64" ]] \
    || ! { [[ "${os_id}" == "debian" && "${codename}" =~ ^(bullseye|bookworm)$ ]] \
      || [[ "${os_id}" == "ubuntu" && "${os_version}" =~ ^(22|24|26)\.04$ ]]; }; then
    warn "官方轻量旧版自动安装目前只支持 Debian 11/12 或 Ubuntu 22.04/24.04/26.04 amd64；当前为 ${os_id:-unknown} ${os_version:-unknown} ${codename:-unknown} ${arch}."
    return 1
  fi

  case "${codename}" in
    bullseye)
      package_url="${KOMARI_WARP_LEGACY_BULLSEYE_URL}"
      package_sha256="${KOMARI_WARP_LEGACY_BULLSEYE_SHA256}"
      ;;
    bookworm)
      package_url="${KOMARI_WARP_LEGACY_URL}"
      package_sha256="${KOMARI_WARP_LEGACY_SHA256}"
      ;;
    jammy)
      package_url="${KOMARI_WARP_LEGACY_JAMMY_URL}"
      package_sha256="${KOMARI_WARP_LEGACY_JAMMY_SHA256}"
      ;;
    noble|resolute)
      package_url="${KOMARI_WARP_LEGACY_NOBLE_URL}"
      package_sha256="${KOMARI_WARP_LEGACY_NOBLE_SHA256}"
      ;;
  esac

  installed_version="$(dpkg-query -W -f='${Version}' cloudflare-warp 2>/dev/null || true)"
  if [[ "${installed_version}" == "${KOMARI_WARP_LEGACY_VERSION}" ]] \
    && command -v warp-cli >/dev/null 2>&1; then
    apt-mark hold cloudflare-warp >/dev/null
    install_systemd_warp_guard
    log "Cloudflare WARP ${installed_version} 已安装并锁定"
    return 0
  fi

  root_free_kib="$(df -Pk / | awk 'NR == 2 {print $4}')"
  [[ "${root_free_kib:-}" =~ ^[0-9]+$ ]] \
    || { warn "无法读取根分区可用空间。"; return 1; }
  root_free_mib=$((root_free_kib / 1024))
  if (( root_free_mib < KOMARI_WARP_LEGACY_MIN_FREE_MIB )); then
    warn "安装官方轻量旧版 WARP 至少需要 ${KOMARI_WARP_LEGACY_MIN_FREE_MIB} MiB 可用空间；当前只有 ${root_free_mib} MiB。"
    return 1
  fi

  printf '\n可用的低磁盘方案：\n'
  printf '  Cloudflare 官方 WARP: %s（新 Linux GUI 引入前）\n' "${KOMARI_WARP_LEGACY_VERSION}"
  printf '  下载约 53 MiB，安装后约 152 MiB；安装完成后会锁定版本。\n'
  printf '  锁定期间不会获得新版功能和修复；扩容后可解除锁定并升级。\n'
  if [[ -n "${installed_version}" ]]; then
    printf '  当前已安装版本：%s；继续后会降级并保留现有 MDM 配置。\n' "${installed_version}"
    prompt_yes_no "是否降级并锁定这个官方轻量版本" 1 || return 1
    if [[ -f /var/lib/cloudflare-warp/mdm.xml ]]; then
      backup="$(backup_file /var/lib/cloudflare-warp/mdm.xml warp-mdm-before-downgrade)"
      log "WARP MDM 配置已备份到 ${backup}"
    fi
    apt-mark unhold cloudflare-warp >/dev/null 2>&1 || true
  else
    prompt_yes_no "是否安装并锁定这个官方轻量版本" 1 || return 1
  fi

  export DEBIAN_FRONTEND=noninteractive
  apt_update_safe
  apt-get install -y curl ca-certificates gnupg2 iproute2 nftables libcap2-bin
  ensure_work_dir
  package_file="${WORK_DIR}/cloudflare-warp_${KOMARI_WARP_LEGACY_VERSION}_amd64.deb"
  curl -fL --retry 2 --connect-timeout 10 --max-time 180 \
    -o "${package_file}" "${package_url}"
  printf '%s  %s\n' "${package_sha256}" "${package_file}" | sha256sum -c -
  apt-get install -y --allow-downgrades "${package_file}"

  installed_version="$(dpkg-query -W -f='${Version}' cloudflare-warp 2>/dev/null || true)"
  [[ "${installed_version}" == "${KOMARI_WARP_LEGACY_VERSION}" ]] \
    || { warn "WARP 版本校验失败：${installed_version:-未安装}"; return 1; }
  command -v warp-cli >/dev/null 2>&1 \
    || { warn "WARP 已安装但找不到 warp-cli。"; return 1; }
  apt-mark hold cloudflare-warp >/dev/null
  service_restart warp-svc
  install_systemd_warp_guard
  log "已安装并锁定 Cloudflare WARP ${installed_version}"
}

komari_install_warp_client() {
  local os_id os_version codename arch
  if is_alpine; then
    komari_install_warp_alpine
    return $?
  fi

  # shellcheck disable=SC1091
  . /etc/os-release
  os_id="${ID:-}"
  os_version="${VERSION_ID:-}"
  codename="${VERSION_CODENAME:-}"
  arch="$(dpkg --print-architecture)"
  if [[ "${arch}" == "amd64" ]] \
    && { [[ "${os_id}" == "debian" && "${codename}" =~ ^(bullseye|bookworm)$ ]] \
      || [[ "${os_id}" == "ubuntu" && "${os_version}" =~ ^(22|24|26)\.04$ ]]; }; then
    komari_install_warp_legacy
    return $?
  fi

  warn "当前系统没有经过验证的轻量 WARP 固定包；为避免拉入高内存新版，脚本不会自动安装仓库最新版。"
  return 1
}


extract_deb_to() {
  local package="$1" destination="$2" extract_dir data_archive
  extract_dir="$(mktemp -d /tmp/vps-manager-deb.XXXXXX)"
  (cd "${extract_dir}" && ar x "${package}")
  data_archive="$(find "${extract_dir}" -maxdepth 1 -type f -name 'data.tar.*' | head -n 1)"
  [[ -n "${data_archive}" ]] || { rm -rf -- "${extract_dir}"; return 1; }
  tar -xf "${data_archive}" -C "${destination}"
  rm -rf -- "${extract_dir}"
}


install_systemd_warp_guard() {
  install -d -m 755 /usr/local/sbin
  cat > "${WARP_GUARD_PATH}" <<EOF
#!/bin/sh
set -eu

LOCK_DIR="/run/vps-manager-warp-guard.lock"
MAX_RSS_KIB=${WARP_RSS_MAX_KIB}
mkdir "\${LOCK_DIR}" 2>/dev/null || exit 0
trap 'rmdir "\${LOCK_DIR}" 2>/dev/null || true' EXIT INT TERM

warp_pid=''
for cmdline in /proc/[0-9]*/cmdline; do
  [ -r "\${cmdline}" ] || continue
  if tr '\\000' ' ' < "\${cmdline}" 2>/dev/null | grep -q '/bin/warp-svc'; then
    warp_pid="\${cmdline#/proc/}"
    warp_pid="\${warp_pid%/cmdline}"
    break
  fi
done

if [ -n "\${warp_pid}" ] && [ -r "/proc/\${warp_pid}/status" ]; then
  rss="\$(awk '/^VmRSS:/{print \$2; exit}' "/proc/\${warp_pid}/status")"
  rss="\${rss:-0}"
  if [ "\${rss}" -gt "\${MAX_RSS_KIB}" ]; then
    logger -t vps-manager-warp-guard "restarting warp-svc at VmRSS=\${rss} KiB"
    systemctl restart warp-svc
  fi
fi
EOF
  chmod 700 "${WARP_GUARD_PATH}"
  cat > /etc/systemd/system/vps-manager-warp-guard.service <<EOF
[Unit]
Description=VPS Manager WARP memory guard
After=warp-svc.service

[Service]
Type=oneshot
ExecStart=${WARP_GUARD_PATH}
EOF
  cat > /etc/systemd/system/vps-manager-warp-guard.timer <<'EOF'
[Unit]
Description=Check WARP memory usage every five minutes

[Timer]
OnBootSec=3min
OnUnitActiveSec=5min
RandomizedDelaySec=30s
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now vps-manager-warp-guard.timer
  "${WARP_GUARD_PATH}"
}


install_alpine_warp_guard() {
  local log_file="/var/log/cloudflare-warp/warp-svc.log"
  local archive_file="/var/log/cloudflare-warp/warp-svc.log.1.gz"
  local log_size tail_tmp
  if [[ -f "${log_file}" ]]; then
    log_size="$(wc -c < "${log_file}" 2>/dev/null || echo 0)"
    if (( log_size > ALPINE_WARP_LOG_MAX_BYTES )); then
      tail_tmp="$(mktemp /run/warp-svc-bootstrap.XXXXXX)"
      tail -c "${ALPINE_WARP_LOG_TAIL_BYTES}" "${log_file}" > "${tail_tmp}" 2>/dev/null \
        || cp "${log_file}" "${tail_tmp}"
      : > "${log_file}"
      gzip -c "${tail_tmp}" > "${archive_file}"
      chmod 600 "${archive_file}"
      rm -f -- "${tail_tmp}"
    fi
  fi
  install -d -m 755 /usr/local/sbin /var/log/cloudflare-warp
  cat > "${WARP_GUARD_PATH}" <<EOF
#!/bin/sh
set -eu

LOG_FILE="/var/log/cloudflare-warp/warp-svc.log"
ARCHIVE_FILE="/var/log/cloudflare-warp/warp-svc.log.1.gz"
LOCK_DIR="/run/vps-manager-warp-guard.lock"
MAX_LOG_BYTES=${ALPINE_WARP_LOG_MAX_BYTES}
TAIL_BYTES=${ALPINE_WARP_LOG_TAIL_BYTES}
MAX_RSS_KIB=${WARP_RSS_MAX_KIB}

mkdir "\${LOCK_DIR}" 2>/dev/null || exit 0
cleanup() { rm -rf "\${LOCK_DIR}" "\${TAIL_TMP:-}" "\${ARCHIVE_TMP:-}"; }
trap cleanup EXIT INT TERM

if [ -f "\${LOG_FILE}" ]; then
  size="\$(wc -c < "\${LOG_FILE}" 2>/dev/null || echo 0)"
  if [ "\${size}" -gt "\${MAX_LOG_BYTES}" ]; then
    TAIL_TMP="\$(mktemp /run/warp-svc-tail.XXXXXX)"
    ARCHIVE_TMP="\${ARCHIVE_FILE}.tmp.\$\$"
    tail -c "\${TAIL_BYTES}" "\${LOG_FILE}" > "\${TAIL_TMP}" 2>/dev/null || cp "\${LOG_FILE}" "\${TAIL_TMP}"
    : > "\${LOG_FILE}"
    gzip -c "\${TAIL_TMP}" > "\${ARCHIVE_TMP}"
    chmod 600 "\${ARCHIVE_TMP}"
    mv -f "\${ARCHIVE_TMP}" "\${ARCHIVE_FILE}"
    logger -t vps-manager-warp-guard "rotated warp-svc.log at \${size} bytes"
  fi
fi

warp_pid=''
for cmdline in /proc/[0-9]*/cmdline; do
  [ -r "\${cmdline}" ] || continue
  if tr '\\000' ' ' < "\${cmdline}" 2>/dev/null | grep -q '${ALPINE_WARP_ROOT}/client/bin/warp-svc'; then
    warp_pid="\${cmdline#/proc/}"
    warp_pid="\${warp_pid%/cmdline}"
    break
  fi
done

if [ -n "\${warp_pid}" ] && [ -r "/proc/\${warp_pid}/status" ]; then
  rss="\$(awk '/^VmRSS:/{print \$2; exit}' "/proc/\${warp_pid}/status")"
  rss="\${rss:-0}"
  if [ "\${rss}" -gt "\${MAX_RSS_KIB}" ]; then
    logger -t vps-manager-warp-guard "restarting warp-svc at VmRSS=\${rss} KiB"
    rc-service warp-svc restart >/dev/null
  fi
fi
EOF
  chmod 700 "${WARP_GUARD_PATH}"
  touch /etc/crontabs/root
  grep -Fqx "*/5 * * * * ${WARP_GUARD_PATH}" /etc/crontabs/root \
    || printf '*/5 * * * * %s\n' "${WARP_GUARD_PATH}" >> /etc/crontabs/root
  service_enable_start crond >/dev/null 2>&1 || true
  "${WARP_GUARD_PATH}"
}


komari_alpine_runtime_manifest() {
  case "$1" in
    amd64)
      cat <<'EOF'
1896a2aacf4ad681ff5eacc24a5b0ca4d5d9c9b9c9e4b6de5197bc1e116ea619|pool/main/g/gcc-12/gcc-12-base_12.2.0-14+deb12u1_amd64.deb
ba4f88f73dbc3ae9055f3c20f4523bfdbaf1ad13ff95e258924f77d20b4fbedf|pool/main/g/glibc/libc6_2.36-9+deb12u14_amd64.deb
8d684c673e7483802a5c447834b0df6fce006eb3a7109e1be412f5ad425bb24f|pool/main/libc/libcap2/libcap2_2.66-4+deb12u3+b1_amd64.deb
18ee0ce5fab9f7b671e87da1e9fa18660e36e04a3402f24bdb8635e0ba1d35f6|pool/main/d/dbus/libdbus-1-3_1.14.10-1~deb12u1_amd64.deb
3016e62cb4b7cd8038822870601f5ed131befe942774d0f745622cc77d8a88f7|pool/main/g/gcc-12/libgcc-s1_12.2.0-14+deb12u1_amd64.deb
e7a56552139c693904a6f9712234c05fe918353273a7cbdb5e62f423ad71bb97|pool/main/libg/libgcrypt20/libgcrypt20_1.10.1-3+deb12u1_amd64.deb
89944ee11d7370ce6ef46fc52f094c4a6512eff8943ec4c6ebefeae6360ceada|pool/main/libg/libgpg-error/libgpg-error0_1.46-1_amd64.deb
64cde86cef1deaf828bd60297839b59710b5cd8dc50efd4f12643caaee9389d3|pool/main/l/lz4/liblz4-1_1.9.4-1_amd64.deb
f96d8876b53ec89d76a992bc199679b818cf518225a768954d9451fb556a4eb7|pool/main/x/xz-utils/liblzma5_5.4.1-1+deb12u1_amd64.deb
6cca09767e94e4b5d2888ef31ad797bd3e7cec27fbbe98b49b10d4884746ce77|pool/main/n/nspr/libnspr4_4.35-1_amd64.deb
bb4339de2e76be9862225447c6c24b9d759baba5ee861d86dfb558ebf4474d14|pool/main/n/nss/libnss3_3.87.1-1+deb12u2_amd64.deb
a8d78b40e9b4e422224aeebfe0e4dfc243f6acf3532490b0c05480d4283d41e2|pool/main/s/sqlite3/libsqlite3-0_3.40.1-2+deb12u2_amd64.deb
013c07514a9e4933b2d5c098018695a6aa42d085dbc483ce2c094a954c8a1b0a|pool/main/s/systemd/libsystemd0_252.39-1~deb12u2_amd64.deb
6315b5ac38b724a710fb96bf1042019398cb656718b1522279a5185ed39318fa|pool/main/libz/libzstd/libzstd1_1.5.4+dfsg2-5_amd64.deb
EOF
      ;;
    arm64)
      cat <<'EOF'
674cf6cba6d432bd200c45fe866c1652c7a53523cc2e7a613e05bc4abf7b5440|pool/main/g/gcc-12/gcc-12-base_12.2.0-14+deb12u1_arm64.deb
01f4330719fd4f65580e16ea5a0527f372fca750e8f588d26deaf09f2d3b1cf4|pool/main/g/glibc/libc6_2.36-9+deb12u14_arm64.deb
b3a21ae1cef9c2f3fa340007100fb0aa934ab6a4d8aed131660de9713db2bb6e|pool/main/libc/libcap2/libcap2_2.66-4+deb12u3+b1_arm64.deb
2a423794f44ee756f70fda67c6e47b15afe3dd22cd69e51f5d14d2ec9538f806|pool/main/d/dbus/libdbus-1-3_1.14.10-1~deb12u1_arm64.deb
576926b283613db80168ddf76380a3bd877602778cf0d226caa7bfbfa71eacf3|pool/main/g/gcc-12/libgcc-s1_12.2.0-14+deb12u1_arm64.deb
140af58350c9b15bfa611000d9e0205528bbed2cba39271bf12bd36de2678f2e|pool/main/libg/libgcrypt20/libgcrypt20_1.10.1-3+deb12u1_arm64.deb
aff6ce011ae9abf7090e906f0cf6bc2b447bbc4cc7e03ff117f9d73528857352|pool/main/libg/libgpg-error/libgpg-error0_1.46-1_arm64.deb
f061216ce11aabba8f032dfd6c75c181e782fef7493033b9621a8c3b2953b87e|pool/main/l/lz4/liblz4-1_1.9.4-1_arm64.deb
647ce9d81e41c30071ce6ac0d3324579216a33aaa1d28971d6952315f6a95a75|pool/main/x/xz-utils/liblzma5_5.4.1-1+deb12u1_arm64.deb
3aa6bc5a1a3f83627f735b9712eed74ed2c345ae9148e9d876887a97982ae28d|pool/main/n/nspr/libnspr4_4.35-1_arm64.deb
2e5af2fc3d1015674a674b48149a342f1922d74c82f16c0cdc2d6a6bee27f154|pool/main/n/nss/libnss3_3.87.1-1+deb12u2_arm64.deb
a690f7f2aa6435bd1fd7cbbd2216acb9acbb8c48c9721f2c195766375439eb13|pool/main/s/sqlite3/libsqlite3-0_3.40.1-2+deb12u2_arm64.deb
293ab474b90276dae9ebc03ed01e622e0c1f2578e83ed3aa926ae1eaf84dda9c|pool/main/s/systemd/libsystemd0_252.39-1~deb12u2_arm64.deb
95e173c9538f96ede4fc275ec7863f395a97dd0ea62454be9bc914efa1b9be93|pool/main/libz/libzstd/libzstd1_1.5.4+dfsg2-5_arm64.deb
EOF
      ;;
    *) return 1 ;;
  esac
}


komari_install_warp_alpine() {
  local free_kib free_mib stage package_file hash path url alpine_arch deb_arch lib_arch loader
  local package_url package_sha256 installed_arch="" backup=""
  local mirror="https://deb.debian.org/debian"
  alpine_arch="$(apk --print-arch)"
  case "${alpine_arch}" in
    x86_64)
      deb_arch="amd64"
      lib_arch="x86_64-linux-gnu"
      loader="ld-linux-x86-64.so.2"
      package_url="${KOMARI_WARP_LEGACY_URL}"
      package_sha256="${KOMARI_WARP_LEGACY_SHA256}"
      ;;
    aarch64)
      deb_arch="arm64"
      lib_arch="aarch64-linux-gnu"
      loader="ld-linux-aarch64.so.1"
      package_url="${KOMARI_WARP_LEGACY_ARM64_URL}"
      package_sha256="${KOMARI_WARP_LEGACY_ARM64_SHA256}"
      ;;
    *)
      warn "Alpine WARP 兼容运行时仅支持 x86_64 和 aarch64；当前为 ${alpine_arch}."
      return 1
      ;;
  esac
  [[ ! -r "${ALPINE_WARP_ROOT}/ARCH" ]] || installed_arch="$(< "${ALPINE_WARP_ROOT}/ARCH")"
  if [[ -x "${ALPINE_WARP_ROOT}/client/bin/warp-cli" && -f "${ALPINE_WARP_ROOT}/VERSION" ]] \
    && grep -qx "${KOMARI_WARP_LEGACY_VERSION}" "${ALPINE_WARP_ROOT}/VERSION" \
    && [[ "${installed_arch}" == "${deb_arch}" ]] \
    && warp-cli --version >/dev/null 2>&1; then
    log "Alpine WARP ${KOMARI_WARP_LEGACY_VERSION} ${deb_arch} 已安装，跳过重复安装"
    service_enable_start dbus >/dev/null 2>&1 || true
    service_enable_start warp-svc
    install_alpine_warp_guard
    return 0
  fi
  if [[ -d "${ALPINE_WARP_ROOT}" ]]; then
    warn "检测到不可用或架构不匹配的 Alpine WARP 安装（记录架构：${installed_arch:-未知}，当前：${deb_arch}），将重新安装。"
  fi
  free_kib="$(df -Pk / | awk 'NR == 2 {print $4}')"
  free_mib=$((free_kib / 1024))
  if (( free_mib < ALPINE_WARP_MIN_FREE_MIB )); then
    warn "Alpine 隔离版 WARP 至少需要 ${ALPINE_WARP_MIN_FREE_MIB} MiB 可用空间；当前 ${free_mib} MiB。"
    return 1
  fi
  printf '\nAlpine 没有 Cloudflare 官方 WARP 包。脚本将安装固定版本 %s，\n' "${KOMARI_WARP_LEGACY_VERSION}"
  printf '并把官方 Debian 程序及其 glibc 依赖隔离在 %s，不替换 Alpine musl。\n' "${ALPINE_WARP_ROOT}"
  prompt_yes_no "是否继续安装 Alpine WARP 兼容运行时" 1 || return 1
  apk add --no-cache bash ca-certificates curl dbus iproute2 nftables libcap nss-tools libpcap binutils xz
  service_enable_start dbus
  ensure_work_dir
  stage="${WORK_DIR}/cloudflare-warp"
  mkdir -p "${stage}/runtime" "${stage}/client"
  while IFS='|' read -r hash path; do
    [[ -n "${hash}" ]] || continue
    package_file="${WORK_DIR}/runtime.deb"
    url="${mirror}/${path}"
    curl -fL --retry 3 --connect-timeout 10 --max-time 300 -o "${package_file}" "${url}"
    printf '%s  %s\n' "${hash}" "${package_file}" | sha256sum -c -
    extract_deb_to "${package_file}" "${stage}/runtime"
    rm -f -- "${package_file}"
  done < <(komari_alpine_runtime_manifest "${deb_arch}")
  package_file="${WORK_DIR}/cloudflare-warp.deb"
  curl -fL --retry 3 --connect-timeout 10 --max-time 240 -o "${package_file}" "${package_url}"
  printf '%s  %s\n' "${package_sha256}" "${package_file}" | sha256sum -c -
  extract_deb_to "${package_file}" "${stage}/client"
  [[ -x "${stage}/client/bin/warp-cli" && -x "${stage}/client/bin/warp-svc" ]] \
    || { warn "WARP 包内缺少程序文件。"; return 1; }
  printf '%s\n' "${KOMARI_WARP_LEGACY_VERSION}" > "${stage}/VERSION"
  printf '%s\n' "${deb_arch}" > "${stage}/ARCH"
  service_is_active warp-svc && rc-service warp-svc stop || true
  if [[ -d "${ALPINE_WARP_ROOT}" ]]; then
    install -d -m 700 "${BACKUP_ROOT}"
    backup="${BACKUP_ROOT}/cloudflare-warp-before-${deb_arch}-$(date '+%Y%m%d-%H%M%S')"
    mv "${ALPINE_WARP_ROOT}" "${backup}"
    log "原 Alpine WARP 运行时已备份到 ${backup}"
  fi
  install -d -m 755 "$(dirname "${ALPINE_WARP_ROOT}")"
  mv "${stage}" "${ALPINE_WARP_ROOT}"
  cat > /usr/local/bin/warp-cli <<EOF
#!/bin/sh
exec ${ALPINE_WARP_ROOT}/runtime/lib/${lib_arch}/${loader} --library-path ${ALPINE_WARP_ROOT}/runtime/lib/${lib_arch}:${ALPINE_WARP_ROOT}/runtime/usr/lib/${lib_arch} ${ALPINE_WARP_ROOT}/client/bin/warp-cli "\$@"
EOF
  cat > /usr/local/bin/warp-svc <<EOF
#!/bin/sh
exec ${ALPINE_WARP_ROOT}/runtime/lib/${lib_arch}/${loader} --library-path ${ALPINE_WARP_ROOT}/runtime/lib/${lib_arch}:${ALPINE_WARP_ROOT}/runtime/usr/lib/${lib_arch} ${ALPINE_WARP_ROOT}/client/bin/warp-svc "\$@"
EOF
  chmod 755 /usr/local/bin/warp-cli /usr/local/bin/warp-svc
  install -d -m 755 /var/log/cloudflare-warp
  cat > /etc/init.d/warp-svc <<'EOF'
#!/sbin/openrc-run
description="Cloudflare WARP Service (isolated glibc runtime)"
command="/usr/local/bin/warp-svc"
supervisor="supervise-daemon"
respawn_delay=5
respawn_max=0
output_log="/var/log/cloudflare-warp/warp-svc.log"
error_log="/var/log/cloudflare-warp/warp-svc.log"
depend() { need net dbus; after firewall; }
EOF
  chmod 755 /etc/init.d/warp-svc
  service_enable_start warp-svc
  install_alpine_warp_guard
  warp-cli --version
  log "Alpine WARP ${deb_arch} 兼容运行时安装完成并已锁定版本"
}


komari_check_kernel() {
  if is_alpine; then
    if nft list ruleset >/dev/null 2>&1; then log "Alpine nftables 接口可用"; return 0; fi
    warn "当前容器没有可用的 nftables 内核接口，WARP 可能无法连接；这需要服务商在宿主机开放。"
    return 1
  fi
  if modprobe nf_tables >/dev/null 2>&1 && nft list ruleset >/dev/null 2>&1; then log "nftables 内核支持正常"; return 0; fi
  warn "当前内核缺少 nftables 支持，WARP 可能无法连接。"
  if prompt_yes_no "安装 linux-image-amd64 新内核（之后需手动重启）" 0; then apt_update_safe; apt-get install -y --no-install-recommends linux-image-amd64; warn "请重启后重新执行 WARP 配置。"; return 1; fi
}


komari_write_mdm() {
  local team="$1" candidate backup=""
  ensure_work_dir; candidate="${WORK_DIR}/mdm.xml"
  cat > "${candidate}" <<EOF
<dict>
  <key>auth_client_id</key><string>${CF_ACCESS_CLIENT_ID}</string>
  <key>auth_client_secret</key><string>${CF_ACCESS_CLIENT_SECRET}</string>
  <key>auto_connect</key><integer>1</integer>
  <key>onboarding</key><false/>
  <key>organization</key><string>${team}</string>
  <key>service_mode</key><string>warp</string>
</dict>
EOF
  install -d -m 700 /var/lib/cloudflare-warp
  [[ ! -e /var/lib/cloudflare-warp/mdm.xml ]] || backup="$(backup_file /var/lib/cloudflare-warp/mdm.xml warp-mdm)"
  install -m 600 "${candidate}" /var/lib/cloudflare-warp/mdm.xml
  [[ -z "${backup}" ]] || printf '原 MDM 备份: %s\n' "${backup}"
}


komari_connect_warp() {
  service_enable_start warp-svc
  warp-cli --accept-tos disconnect >/dev/null 2>&1 || true
  warp-cli --accept-tos registration delete >/dev/null 2>&1 || true
  service_restart warp-svc; sleep 3
  if warp-cli mdm refresh --help >/dev/null 2>&1; then
    warp-cli --accept-tos mdm refresh || true
  else
    log "当前 WARP 版本会在服务重启时加载 MDM 配置"
  fi
  sleep 3
  warp-cli --accept-tos connect || true; sleep 8
}


komari_verify_warp() {
  local endpoint="$1"
  warp-cli --accept-tos status || true
  log "检查 Komari 私网地址: ${endpoint}"
  curl -i --connect-timeout 10 --max-time 20 "${endpoint}" | sed -n '1,40p' || warn "私网地址不可达，请检查 WARP、Zero Trust 路由和 Service Token。"
}


install_komari_warp() {
  local team endpoint install_agent=1
  require_root; check_supported_os
  team="$(prompt_default "Cloudflare Zero Trust Team 名称" "${KOMARI_DEFAULT_TEAM}")"
  endpoint="$(prompt_default "Komari 私网连接地址" "${KOMARI_DEFAULT_PRIVATE_URL}")"
  prompt_yes_no "WARP 完成后是否继续安装/重装 Agent" 1 || install_agent=0
  printf '\n配置预览：\n  Team: %s\n  私网地址: %s\n  MDM: /var/lib/cloudflare-warp/mdm.xml\n  Service Token: 环境变量、%s 或安全输入\n' "${team}" "${endpoint}" "${KOMARI_TOKEN_ENV_FILE}"
  if [[ "${DEMO_MODE}" == 1 ]]; then printf '[演示] 使用主脚本内置流程，不下载 komari-warp-scripts 包装脚本。\n'; [[ "${install_agent}" == 1 ]] && komari_install_agent "${endpoint}"; return 0; fi
  prompt_yes_no "确认配置 WARP 私网" 0 || return 0
  log "安装 Cloudflare WARP"
  if ! komari_install_warp_client; then
    warn "WARP 未安装，未继续写入 MDM 或安装私网 Agent。"
    return 0
  fi
  komari_check_kernel || return 0
  komari_load_cf_token || return 1
  komari_write_mdm "${team}"
  komari_connect_warp
  komari_verify_warp "${endpoint}"
  [[ "${install_agent}" == 1 ]] && komari_install_agent "${endpoint}"
}


install_komari_standard() { require_root; check_supported_os; komari_install_agent "https://example.com"; }


komari_status() {
  printf '\nKomari Agent 状态：\n'; service_status_text komari-agent | sed -n '1,60p' || printf '未发现运行中的 Komari Agent。\n'
  printf '\nWARP 状态：\n'; command -v warp-cli >/dev/null 2>&1 && warp-cli --accept-tos status || printf '未安装或无法读取 warp-cli。\n'
}


komari_reconnect_warp() {
  require_root
  if [[ "${DEMO_MODE}" == 1 ]]; then printf '[演示] 将重启 warp-svc 并重新连接。\n'; return 0; fi
  command -v warp-cli >/dev/null 2>&1 || { warn "尚未安装 WARP。"; return 0; }
  service_restart warp-svc; warp-cli --accept-tos disconnect >/dev/null 2>&1 || true; warp-cli --accept-tos connect; sleep 5; warp-cli --accept-tos status || true
}


komari_menu() {
  local choice
  while true; do
    if is_alpine; then
      printf '\nAlpine Komari/WARP 管理：\n  1) 配置/修复 WARP 私网，并安装/重装 Agent\n  2) 查看 Agent/WARP 状态\n  3) 重连 WARP\n  0) 返回\n'
      read -r -p "请选择 [0]: " choice
      case "${choice:-0}" in 1) install_komari_warp ;; 2) komari_status ;; 3) komari_reconnect_warp ;; 0) return 0 ;; *) warn "未知选项。" ;; esac
      continue
    fi
    printf '\nKomari Agent 安装/管理：\n  1) 配置/修复 WARP 私网，并可继续安装 Agent（内置流程）\n  2) 安装/重装普通公网 Agent\n  3) 查看 Agent/WARP 状态\n  4) 重连 WARP\n  0) 返回\n'
    read -r -p "请选择 [0]: " choice
    case "${choice:-0}" in 1) install_komari_warp ;; 2) install_komari_standard ;; 3) komari_status ;; 4) komari_reconnect_warp ;; 0) return 0 ;; *) warn "未知选项。" ;; esac
  done
}

show_system_status() {
  local service_user

  log "系统"
  printf 'Hostname: %s\n' "$(hostname)"
  printf 'OS: '
  awk -F= '/^PRETTY_NAME=/{gsub(/^"|"$/, "", $2); print $2}' /etc/os-release
  printf 'Kernel: %s\n' "$(uname -r)"

  log "BBR"
  show_bbr_status

  log "Xray"
  if [[ -x "${XRAY_BIN}" ]]; then
    "${XRAY_BIN}" version | head -n 2
    if service_is_active xray; then printf 'Service: active\n'; else printf 'Service: inactive\n'; fi
    if [[ -r "${XRAY_CONFIG}" ]]; then
      service_user="$(xray_service_user)"
      printf 'Service user: %s\n' "${service_user}"
      if [[ "${EUID}" -eq 0 ]]; then
        validate_xray_config "${XRAY_CONFIG}" || true
      else
        printf '配置校验需要 root 权限。\n'
      fi
    fi
  else
    printf '未安装。\n'
  fi

  log "Komari/WARP"
  if service_is_active komari-agent; then printf 'Komari Agent: active\n'; else printf 'Komari Agent: inactive\n'; fi
  if service_is_active warp-svc; then printf 'WARP service: active\n'; else printf 'WARP service: inactive\n'; fi
}


current_script_path() {
  local path
  path="$(readlink -f -- "$0" 2>/dev/null || true)"
  [[ -n "${path}" && -f "${path}" ]] || return 1
  printf '%s' "${path}"
}


update_current_script() {
  local target candidate staged new_version

  require_root
  target="$(current_script_path)" \
    || { warn "无法确定当前 .sh 文件；通过管道或 /dev/fd 运行时不能自更新。"; return 1; }
  printf '当前脚本：%s\n更新来源：%s\n' "${target}" "${SCRIPT_UPDATE_URL}"
  if [[ "${DEMO_MODE}" == "1" ]]; then
    log "[预览] 将下载、校验并覆盖当前脚本；不会修改任何文件。"
    return 0
  fi
  prompt_yes_no "确认从 GitHub main 更新当前脚本" "0" \
    || { printf '已取消，脚本没有变化。\n'; return 0; }

  ensure_work_dir
  candidate="${WORK_DIR}/vps-manager.sh"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 --connect-timeout 15 "${SCRIPT_UPDATE_URL}" -o "${candidate}" \
      || { warn "从 GitHub 下载脚本失败。"; return 1; }
  elif command -v wget >/dev/null 2>&1; then
    wget -O "${candidate}" "${SCRIPT_UPDATE_URL}" \
      || { warn "从 GitHub 下载脚本失败。"; return 1; }
  else
    warn "缺少 curl 和 wget，请先运行初始化。"
    return 1
  fi

  bash -n "${candidate}" \
    || { warn "下载的脚本未通过 Bash 语法校验，当前脚本未改变。"; return 1; }
  grep -Fq 'SCRIPT_NAME="VPS Manager"' "${candidate}" \
    || { warn "下载内容不是预期的 VPS Manager 脚本，当前脚本未改变。"; return 1; }
  new_version="$(sed -n 's/^SCRIPT_VERSION="\([^"]*\)"/\1/p' "${candidate}" | head -n 1)"
  [[ -n "${new_version}" ]] \
    || { warn "无法识别下载脚本的版本，当前脚本未改变。"; return 1; }

  staged="$(mktemp "${target}.update.XXXXXX")" \
    || { warn "无法在当前脚本目录创建更新文件。"; return 1; }
  if ! install -m 700 "${candidate}" "${staged}"; then
    rm -f -- "${staged}"
    warn "无法准备更新文件。"
    return 1
  fi
  if ! mv -f -- "${staged}" "${target}"; then
    rm -f -- "${staged}"
    warn "无法覆盖当前脚本，原文件未改变。"
    return 1
  fi
  log "脚本已更新为 ${new_version}"
  printf '正在重新启动新脚本：%s\n' "${target}"
  cleanup
  WORK_DIR=""
  exec bash "${target}"
}


delete_current_script() {
  local target

  require_root
  target="$(current_script_path)" \
    || { warn "无法确定当前 .sh 文件；通过管道或 /dev/fd 运行时不能自删除。"; return 1; }
  printf '将只删除当前脚本：%s\n' "${target}"
  printf 'Xray、SSH、YAML、Komari 配置和备份都不会删除。\n'
  if [[ "${DEMO_MODE}" == "1" ]]; then
    log "[预览] 不会删除任何文件。"
    return 1
  fi
  prompt_yes_no "确认永久删除这个 .sh 文件" "0" \
    || { printf '已取消，脚本没有变化。\n'; return 1; }
  rm -f -- "${target}" \
    || { warn "删除脚本失败。"; return 1; }
  [[ ! -e "${target}" ]] \
    || { warn "脚本仍然存在，删除未完成。"; return 1; }
  log "已删除 ${target}"
  return 0
}

initialize_environment() {
  require_root
  install_base_tools

  if prompt_yes_no "基础工具已处理，是否继续开启 BBR" "1"; then
    enable_bbr
  else
    printf '已跳过 BBR。\n'
  fi

}


xray_setup_workflow() {
  require_root

  log "步骤 1/3：安装或升级 Xray"
  install_or_upgrade_xray
  if ! prompt_yes_no "Xray 安装步骤已完成，是否继续生成并应用配置" "1"; then
    printf '已在安装步骤结束。\n'
    return 0
  fi

  log "步骤 2/3：配置 Xray"
  configure_xray
  if ! prompt_yes_no "Xray 配置步骤已完成，是否继续显示密钥和 AWS YAML" "1"; then
    printf '已完成配置；结果保存在 %s 和 %s。\n' "${INFO_FILE}" "${YAML_FILE}"
    return 0
  fi

  log "步骤 3/3：输出配置结果"
  show_connection_info
}


show_help() {
  cat <<EOF
${SCRIPT_NAME} ${SCRIPT_VERSION}

用法:
  sudo bash $0          启动交互式管理菜单
  bash $0 --demo        无需 root 的预览模式，配置时输出完整 JSON
  bash $0 --version     显示版本
  bash $0 --help        显示帮助

完整模式支持 Debian/Ubuntu + systemd；Alpine + OpenRC 进入 BBR、Xray、Komari/WARP 受限模式。
SSH 加固会在 reload 后要求使用第二个终端验证，失败则自动恢复。
首次生成或更新 Xray 配置时，仅检测新增或链接变化的 SOCKS5 出口。
SSH 密钥与加固管理可以写入公钥，但不会在 VPS 上创建或显示客户端私钥。
YAML 管理仅重写 proxies 和 proxy-groups，并在确认前显示 diff。
EOF
}


show_banner() {
  printf '\n==================================================\n'
  printf ' %s  %s\n' "${SCRIPT_NAME}" "${SCRIPT_VERSION}"
  if [[ "${DEMO_MODE}" == "1" ]]; then
    printf ' 预览模式：不会修改系统\n'
  fi
  printf '==================================================\n'
}


main_menu() {
  local choice

  check_supported_os
  if is_alpine; then
    alpine_main_menu
    return 0
  fi
  while true; do
    show_banner
    printf '  1) 初始化环境：基础工具和可选 BBR\n'
    printf '  2) Xray 管理：安装、首次配置或更新现有配置\n'
    printf '  3) SSH 密钥与加固管理\n'
    printf '  4) YAML 管理：查看、导入节点、更新名称和分组\n'
    printf '  5) 安装/管理 Komari Agent\n'
    printf '  6) 状态检查\n'
    printf '  7) 从 GitHub 更新当前脚本\n'
    printf '  8) 删除当前 .sh 脚本\n'
    printf '  0) 退出\n'
    read -r -p "请选择: " choice
    case "${choice}" in
      1) initialize_environment; pause_screen ;;
      2) xray_management_menu; pause_screen ;;
      3) ssh_key_helper_menu; pause_screen ;;
      4) yaml_management_menu; pause_screen ;;
      5) komari_menu; pause_screen ;;
      6) show_system_status; pause_screen ;;
      7) update_current_script || true; pause_screen ;;
      8)
        if delete_current_script; then
          printf '脚本已删除，程序退出。\n'
          exit 0
        fi
        ;;
      0) printf '已退出。\n'; return 0 ;;
      *) warn "未知选项：${choice}" ;;
    esac
  done
}


alpine_main_menu() {
  local choice
  while true; do
    show_banner
    printf ' Alpine 受限模式：只提供本机需要的功能\n'
    printf '  1) 检查/开启 BBR（仅安装必要工具）\n'
    printf '  2) Xray 管理：安装、配置或更新\n'
    printf '  3) Komari + WARP 管理\n'
    printf '  4) 状态检查\n'
    printf '  7) 从 GitHub 更新当前脚本\n'
    printf '  8) 删除当前 .sh 脚本\n'
    printf '  0) 退出\n'
    read -r -p "请选择: " choice
    case "${choice}" in
      1) enable_bbr; pause_screen ;;
      2) xray_management_menu; pause_screen ;;
      3) komari_menu; pause_screen ;;
      4) show_system_status; pause_screen ;;
      7) update_current_script || true; pause_screen ;;
      8) if delete_current_script; then printf '脚本已删除，程序退出。\n'; exit 0; fi ;;
      0) printf '已退出。\n'; return 0 ;;
      *) warn "未知选项：${choice}" ;;
    esac
  done
}


while [[ $# -gt 0 ]]; do
  case "$1" in
    --demo)
      DEMO_MODE=1
      ;;
    --version)
      printf '%s %s\n' "${SCRIPT_NAME}" "${SCRIPT_VERSION}"
      exit 0
      ;;
    -h|--help)
      show_help
      exit 0
      ;;
    *)
      show_help
      die "未知参数：$1"
      ;;
  esac
  shift
done

main_menu
