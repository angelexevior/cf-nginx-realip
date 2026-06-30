#!/usr/bin/env bash
set -euo pipefail

# cf-nginx-realip — Cloudflare real IP restoration for nginx
# Auto-detects your nginx setup and installs everything needed.
#
# Usage:
#   sudo ./cfips-nginx.sh [options]
#
# Options:
#   --install              Full guided installation (auto-detect + configure + cron)
#   -p, --path PATH        nginx config directory (skip auto-detect)
#   -f, --file FILE        output filename inside PATH (default: cfips.conf)
#   -H, --header HEADER    real IP header (default: CF-Connecting-IP)
#   -e, --extra-cidr CIDR  additional trusted CIDR (repeatable)
#   -r, --reload           reload nginx after update
#   -n, --no-reload        skip nginx reload
#   --dry-run              print generated config without writing anything
#   --install-cron         install a weekly cron entry for this script and exit
#   -h, --help             show this help and exit

# ─── Colors ───────────────────────────────────────────────────────────────────
RED="\033[0;31m"; GREEN="\033[0;32m"; YELLOW="\033[1;33m"
CYAN="\033[0;36m"; BOLD="\033[1m"; RESET="\033[0m"

log_ok()     { echo -e "${GREEN}[OK]${RESET}  $*"; }
log_info()   { echo -e "${CYAN}[INFO]${RESET} $*"; }
log_warn()   { echo -e "${YELLOW}[WARN]${RESET} $*"; }
log_fail()   { echo -e "${RED}[FAIL]${RESET} $*" >&2; }
log_step()   { echo -e "\n${BOLD}>>> $*${RESET}"; }
die()        { log_fail "$*"; exit 1; }

ask() {
  # ask <prompt> <default>  — returns answer in $REPLY
  local prompt="$1" default="${2:-}"
  local hint=""
  [[ -n "$default" ]] && hint=" [${default}]"
  echo -en "${YELLOW}?${RESET} ${prompt}${hint}: "
  read -r REPLY
  [[ -z "$REPLY" ]] && REPLY="$default"
}

confirm() {
  # confirm <prompt>  — returns 0 for yes, 1 for no
  echo -en "${YELLOW}?${RESET} $* [Y/n]: "
  read -r REPLY
  [[ "${REPLY,,}" =~ ^(y|yes|)$ ]]
}

# ─── Defaults ─────────────────────────────────────────────────────────────────
NGINX_PATH=""
OUTPUT_FILE="cfips.conf"
REAL_IP_HEADER="CF-Connecting-IP"
EXTRA_CIDRS=()
RELOAD_MODE="auto"
DRY_RUN=false
INSTALL_CRON=false
INSTALL_MODE=false

CF_IPV4_URL="https://www.cloudflare.com/ips-v4"
CF_IPV6_URL="https://www.cloudflare.com/ips-v6"

# ─── Argument parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --install)       INSTALL_MODE=true;     shift   ;;
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

SCRIPT_PATH="$(realpath "$0")"

# ─── Auto-detect nginx binary ─────────────────────────────────────────────────
detect_nginx_bin() {
  local candidates=(
    nginx
    /usr/sbin/nginx
    /usr/local/nginx/sbin/nginx
    /usr/local/sbin/nginx
    /usr/local/openresty/nginx/sbin/nginx
    /opt/nginx/sbin/nginx
  )
  for bin in "${candidates[@]}"; do
    if command -v "$bin" >/dev/null 2>&1 || [[ -x "$bin" ]]; then
      echo "$bin"
      return 0
    fi
  done
  return 1
}

# ─── Auto-detect nginx config directory ───────────────────────────────────────
detect_nginx_conf_dir() {
  local nginx_bin="$1"

  # Ask nginx itself where its config file is
  local conf_file
  conf_file=$("$nginx_bin" -t 2>&1 | grep "configuration file" | awk '{print $NF}' | tr -d '.')
  if [[ -z "$conf_file" ]]; then
    conf_file=$("$nginx_bin" -V 2>&1 | grep -oP '(?<=--conf-path=)[^ ]+')
  fi

  if [[ -n "$conf_file" && -f "$conf_file" ]]; then
    dirname "$conf_file"
    return 0
  fi

  # Fallback: check common paths
  local common_paths=(
    /etc/nginx
    /usr/local/nginx/conf
    /usr/local/openresty/nginx/conf
    /opt/nginx/conf
    /usr/share/nginx/conf
  )
  for path in "${common_paths[@]}"; do
    if [[ -d "$path" && -f "$path/nginx.conf" ]]; then
      echo "$path"
      return 0
    fi
  done

  return 1
}

