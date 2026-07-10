#!/usr/bin/env bash
set -euo pipefail

TEAM_NAME="${TEAM_NAME:-uzikaisa}"
KOMARI_PRIVATE_URL="${KOMARI_PRIVATE_URL:-http://komari.example.internal:8080}"
TOKEN_ENV_FILE="${TOKEN_ENV_FILE:-/root/warp-token.env}"
SERVICE_MODE="${SERVICE_MODE:-warp}"
AUTO_CONNECT="${AUTO_CONNECT:-1}"
APT_FRONTEND="${DEBIAN_FRONTEND:-noninteractive}"
KOMARI_AGENT_INSTALL_SCRIPT_URL="${KOMARI_AGENT_INSTALL_SCRIPT_URL:-https://raw.githubusercontent.com/komari-monitor/komari-agent/refs/heads/main/install.sh}"
KOMARI_AGENT_MONTH_ROTATE="${KOMARI_AGENT_MONTH_ROTATE:-11}"
KOMARI_AGENT_DISABLE_WEB_SSH="${KOMARI_AGENT_DISABLE_WEB_SSH:-1}"
KOMARI_AGENT_GPU="${KOMARI_AGENT_GPU:-1}"
KOMARI_AGENT_AUTO_PUBLIC_IPV4="${KOMARI_AGENT_AUTO_PUBLIC_IPV4:-1}"

detect_target_home() {
  local target_user
  local detected_home
  target_user="${SUDO_USER:-}"

  if [[ -n "${target_user}" && "${target_user}" != "root" ]]; then
    getent passwd "${target_user}" | cut -d: -f6
    return
  fi

  detected_home="$(getent passwd | awk -F: '$3 >= 1000 && $3 < 60000 && $1 != "nobody" && $6 ~ "^/home/" {print $6; exit}')"
  if [[ -n "${detected_home}" ]]; then
    printf '%s' "${detected_home}"
    return
  fi

  printf '%s' "${HOME:-/root}"
}

TARGET_HOME="${TARGET_HOME:-$(detect_target_home)}"
KOMARI_AGENT_INSTALL_DIR="${KOMARI_AGENT_INSTALL_DIR:-${TARGET_HOME}/scripts/komari-agent}"

usage() {
  cat <<USAGE
用法: sudo $0 [--upgrade-kernel] [--reboot-if-needed] [--no-connect] [--install-agent] [--skip-agent]

安装并配置 Cloudflare WARP，让 Komari Agent 通过私网访问 Komari 服务端。

Cloudflare Service Token 读取顺序:
  1. 已存在的环境变量:
     CF_ACCESS_CLIENT_ID / CF_ACCESS_CLIENT_SECRET
  2. 如果存在，则读取环境变量文件:
     ${TOKEN_ENV_FILE}
  3. 交互式输入

可选环境变量覆盖:
  TEAM_NAME=${TEAM_NAME}
  KOMARI_PRIVATE_URL=${KOMARI_PRIVATE_URL}
  TOKEN_ENV_FILE=${TOKEN_ENV_FILE}
  KOMARI_AGENT_INSTALL_DIR=${KOMARI_AGENT_INSTALL_DIR}

参数:
  --upgrade-kernel    如果缺少 nftables 内核支持，则升级 linux-image-amd64。
  --reboot-if-needed  内核升级后自动重启。
  --no-connect        只配置 WARP，不执行 warp-cli connect。
  --install-agent     WARP 验证后直接安装/重装 Komari Agent。
  --skip-agent        不询问 Komari Agent 安装流程。
USAGE
}

UPGRADE_KERNEL=0
REBOOT_IF_NEEDED=0
CONNECT_WARP=1
AGENT_INSTALL_MODE="ask"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --upgrade-kernel)
      UPGRADE_KERNEL=1
      ;;
    --reboot-if-needed)
      REBOOT_IF_NEEDED=1
      ;;
    --no-connect)
      CONNECT_WARP=0
      ;;
    --install-agent)
      AGENT_INSTALL_MODE="install"
      ;;
    --skip-agent)
      AGENT_INSTALL_MODE="skip"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "未知参数: $1" >&2
      usage
      exit 2
      ;;
  esac
  shift
