#!/usr/bin/env bash
set -euo pipefail

TEAM_NAME="${TEAM_NAME:-uzikaisa}"
KOMARI_PRIVATE_URL="${KOMARI_PRIVATE_URL:-http://komari.example.internal:8080}"
TOKEN_ENV_FILE="${TOKEN_ENV_FILE:-/root/warp-token.env}"
SERVICE_MODE="${SERVICE_MODE:-warp}"
AUTO_CONNECT="${AUTO_CONNECT:-1}"
APT_FRONTEND="${DEBIAN_FRONTEND:-noninteractive}"
KOMARI_AGENT_INSTALL_SCRIPT_URL="${KOMARI_AGENT_INSTALL_SCRIPT_URL:-https://raw.githubusercontent.com/komari-monitor/komari-agent/refs/heads/main/install.sh}"
KOMARI_AGENT_INSTALL_DIR="${KOMARI_AGENT_INSTALL_DIR:-/home/ubuntu/repos/komari/komari-agent}"
KOMARI_AGENT_MONTH_ROTATE="${KOMARI_AGENT_MONTH_ROTATE:-11}"
KOMARI_AGENT_DISABLE_WEB_SSH="${KOMARI_AGENT_DISABLE_WEB_SSH:-1}"
KOMARI_AGENT_GPU="${KOMARI_AGENT_GPU:-1}"
KOMARI_AGENT_AUTO_PUBLIC_IPV4="${KOMARI_AGENT_AUTO_PUBLIC_IPV4:-1}"

