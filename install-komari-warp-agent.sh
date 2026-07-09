#!/usr/bin/env bash
set -euo pipefail

TEAM_NAME="${TEAM_NAME:-uzikaisa}"
KOMARI_PRIVATE_URL="${KOMARI_PRIVATE_URL:-http://192.0.2.10:8080}"
TOKEN_ENV_FILE="${TOKEN_ENV_FILE:-/root/warp-token.env}"
SERVICE_MODE="${SERVICE_MODE:-warp}"
AUTO_CONNECT="${AUTO_CONNECT:-1}"
APT_FRONTEND="${DEBIAN_FRONTEND:-noninteractive}"

usage() {
  cat <<USAGE
Usage: sudo $0 [--upgrade-kernel] [--reboot-if-needed] [--no-connect]

Installs and configures Cloudflare WARP for Komari agent private-network access.

Required secret file:
  ${TOKEN_ENV_FILE}

Expected variables in the secret file:
  CF_ACCESS_CLIENT_ID='xxx.access'
  CF_ACCESS_CLIENT_SECRET='xxx'

Optional environment overrides:
  TEAM_NAME=${TEAM_NAME}
  KOMARI_PRIVATE_URL=${KOMARI_PRIVATE_URL}
  TOKEN_ENV_FILE=${TOKEN_ENV_FILE}

Options:
  --upgrade-kernel    Upgrade linux-image-amd64 if nftables kernel support is missing.
  --reboot-if-needed  Reboot automatically after kernel upgrade.
  --no-connect        Configure WARP but do not run warp-cli connect.
USAGE
}

UPGRADE_KERNEL=0
REBOOT_IF_NEEDED=0
CONNECT_WARP=1

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
  if [[ ! -f "${TOKEN_ENV_FILE}" ]]; then
    echo "Missing token env file: ${TOKEN_ENV_FILE}" >&2
    exit 1
  fi

  set -a
  # shellcheck disable=SC1090
  . "${TOKEN_ENV_FILE}"
  set +a

  if [[ -z "${CF_ACCESS_CLIENT_ID:-}" || -z "${CF_ACCESS_CLIENT_SECRET:-}" ]]; then
    echo "Missing CF_ACCESS_CLIENT_ID or CF_ACCESS_CLIENT_SECRET in ${TOKEN_ENV_FILE}" >&2
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
}

main "$@"