done

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "请使用 root 权限运行，例如 sudo $0。" >&2
    exit 1
  fi
}

log() {
  printf '\n[%s] %s\n' "$(date '+%F %T')" "$*"
}

prompt_with_default() {
  local prompt="$1"
  local default_value="$2"
  local value

  read -r -p "${prompt} [${default_value}]: " value
  if [[ -z "${value}" ]]; then
    value="${default_value}"
  fi
  printf '%s' "${value}"
}

prompt_yes_no() {
  local prompt="$1"
  local default_value="$2"
  local value
  local suffix

  if [[ "${default_value}" == "1" ]]; then
    suffix="Y/n"
  else
    suffix="y/N"
  fi

  read -r -p "${prompt} [${suffix}]: " value
  case "${value}" in
    y|Y|yes|YES|Yes) return 0 ;;
    n|N|no|NO|No) return 1 ;;
    "")
      [[ "${default_value}" == "1" ]]
      return
      ;;
    *)
      echo "请输入 yes/no，或直接回车使用默认值。" >&2
      prompt_yes_no "${prompt}" "${default_value}"
      ;;
  esac
}

normalize_path() {
  local input_path="$1"

  case "${input_path}" in
    "~")
      printf '%s' "${HOME}"
      ;;
    "~/"*)
      printf '%s/%s' "${HOME}" "${input_path#"~/"}"
      ;;
    /*)
      printf '%s' "${input_path}"
      ;;
    *)
      printf '%s/%s' "$(pwd -P)" "${input_path}"
      ;;
  esac
}

install_warp_repo() {
  local codename
  codename="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"
  if [[ -z "${codename}" ]]; then
    codename="$(lsb_release -cs)"
  fi

  export DEBIAN_FRONTEND="${APT_FRONTEND}"
  apt-get update
  apt-get install -y curl gpg lsb-release ca-certificates
  install -d -m 0755 /usr/share/keyrings
  curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
    | gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ ${codename} main" \
    > /etc/apt/sources.list.d/cloudflare-client.list
  apt-get update
  apt-get install -y cloudflare-warp
}

load_token_env() {
  if [[ -f "${TOKEN_ENV_FILE}" ]]; then
    set -a
    # shellcheck disable=SC1090
    . "${TOKEN_ENV_FILE}"
    set +a
  fi

  if [[ -z "${CF_ACCESS_CLIENT_ID:-}" ]]; then
    if [[ -t 0 ]]; then
      read -r -p "请输入 Cloudflare Access Client ID: " CF_ACCESS_CLIENT_ID
      export CF_ACCESS_CLIENT_ID
    else
      echo "缺少 CF_ACCESS_CLIENT_ID，且当前不是交互式终端。" >&2
      exit 1
    fi
  fi

  if [[ -z "${CF_ACCESS_CLIENT_SECRET:-}" ]]; then
    if [[ -t 0 ]]; then
      read -r -s -p "请输入 Cloudflare Access Client Secret（输入时不会显示）: " CF_ACCESS_CLIENT_SECRET
      echo
      export CF_ACCESS_CLIENT_SECRET
    else
      echo "缺少 CF_ACCESS_CLIENT_SECRET，且当前不是交互式终端。" >&2
      exit 1
    fi
  fi

  if [[ -z "${CF_ACCESS_CLIENT_ID}" || -z "${CF_ACCESS_CLIENT_SECRET}" ]]; then
    echo "Cloudflare Access Client ID/Secret 不能为空。" >&2
    exit 1
  fi
}

write_mdm() {
  install -d -m 700 /var/lib/cloudflare-warp
  cat > /var/lib/cloudflare-warp/mdm.xml <<EOF
<dict>
  <key>auth_client_id</key>
  <string>${CF_ACCESS_CLIENT_ID}</string>
  <key>auth_client_secret</key>
  <string>${CF_ACCESS_CLIENT_SECRET}</string>
  <key>auto_connect</key>
  <integer>${AUTO_CONNECT}</integer>
  <key>onboarding</key>
  <false/>
  <key>organization</key>
  <string>${TEAM_NAME}</string>
  <key>service_mode</key>
  <string>${SERVICE_MODE}</string>
</dict>
EOF
  chmod 600 /var/lib/cloudflare-warp/mdm.xml
}

nft_supported() {
  modprobe nf_tables >/dev/null 2>&1 || return 1
  nft list ruleset >/dev/null 2>&1 || return 1
}

maybe_upgrade_kernel() {
  if nft_supported; then
    log "nftables 内核支持正常。"
    return 0
  fi

  log "当前内核缺少 nftables 支持。"
  if [[ "${UPGRADE_KERNEL}" -ne 1 ]]; then
    cat >&2 <<EOF
缺少 nf_tables/nftables 支持时，WARP 可能无法连接。
如需自动安装新内核，请重新运行并添加 --upgrade-kernel。
EOF
    return 0
  fi

  log "仅升级 linux-image-amd64 内核包。"
  export DEBIAN_FRONTEND="${APT_FRONTEND}"
  apt-get update
  apt-get install -y --no-install-recommends linux-image-amd64

  if [[ "${REBOOT_IF_NEEDED}" -eq 1 ]]; then
    log "正在重启以加载新内核。"
    sync
    reboot
  else
    log "内核已升级。需要重启后 WARP 才能使用新内核。"
  fi
}

configure_warp() {
  systemctl enable --now warp-svc
  warp-cli --accept-tos disconnect >/dev/null 2>&1 || true
  warp-cli --accept-tos registration delete >/dev/null 2>&1 || true
  systemctl restart warp-svc
  sleep 5
  warp-cli --accept-tos mdm refresh || true
  sleep 5

  if [[ "${CONNECT_WARP}" -eq 1 ]]; then
    warp-cli --accept-tos connect || true
    sleep 10
  fi
}

verify() {
  log "WARP 状态"
  warp-cli --accept-tos status || true

  log "相关 WARP 配置"
  warp-cli --accept-tos settings list 2>&1 \
    | grep -E 'Organization|Mode:|Include mode|Exclude mode|Profile ID|Daemon Teams Auth|172\.31\.9\.160|Auto Connect' || true

  log "检查 Komari 私网地址: ${KOMARI_PRIVATE_URL}"
  curl -i --connect-timeout 10 --max-time 20 "${KOMARI_PRIVATE_URL}" | sed -n '1,40p'

  log "资源占用"
  free -h
  ps -eo pid,comm,%cpu,%mem,rss --sort=-rss | head -n 15
}

detect_public_ipv4() {
  local ip
  ip="$(curl -4 -fsS --max-time 10 https://ifconfig.me 2>/dev/null || true)"
  if [[ -z "${ip}" ]]; then
    ip="$(curl -4 -fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)"
  fi
  printf '%s' "${ip}"
}

install_komari_agent() {
  local token endpoint install_dir month_rotate public_ipv4
  local disable_web_ssh gpu auto_public_ipv4
  local install_args

  if [[ ! -t 0 && -z "${KOMARI_AGENT_TOKEN:-}" ]]; then
    echo "非交互模式安装 Komari Agent 时，必须提供 KOMARI_AGENT_TOKEN。" >&2
    exit 1
  fi

  endpoint="${KOMARI_PRIVATE_URL}"
  install_dir="${KOMARI_AGENT_INSTALL_DIR}"
  month_rotate="${KOMARI_AGENT_MONTH_ROTATE}"
  disable_web_ssh="${KOMARI_AGENT_DISABLE_WEB_SSH}"
  gpu="${KOMARI_AGENT_GPU}"
  auto_public_ipv4="${KOMARI_AGENT_AUTO_PUBLIC_IPV4}"

  if [[ -z "${KOMARI_AGENT_TOKEN:-}" ]]; then
    read -r -s -p "请输入 Komari Client Token（输入时不会显示）: " token
    echo
  else
    token="${KOMARI_AGENT_TOKEN}"
  fi

  if [[ -z "${token}" ]]; then
    echo "Komari Client Token 不能为空。" >&2
    exit 1
  fi

  if [[ -t 0 ]]; then
    endpoint="$(prompt_with_default "Komari 连接地址" "${endpoint}")"
    install_dir="$(prompt_with_default "Komari Agent 安装目录" "${install_dir}")"
    month_rotate="$(prompt_with_default "流量统计重置日" "${month_rotate}")"

    install_dir="$(normalize_path "${install_dir}")"

    if prompt_yes_no "是否禁用 Web SSH（直接回车默认：是）" "${disable_web_ssh}"; then
      disable_web_ssh=1
    else
      disable_web_ssh=0
    fi

    if prompt_yes_no "是否启用 GPU 监控（直接回车默认：是）" "${gpu}"; then
      gpu=1
    else
      gpu=0
    fi

    if prompt_yes_no "是否自动探测公网 IPv4 并写入 --custom-ipv4（直接回车默认：是）" "${auto_public_ipv4}"; then
      auto_public_ipv4=1
    else
      auto_public_ipv4=0
    fi
  else
    install_dir="$(normalize_path "${install_dir}")"
  fi

  install_args=(-e "${endpoint}" -t "${token}" --install-dir "${install_dir}" --month-rotate "${month_rotate}")

  if [[ "${disable_web_ssh}" == "1" ]]; then
    install_args+=(--disable-web-ssh)
  fi

  if [[ "${gpu}" == "1" ]]; then
    install_args+=(--gpu)
  fi

  if [[ "${auto_public_ipv4}" == "1" ]]; then
    public_ipv4="$(detect_public_ipv4)"
    if [[ -n "${public_ipv4}" ]]; then
      install_args+=(--custom-ipv4 "${public_ipv4}")
      log "已探测到公网 IPv4: ${public_ipv4}"
    else
      log "公网 IPv4 探测失败，将不带 --custom-ipv4 安装。"
    fi
  fi

  log "开始安装 Komari Agent"
  log "连接地址: ${endpoint}"
  log "安装目录: ${install_dir}"
  wget -qO- "${KOMARI_AGENT_INSTALL_SCRIPT_URL}" | bash -s -- "${install_args[@]}"

  log "Komari Agent 状态"
  systemctl status komari-agent --no-pager -l | sed -n '1,80p' || true
}

maybe_install_komari_agent() {
  local choice

  case "${AGENT_INSTALL_MODE}" in
    skip)
      log "跳过 Komari Agent 安装。"
      return 0
      ;;
    install)
      install_komari_agent
      return 0
      ;;
  esac

  if [[ ! -t 0 ]]; then
    log "检测到非交互运行，跳过 Komari Agent 安装。如需强制安装，请添加 --install-agent。"
    return 0
  fi

  echo
  echo "WARP 私网接入配置已完成。"
  echo "请选择下一步："
  echo "  1) 继续安装/重装 Komari Agent"
  echo "  2) 跳过 Komari Agent 安装"
  read -r -p "请输入选项 [2]: " choice

  case "${choice:-2}" in
    1)
      install_komari_agent
      ;;
    2)
      log "跳过 Komari Agent 安装。"
      ;;
    *)
      echo "未知选项: ${choice}" >&2
      return 2
      ;;
  esac
}

main() {
  need_root
  log "安装 Cloudflare WARP 客户端"
  install_warp_repo

  log "检查内核支持"
  maybe_upgrade_kernel

  log "读取 Service Token，环境变量文件: ${TOKEN_ENV_FILE}"
  load_token_env

  log "写入 WARP MDM 配置"
  write_mdm

  log "配置 WARP"
  configure_warp

  verify
  maybe_install_komari_agent
}

main "$@"