# ─── Find the main nginx.conf ─────────────────────────────────────────────────
find_nginx_conf() {
  local conf_dir="$1"
  if [[ -f "$conf_dir/nginx.conf" ]]; then
    echo "$conf_dir/nginx.conf"
  else
    find "$conf_dir" -maxdepth 1 -name "*.conf" | head -1
  fi
}

# ─── Check if include already exists in nginx.conf ────────────────────────────
include_exists() {
  local conf_file="$1" include_file="$2"
  grep -qE "^\s*include\s+.*${include_file}" "$conf_file" 2>/dev/null
}

# ─── Add include to nginx.conf after http { ───────────────────────────────────
add_include_to_nginx_conf() {
  local conf_file="$1" include_file="$2"
  # Insert after the first http { line
  if grep -q "^http\s*{" "$conf_file"; then
    sed -i "/^http\s*{/a\\    include ${include_file};" "$conf_file"
    return 0
  fi
  # Fallback: try http { with content on same line or with spaces
  if grep -qE "^\s*http\s*\{" "$conf_file"; then
    sed -i "/^\s*http\s*{/a\\    include ${include_file};" "$conf_file"
    return 0
  fi
  return 1
}

# ─── Detect reload method ─────────────────────────────────────────────────────
do_reload() {
  local nginx_bin="${1:-nginx}"
  if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet nginx 2>/dev/null; then
    systemctl reload nginx && log_ok "nginx reloaded via systemctl"
  elif [[ -x "$nginx_bin" ]]; then
    "$nginx_bin" -s reload && log_ok "nginx reloaded"
  else
    log_warn "Could not reload nginx automatically — please run: nginx -s reload"
  fi
}

# ─── Fetch Cloudflare IPs ─────────────────────────────────────────────────────
fetch_cloudflare_ips() {
  log_info "Fetching Cloudflare IPv4 ranges..."
  IPV4_LIST=$(curl --fail --silent --show-error --max-time 15 "$CF_IPV4_URL") \
    || die "Failed to fetch Cloudflare IPv4 list"

  log_info "Fetching Cloudflare IPv6 ranges..."
  IPV6_LIST=$(curl --fail --silent --show-error --max-time 15 "$CF_IPV6_URL") \
    || die "Failed to fetch Cloudflare IPv6 list"
}

# ─── Build config content ─────────────────────────────────────────────────────
build_config() {
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
}

# ─── Write config (atomic) ────────────────────────────────────────────────────
write_config() {
  local dest="$1" nginx_bin="${2:-nginx}"
  local dest_dir
  dest_dir="$(dirname "$dest")"

  [[ -d "$dest_dir" ]] || die "Target directory does not exist: $dest_dir"

  # Backup existing
  [[ -f "$dest" ]] && cp "$dest" "${dest}.bak"

  # Idempotency check
  if [[ -f "$dest" ]] && diff -q /tmp/cfips-nginx-staging.conf "$dest" >/dev/null 2>&1; then
    log_info "Cloudflare IP list unchanged — no update needed"
    rm -f /tmp/cfips-nginx-staging.conf
    return 1  # signal: no change
  fi

  mv /tmp/cfips-nginx-staging.conf "$dest"
  log_ok "Written: ${dest}"

  # Validate nginx config
  if command -v "$nginx_bin" >/dev/null 2>&1 || [[ -x "$nginx_bin" ]]; then
    if ! "$nginx_bin" -t 2>/dev/null; then
      log_fail "nginx config test failed — reverting"
      [[ -f "${dest}.bak" ]] && mv "${dest}.bak" "$dest"
      die "Aborting: invalid nginx config after writing ${dest}"
    fi
    log_ok "nginx config test passed"
  fi

  return 0  # signal: changed
}

