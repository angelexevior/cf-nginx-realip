#!/usr/bin/env bash
set -euo pipefail

# cf-nginx-realip — Cloudflare real IP restoration for nginx
# Fetches Cloudflare IPv4+IPv6 ranges and writes a trusted-proxy include file.
# Run once manually, then schedule via cron (@daily or @weekly).
#
# Usage:
#   ./cfips-nginx.sh [options]
#
# Options:
#   -p, --path PATH        nginx config directory (default: /etc/nginx)
#   -f, --file FILE        output filename inside PATH (default: cfips.conf)
#   -H, --header HEADER    real IP header (default: CF-Connecting-IP)
#   -e, --extra-cidr CIDR  additional trusted CIDR (repeatable)
#   -r, --reload           reload nginx after update (default: auto-detect)
#   -n, --no-reload        skip nginx reload even on changes
#   --dry-run              print generated config; do not write files or reload
#   --install-cron         install a weekly cron entry for this script and exit
#   -h, --help             show this help and exit

# ─── Defaults ────────────────────────────────────────────────────────────────
NGINX_PATH="/etc/nginx"
OUTPUT_FILE="cfips.conf"
REAL_IP_HEADER="CF-Connecting-IP"
EXTRA_CIDRS=()
RELOAD_MODE="auto"   # auto | yes | no
DRY_RUN=false
INSTALL_CRON=false

CF_IPV4_URL="https://www.cloudflare.com/ips-v4"
CF_IPV6_URL="https://www.cloudflare.com/ips-v6"

# ─── Colors ───────────────────────────────────────────────────────────────────
RED="\033[0;31m"; GREEN="\033[0;32m"; YELLOW="\033[1;33m"
CYAN="\033[0;36m"; BOLD="\033[1m"; RESET="\033[0m"

log_ok()   { echo -e "${GREEN}[OK]${RESET}  $*"; }
log_info() { echo -e "${CYAN}[INFO]${RESET} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${RESET} $*"; }
log_fail() { echo -e "${RED}[FAIL]${RESET} $*" >&2; }

die() { log_fail "$*"; exit 1; }

# ─── Argument parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--path)       NGINX_PATH="$2";       shift 2 ;;
    -f|--file)       OUTPUT_FILE="$2";      shift 2 ;;
    -H|--header)     REAL_IP_HEADER="$2";   shift 2 ;;
    -e|--extra-cidr) EXTRA_CIDRS+=("$2");   shift 2 ;;
    -r|--reload)     RELOAD_MODE="yes";     shift   ;;
    -n|--no-reload)  RELOAD_MODE="no";      shift   ;;
    --dry-run)       DRY_RUN=true;          shift   ;;
    --install-cron)  INSTALL_CRON=true;     shift   ;;
    -h|--help)
      sed -n '/^# Usage:/,/^[^#]/{ /^#/{ s/^# \{0,2\}//; p }; /^[^#]/q }' "$0"
      exit 0
      ;;
    *) die "Unknown option: $1. Use --help for usage." ;;
  esac
done

DEST_FILE="${NGINX_PATH}/${OUTPUT_FILE}"

# ─── Install cron ─────────────────────────────────────────────────────────────
if $INSTALL_CRON; then
  SCRIPT_PATH="$(realpath "$0")"
  CRON_LINE="@weekly root ${SCRIPT_PATH} --path ${NGINX_PATH} --file ${OUTPUT_FILE} --reload"
  CRON_FILE="/etc/cron.d/cf-nginx-realip"
  if $DRY_RUN; then
    echo "Would write to ${CRON_FILE}:"
    echo "${CRON_LINE}"
  else
    echo "${CRON_LINE}" > "${CRON_FILE}"
    chmod 644 "${CRON_FILE}"
    log_ok "Cron entry installed at ${CRON_FILE}"
  fi
  exit 0
fi

# ─── Validation ───────────────────────────────────────────────────────────────
if ! $DRY_RUN; then
  [[ -d "$NGINX_PATH" ]] || die "nginx config directory not found: ${NGINX_PATH}"
  command -v nginx >/dev/null 2>&1 || log_warn "nginx not found in PATH — skipping config test"
fi