usage() {
  cat <<USAGE
Usage: sudo $0 [--upgrade-kernel] [--reboot-if-needed] [--no-connect] [--install-agent] [--skip-agent]

Installs and configures Cloudflare WARP for Komari agent private-network access.

Credential input order:
  1. Existing environment variables:
     CF_ACCESS_CLIENT_ID / CF_ACCESS_CLIENT_SECRET
  2. Optional env file, if present:
     ${TOKEN_ENV_FILE}
  3. Interactive prompt

Optional environment overrides:
  TEAM_NAME=${TEAM_NAME}
  KOMARI_PRIVATE_URL=${KOMARI_PRIVATE_URL}
  TOKEN_ENV_FILE=${TOKEN_ENV_FILE}

Options:
  --upgrade-kernel    Upgrade linux-image-amd64 if nftables kernel support is missing.
  --reboot-if-needed  Reboot automatically after kernel upgrade.
  --no-connect        Configure WARP but do not run warp-cli connect.
  --install-agent      Install/reinstall Komari Agent after WARP verification.
  --skip-agent         Do not offer Komari Agent installation.
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
      echo "Unknown option: $1" >&2
      usage
      exit 2
      ;;
  esac
  shift
done

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Please run as root." >&2
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
      echo "Please answer yes or no." >&2
      prompt_yes_no "${prompt}" "${default_value}"
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
      read -r -p "Cloudflare Access Client ID: " CF_ACCESS_CLIENT_ID
      export CF_ACCESS_CLIENT_ID
    else
      echo "Missing CF_ACCESS_CLIENT_ID and stdin is not interactive." >&2
      exit 1
    fi
  fi

  if [[ -z "${CF_ACCESS_CLIENT_SECRET:-}" ]]; then
    if [[ -t 0 ]]; then
      read -r -s -p "Cloudflare Access Client Secret: " CF_ACCESS_CLIENT_SECRET
      echo
      export CF_ACCESS_CLIENT_SECRET
    else
      echo "Missing CF_ACCESS_CLIENT_SECRET and stdin is not interactive." >&2
      exit 1
    fi
  fi

  if [[ -z "${CF_ACCESS_CLIENT_ID}" || -z "${CF_ACCESS_CLIENT_SECRET}" ]]; then
    echo "Cloudflare Access Client ID/Secret cannot be empty." >&2
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
    log "nftables kernel support is available."
    return 0
  fi

  log "nftables kernel support is not available."
  if [[ "${UPGRADE_KERNEL}" -ne 1 ]]; then
    cat >&2 <<EOF
WARP may fail to connect without nf_tables/nftables support.
Re-run with --upgrade-kernel to install the latest linux-image-amd64.
EOF
    return 0
  fi

  log "Upgrading linux-image-amd64 only."
  export DEBIAN_FRONTEND="${APT_FRONTEND}"
  apt-get update
  apt-get install -y --no-install-recommends linux-image-amd64

  if [[ "${REBOOT_IF_NEEDED}" -eq 1 ]]; then
    log "Rebooting to load the upgraded kernel."
    sync
    reboot
  else
    log "Kernel upgraded. Reboot is required before WARP can use the new kernel."
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
  log "WARP status"
  warp-cli --accept-tos status || true

  log "Relevant WARP settings"
  warp-cli --accept-tos settings list 2>&1 \
    | grep -E 'Organization|Mode:|Include mode|Exclude mode|Profile ID|Daemon Teams Auth|172\.31\.9\.160|Auto Connect' || true

  log "Komari private URL check: ${KOMARI_PRIVATE_URL}"
  curl -i --connect-timeout 10 --max-time 20 "${KOMARI_PRIVATE_URL}" | sed -n '1,40p'

  log "Resource usage"
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
    echo "Cannot install Komari Agent non-interactively without KOMARI_AGENT_TOKEN." >&2
    exit 1
  fi

  endpoint="${KOMARI_PRIVATE_URL}"
  install_dir="${KOMARI_AGENT_INSTALL_DIR}"
  month_rotate="${KOMARI_AGENT_MONTH_ROTATE}"
  disable_web_ssh="${KOMARI_AGENT_DISABLE_WEB_SSH}"
  gpu="${KOMARI_AGENT_GPU}"
  auto_public_ipv4="${KOMARI_AGENT_AUTO_PUBLIC_IPV4}"

  if [[ -z "${KOMARI_AGENT_TOKEN:-}" ]]; then
    read -r -s -p "Komari client token: " token
    echo
  else
    token="${KOMARI_AGENT_TOKEN}"
  fi

  if [[ -z "${token}" ]]; then
    echo "Komari client token cannot be empty." >&2
    exit 1
  fi

  if [[ -t 0 ]]; then
    endpoint="$(prompt_with_default "Komari endpoint" "${endpoint}")"
    install_dir="$(prompt_with_default "Komari Agent install dir" "${install_dir}")"
    month_rotate="$(prompt_with_default "Traffic reset day" "${month_rotate}")"

    if prompt_yes_no "Disable Web SSH" "${disable_web_ssh}"; then
      disable_web_ssh=1
    else
      disable_web_ssh=0
    fi

    if prompt_yes_no "Enable GPU reporting" "${gpu}"; then
      gpu=1
    else
      gpu=0
    fi

    if prompt_yes_no "Auto-detect public IPv4 and pass --custom-ipv4" "${auto_public_ipv4}"; then
      auto_public_ipv4=1
    else
      auto_public_ipv4=0
    fi
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
      log "Detected public IPv4: ${public_ipv4}"
    else
      log "Public IPv4 detection failed; installing without --custom-ipv4."
    fi
  fi

  log "Installing Komari Agent"
  log "Endpoint: ${endpoint}"
  log "Install dir: ${install_dir}"
  wget -qO- "${KOMARI_AGENT_INSTALL_SCRIPT_URL}" | bash -s -- "${install_args[@]}"

  log "Komari Agent status"
  systemctl status komari-agent --no-pager -l | sed -n '1,80p' || true
}

maybe_install_komari_agent() {
  local choice

  case "${AGENT_INSTALL_MODE}" in
    skip)
      log "Skipping Komari Agent installation."
      return 0
      ;;
    install)
      install_komari_agent
      return 0
      ;;
  esac

  if [[ ! -t 0 ]]; then
    log "Non-interactive run detected; skipping Komari Agent installation. Re-run with --install-agent to force it."
    return 0
  fi

  echo
  echo "WARP private-network setup is complete."
  echo "Choose the next step:"
  echo "  1) Continue to install/reinstall Komari Agent"
  echo "  2) Skip Komari Agent installation"
  read -r -p "Selection [2]: " choice

  case "${choice:-2}" in
    1)
      install_komari_agent
      ;;
    2)
      log "Skipping Komari Agent installation."
      ;;
    *)
      echo "Unknown selection: ${choice}" >&2
      return 2
      ;;
  esac
}

main() {
  need_root
  log "Installing Cloudflare WARP client"
  install_warp_repo

  log "Checking kernel support"
  maybe_upgrade_kernel

  log "Loading service token from ${TOKEN_ENV_FILE}"
  load_token_env

  log "Writing WARP MDM config"
  write_mdm

  log "Configuring WARP"
  configure_warp

  verify
  maybe_install_komari_agent
}

main "$@"