# ─── Install cron ─────────────────────────────────────────────────────────────
install_cron() {
  local conf_dir="$1"
  local cron_line="@weekly root ${SCRIPT_PATH} --path ${conf_dir} --file ${OUTPUT_FILE} --reload"
  local cron_file="/etc/cron.d/cf-nginx-realip"

  if $DRY_RUN; then
    echo "Would write ${cron_file}:"
    echo "  ${cron_line}"
    return
  fi

  echo "$cron_line" > "$cron_file"
  chmod 644 "$cron_file"
  log_ok "Weekly cron installed: ${cron_file}"
}

# ══════════════════════════════════════════════════════════════════════════════
# INSTALL MODE — guided full setup
# ══════════════════════════════════════════════════════════════════════════════
run_install() {
  echo -e "\n${BOLD}╔══════════════════════════════════════════╗"
  echo -e "║   cf-nginx-realip  —  Guided Installer   ║"
  echo -e "╚══════════════════════════════════════════╝${RESET}\n"

  # Must be root
  [[ $EUID -eq 0 ]] || die "Installation requires root. Run: sudo $SCRIPT_PATH --install"

  # curl check
  command -v curl >/dev/null 2>&1 || die "curl is required but not installed. Install it first."

  # ── Step 1: Find nginx ──────────────────────────────────────────────────────
  log_step "Step 1/5 — Locating nginx"

  NGINX_BIN=""
  if NGINX_BIN=$(detect_nginx_bin); then
    NGINX_VER=$("$NGINX_BIN" -v 2>&1 | head -1)
    log_ok "Found nginx: ${NGINX_BIN} (${NGINX_VER})"
  else
    log_warn "Could not find nginx binary automatically."
    ask "Enter the full path to your nginx binary" "/usr/sbin/nginx"
    NGINX_BIN="$REPLY"
    [[ -x "$NGINX_BIN" ]] || die "Not executable: ${NGINX_BIN}"
    log_ok "Using nginx: ${NGINX_BIN}"
  fi

  # ── Step 2: Find config directory ──────────────────────────────────────────
  log_step "Step 2/5 — Locating nginx config directory"

  if [[ -z "$NGINX_PATH" ]]; then
    if NGINX_PATH=$(detect_nginx_conf_dir "$NGINX_BIN"); then
      log_ok "Detected nginx config directory: ${NGINX_PATH}"
    else
      log_warn "Could not detect nginx config directory automatically."
      ask "Enter the full path to your nginx config directory" "/etc/nginx"
      NGINX_PATH="$REPLY"
    fi
  else
    log_info "Using specified path: ${NGINX_PATH}"
  fi

  [[ -d "$NGINX_PATH" ]] || die "Directory not found: ${NGINX_PATH}"

  NGINX_CONF=$(find_nginx_conf "$NGINX_PATH")
  [[ -n "$NGINX_CONF" && -f "$NGINX_CONF" ]] || die "Could not find nginx.conf in ${NGINX_PATH}"
  log_ok "nginx.conf: ${NGINX_CONF}"

  DEST_FILE="${NGINX_PATH}/${OUTPUT_FILE}"

  # ── Step 3: Fetch + write cfips.conf ───────────────────────────────────────
  log_step "Step 3/5 — Fetching Cloudflare IP ranges"

  fetch_cloudflare_ips
  build_config

  IPV4_COUNT=$(echo "$IPV4_LIST" | grep -c '\.' || true)
  IPV6_COUNT=$(echo "$IPV6_LIST" | grep -c ':' || true)
  log_ok "Got ${IPV4_COUNT} IPv4 ranges and ${IPV6_COUNT} IPv6 ranges"

  write_config "$DEST_FILE" "$NGINX_BIN" || true

  # ── Step 4: Add include to nginx.conf ──────────────────────────────────────
  log_step "Step 4/5 — Configuring nginx.conf"

  if include_exists "$NGINX_CONF" "$OUTPUT_FILE"; then
    log_ok "include ${OUTPUT_FILE} already present in ${NGINX_CONF}"
  else
    log_info "Adding 'include ${OUTPUT_FILE};' to ${NGINX_CONF}"
    # Backup nginx.conf before modifying
    cp "$NGINX_CONF" "${NGINX_CONF}.bak.$(date +%Y%m%d%H%M%S)"
    if add_include_to_nginx_conf "$NGINX_CONF" "$OUTPUT_FILE"; then
      log_ok "Added include directive to ${NGINX_CONF}"
    else
      log_warn "Could not auto-add include directive."
      echo ""
      echo -e "  Please add this line manually inside the ${BOLD}http { }${RESET} block of:"
      echo -e "  ${BOLD}${NGINX_CONF}${RESET}"
      echo ""
      echo -e "      ${CYAN}include ${OUTPUT_FILE};${RESET}"
      echo ""
      confirm "Press Y once you have added it and saved the file" || die "Aborted."
    fi

    # Test the config
    if ! "$NGINX_BIN" -t 2>/dev/null; then
      log_fail "nginx config test failed after adding include. Restoring backup..."
      # Restore the most recent backup
      local latest_bak
      latest_bak=$(ls -t "${NGINX_CONF}.bak."* 2>/dev/null | head -1)
      [[ -n "$latest_bak" ]] && cp "$latest_bak" "$NGINX_CONF"
      die "Please add the include line manually and run this installer again."
    fi
    log_ok "nginx config test passed"
  fi

  # ── Step 5: Reload nginx + cron ────────────────────────────────────────────
  log_step "Step 5/5 — Reloading nginx and setting up auto-update"

  do_reload "$NGINX_BIN"

  # Install cron
  install_cron "$NGINX_PATH"

  # ── Summary ────────────────────────────────────────────────────────────────
  echo ""
  echo -e "${BOLD}╔══════════════════════════════════════════════════════╗"
  echo -e "║                  Installation Complete!             ║"
  echo -e "╚══════════════════════════════════════════════════════╝${RESET}"
  echo ""
  echo -e "  ${GREEN}✔${RESET} Config file:   ${BOLD}${DEST_FILE}${RESET}"
  echo -e "  ${GREEN}✔${RESET} nginx.conf:    ${BOLD}${NGINX_CONF}${RESET}"
  echo -e "  ${GREEN}✔${RESET} Auto-update:   ${BOLD}/etc/cron.d/cf-nginx-realip${RESET} (weekly)"
  echo -e "  ${GREEN}✔${RESET} nginx:         reloaded"
  echo ""
  echo -e "  ${CYAN}Verify it works:${RESET}"
  echo -e "  tail -f /var/log/nginx/access.log"
  echo -e "  (visitor IPs should now be real IPs, not Cloudflare ranges)"
  echo ""
}