command -v curl >/dev/null 2>&1 || die "curl is required but not installed"

# ─── Fetch Cloudflare IPs ─────────────────────────────────────────────────────
log_info "Fetching Cloudflare IPv4 ranges..."
IPV4_LIST=$(curl --fail --silent --show-error --max-time 15 "$CF_IPV4_URL") \
  || die "Failed to fetch Cloudflare IPv4 list from ${CF_IPV4_URL}"

log_info "Fetching Cloudflare IPv6 ranges..."
IPV6_LIST=$(curl --fail --silent --show-error --max-time 15 "$CF_IPV6_URL") \
  || die "Failed to fetch Cloudflare IPv6 list from ${CF_IPV6_URL}"

# ─── Build config ─────────────────────────────────────────────────────────────
{
  echo "# Cloudflare real-IP configuration"
  echo "# Generated: $(date -u '+%Y-%m-%d %H:%M:%S UTC') by cf-nginx-realip"
  echo "# Source: ${CF_IPV4_URL} | ${CF_IPV6_URL}"
  echo ""
  echo "# Cloudflare IPv4"
  while IFS= read -r cidr; do
    [[ -n "$cidr" ]] && echo "set_real_ip_from ${cidr};"
  done <<< "$IPV4_LIST"
  echo ""
  echo "# Cloudflare IPv6"
  while IFS= read -r cidr; do
    [[ -n "$cidr" ]] && echo "set_real_ip_from ${cidr};"
  done <<< "$IPV6_LIST"
  if [[ ${#EXTRA_CIDRS[@]} -gt 0 ]]; then
    echo ""
    echo "# Additional trusted proxies"
    for cidr in "${EXTRA_CIDRS[@]}"; do
      echo "set_real_ip_from ${cidr};"
    done
  fi
  echo ""
  echo "real_ip_header ${REAL_IP_HEADER};"
  echo "real_ip_recursive on;"
} > /tmp/cfips-nginx-staging.conf

# ─── Dry run ──────────────────────────────────────────────────────────────────
if $DRY_RUN; then
  echo -e "\n${BOLD}--- dry-run output (not written) ---${RESET}"
  cat /tmp/cfips-nginx-staging.conf
  rm -f /tmp/cfips-nginx-staging.conf
  exit 0
fi

# ─── Idempotency check ────────────────────────────────────────────────────────
if [[ -f "$DEST_FILE" ]] && diff -q /tmp/cfips-nginx-staging.conf "$DEST_FILE" >/dev/null 2>&1; then
  log_info "Cloudflare IP list unchanged — no update needed"
  rm -f /tmp/cfips-nginx-staging.conf
  exit 0
fi

# ─── Atomic write ─────────────────────────────────────────────────────────────
mv /tmp/cfips-nginx-staging.conf "$DEST_FILE"
log_ok "Written: ${DEST_FILE}"

# ─── nginx config test ────────────────────────────────────────────────────────
if command -v nginx >/dev/null 2>&1; then
  if ! nginx -t 2>/dev/null; then
    log_fail "nginx config test failed — reverting to previous config"
    # Restore backup if it exists
    [[ -f "${DEST_FILE}.bak" ]] && mv "${DEST_FILE}.bak" "$DEST_FILE"
    die "Aborting reload due to invalid nginx config"
  fi
  log_ok "nginx config test passed"
fi

# ─── Reload nginx ─────────────────────────────────────────────────────────────
do_reload() {
  if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet nginx 2>/dev/null; then
    systemctl reload nginx && log_ok "nginx reloaded via systemctl"
  elif command -v nginx >/dev/null 2>&1; then
    nginx -s reload && log_ok "nginx reloaded via nginx -s reload"
  else
    log_warn "Could not detect nginx reload method — please reload nginx manually"
  fi
}

case "$RELOAD_MODE" in
  yes)  do_reload ;;
  no)   log_info "Skipping nginx reload (--no-reload)" ;;
  auto)
    if command -v nginx >/dev/null 2>&1; then
      do_reload
    else
      log_warn "nginx not found — skipping reload. Add --reload to force."
    fi
    ;;
esac

log_ok "Done. Add 'include ${OUTPUT_FILE};' to your nginx http block if not already present."