# ══════════════════════════════════════════════════════════════════════════════
# UPDATE MODE — just refresh the IP list (used by cron)
# ══════════════════════════════════════════════════════════════════════════════
run_update() {
  # Detect nginx if not specified
  NGINX_BIN=$(detect_nginx_bin 2>/dev/null) || NGINX_BIN="nginx"

  if [[ -z "$NGINX_PATH" ]]; then
    if ! NGINX_PATH=$(detect_nginx_conf_dir "$NGINX_BIN" 2>/dev/null); then
      die "Could not detect nginx config directory. Run: sudo $SCRIPT_PATH --install"
    fi
  fi

  DEST_FILE="${NGINX_PATH}/${OUTPUT_FILE}"

  [[ -d "$NGINX_PATH" ]] || die "nginx config directory not found: ${NGINX_PATH}. Run: sudo $SCRIPT_PATH --install"

  command -v curl >/dev/null 2>&1 || die "curl is required but not installed"

  fetch_cloudflare_ips
  build_config

  if $DRY_RUN; then
    echo -e "\n${BOLD}--- dry-run output (not written) ---${RESET}"
    cat /tmp/cfips-nginx-staging.conf
    rm -f /tmp/cfips-nginx-staging.conf
    return
  fi

  CHANGED=true
  write_config "$DEST_FILE" "$NGINX_BIN" || CHANGED=false

  if $CHANGED; then
    case "$RELOAD_MODE" in
      yes)  do_reload "$NGINX_BIN" ;;
      no)   log_info "Skipping nginx reload (--no-reload)" ;;
      auto) do_reload "$NGINX_BIN" ;;
    esac
  fi

  log_ok "Done."
}

# ── Install-cron shortcut ──────────────────────────────────────────────────────
if $INSTALL_CRON; then
  [[ -n "$NGINX_PATH" ]] || die "Specify --path when using --install-cron directly"
  install_cron "$NGINX_PATH"
  exit 0
fi

# ── Route to correct mode ─────────────────────────────────────────────────────
if $INSTALL_MODE; then
  run_install
else
  run_update
fi
