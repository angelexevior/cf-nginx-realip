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
#   -h, --help             show this help and exit

# ─── Colors ───────────────────────────────────────────────────────────────────
RED="\033[0;31m"; GREEN="\033[0;32m"; YELLOW="\033[1;33m"
CYAN="\033[0;36m"; BOLD="\033[1m"; RESET="\033[0m"

log_ok()   { echo -e "${GREEN}[OK]${RESET}  $*"; }
log_info() { echo -e "${CYAN}[INFO]${RESET} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${RESET} $*"; }
log_fail() { echo -e "${RED}[FAIL]${RESET} $*" >&2; }
log_step() { echo -e "\n${BOLD}>>> $*${RESET}"; }
die()      { log_fail "$*"; exit 1; }

ask() {
  local prompt="$1" default="${2:-}" hint=""
  [[ -n "$default" ]] && hint=" [${default}]"
  echo -en "${YELLOW}?${RESET} ${prompt}${hint}: "
  read -r REPLY
  [[ -z "$REPLY" ]] && REPLY="$default"
}

confirm() {
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
    -h|--help)
      sed -n '/^# Usage:/,/^[^#]/{ /^#/{ s/^# \{0,2\}//; p }; /^[^#]/q }' "$0"
      exit 0
      ;;
    *) die "Unknown option: $1. Use --help for usage." ;;
  esac
done

SCRIPT_PATH="$(realpath "$0")"

# ─── Find ALL nginx binaries on this system ───────────────────────────────────
find_all_nginx_bins() {
  local found=()

  # 1. The actually-running master process (most reliable)
  local running
  running=$(ps aux 2>/dev/null \
    | awk '/nginx: master process/ && !/awk/{
        for(i=1;i<=NF;i++) if($i ~ /^\/.*nginx/) { gsub(/:$/,"",$i); print $i; exit }
      }')
  [[ -n "$running" && -x "$running" ]] && found+=("$running")

  # 2. Known install paths
  local candidates=(
    /usr/local/nginx/sbin/nginx
    /usr/local/openresty/nginx/sbin/nginx
    /usr/local/sbin/nginx
    /opt/nginx/sbin/nginx
    /usr/sbin/nginx
    /sbin/nginx
  )
  for bin in "${candidates[@]}"; do
    [[ -x "$bin" ]] || continue
    # Skip if already in list
    local dup=false
    for f in "${found[@]:-}"; do [[ "$f" == "$bin" ]] && dup=true && break; done
    $dup || found+=("$bin")
  done

  # 3. Anything in PATH called nginx not already listed
  local path_nginx
  path_nginx=$(command -v nginx 2>/dev/null || true)
  if [[ -n "$path_nginx" && -x "$path_nginx" ]]; then
    local dup=false
    for f in "${found[@]:-}"; do [[ "$f" == "$path_nginx" ]] && dup=true && break; done
    $dup || found+=("$path_nginx")
  fi

  printf '%s\n' "${found[@]:-}"
}

# ─── Auto-detect the nginx binary that is actually running ────────────────────
detect_nginx_bin() {
  local all_bins=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && all_bins+=("$line")
  done < <(find_all_nginx_bins)

  case "${#all_bins[@]}" in
    0) return 1 ;;
    1) echo "${all_bins[0]}"; return 0 ;;
    *)
      # Multiple nginx installs found — let the user choose
      echo "__MULTIPLE__"
      printf '%s\n' "${all_bins[@]}"
      return 0
      ;;
  esac
}

# ─── Derive config directory from the nginx binary ───────────────────────────
detect_nginx_conf_dir() {
  local nginx_bin="$1"

  # nginx -V prints --conf-path= which is definitive
  local conf_path
  conf_path=$("$nginx_bin" -V 2>&1 | grep -oP '(?<=--conf-path=)\S+')
  if [[ -n "$conf_path" && -f "$conf_path" ]]; then
    dirname "$conf_path"; return 0
  fi

  # nginx -t also prints the config file being tested
  conf_path=$("$nginx_bin" -t 2>&1 | awk '/configuration file/{print $NF}' | tr -d '.')
  if [[ -n "$conf_path" && -f "$conf_path" ]]; then
    dirname "$conf_path"; return 0
  fi

  return 1
}

# ─── Check if include already exists ─────────────────────────────────────────
include_exists() {
  grep -qE "^\s*include\s+.*${2}" "$1" 2>/dev/null
}

# ─── Inject include into the http { } block ──────────────────────────────────
add_include_to_nginx_conf() {
  local conf_file="$1" include_file="$2"
  # Match any variation of:  http {   http{   http   {
  if grep -qE '^\s*http\s*\{' "$conf_file"; then
    sed -i -E "0,/^\s*http\s*\{/s//&\n    include ${include_file};/" "$conf_file"
    return 0
  fi
  return 1
}

# ─── Reload the correct nginx instance ───────────────────────────────────────
do_reload() {
  local nginx_bin="$1"

  # Prefer the binary we already know is the right one
  if [[ -x "$nginx_bin" ]]; then
    "$nginx_bin" -s reload && { log_ok "nginx reloaded"; return 0; }
  fi

  # Fallback to systemctl only if it manages a service called nginx
  if command -v systemctl &>/dev/null && systemctl is-active --quiet nginx 2>/dev/null; then
    systemctl reload nginx && { log_ok "nginx reloaded via systemctl"; return 0; }
  fi

  log_warn "Could not reload nginx automatically — run manually: ${nginx_bin} -s reload"
}

# ─── Remove old cf-realip includes from nginx.conf and delete old files ───────
cleanup_old_install() {
  local nginx_conf="$1" conf_dir="$2"

  # Patterns that previous versions of this script may have left behind
  local old_files=("cfips.txt" "cfips.conf" "cloudflare-ips.conf" "cf-ips.conf")
  local found_old=false

  for old_file in "${old_files[@]}"; do
    local old_path="${conf_dir}/${old_file}"

    # Remove include line from nginx.conf
    if grep -qE "^\s*include\s+.*${old_file}" "$nginx_conf" 2>/dev/null; then
      sed -i -E "/^\s*include\s+.*${old_file}\s*;/d" "$nginx_conf"
      log_info "Removed old include '${old_file}' from ${nginx_conf}"
      found_old=true
    fi

    # Delete the old file
    if [[ -f "$old_path" && "$old_file" != "$OUTPUT_FILE" ]]; then
      rm -f "$old_path"
      log_info "Deleted old config file: ${old_path}"
      found_old=true
    fi
  done

  $found_old && log_ok "Old installation cleaned up"
  return 0
}

# ─── Fetch Cloudflare IPs ─────────────────────────────────────────────────────
fetch_cloudflare_ips() {
  log_info "Fetching Cloudflare IPv4 ranges..."
  IPV4_LIST=$(curl --fail --silent --show-error --max-time 15 "$CF_IPV4_URL") \
    || die "Failed to fetch Cloudflare IPv4 list from ${CF_IPV4_URL}"

  log_info "Fetching Cloudflare IPv6 ranges..."
  IPV6_LIST=$(curl --fail --silent --show-error --max-time 15 "$CF_IPV6_URL") \
    || die "Failed to fetch Cloudflare IPv6 list from ${CF_IPV6_URL}"
}

# ─── Build cfips.conf content ─────────────────────────────────────────────────
build_config() {
  {
    echo "# Cloudflare real-IP configuration"
    echo "# Generated: $(date -u '+%Y-%m-%d %H:%M:%S UTC') by cf-nginx-realip"
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

# ─── Atomic write with nginx validation + rollback ───────────────────────────
write_config() {
  local dest="$1" nginx_bin="$2"

  [[ -d "$(dirname "$dest")" ]] || die "Target directory does not exist: $(dirname "$dest")"

  # Idempotency — skip if nothing changed
  if [[ -f "$dest" ]] && diff -q /tmp/cfips-nginx-staging.conf "$dest" &>/dev/null; then
    log_info "Cloudflare IP list unchanged — no update needed"
    rm -f /tmp/cfips-nginx-staging.conf
    return 1
  fi

  [[ -f "$dest" ]] && cp "$dest" "${dest}.bak"
  mv /tmp/cfips-nginx-staging.conf "$dest"
  log_ok "Written: ${dest}"

  if ! "$nginx_bin" -t &>/dev/null; then
    log_fail "nginx config test failed — reverting ${dest}"
    [[ -f "${dest}.bak" ]] && mv "${dest}.bak" "$dest"
    die "Aborted: nginx config invalid after writing ${dest}"
  fi
  log_ok "nginx config test passed"
  return 0
}

# ─── Install weekly cron ─────────────────────────────────────────────────────
install_cron() {
  local nginx_bin="$1" conf_dir="$2"
  local cron_file="/etc/cron.d/cf-nginx-realip"
  local cron_line="@weekly root ${SCRIPT_PATH} --path ${conf_dir} --file ${OUTPUT_FILE} --reload"

  printf '%s\n' "$cron_line" > "$cron_file"
  chmod 644 "$cron_file"
  log_ok "Weekly cron installed: ${cron_file}"
}

# ══════════════════════════════════════════════════════════════════════════════
# INSTALL MODE
# ══════════════════════════════════════════════════════════════════════════════
run_install() {
  echo -e "\n${BOLD}╔══════════════════════════════════════════╗"
  echo -e "║   cf-nginx-realip  —  Guided Installer   ║"
  echo -e "╚══════════════════════════════════════════╝${RESET}\n"

  [[ $EUID -eq 0 ]] || die "Run as root: sudo ${SCRIPT_PATH} --install"
  command -v curl &>/dev/null || die "curl is required but not installed"

  # ── Step 1: Locate nginx binary ───────────────────────────────────────────
  log_step "Step 1/5 — Locating nginx"

  local nginx_bin=""
  local detect_result
  detect_result=$(detect_nginx_bin)

  if [[ -z "$detect_result" ]]; then
    log_warn "Could not find any nginx binary on this system."
    ask "Enter the full path to your nginx binary" ""
    nginx_bin="$REPLY"
    [[ -x "$nginx_bin" ]] || die "Not executable: ${nginx_bin}"

  elif [[ "$detect_result" == __MULTIPLE__* ]]; then
    # Multiple installs found — build list and ask user to choose
    local multi_bins=()
    while IFS= read -r line; do
      [[ -n "$line" && "$line" != "__MULTIPLE__" ]] && multi_bins+=("$line")
    done <<< "$detect_result"

    log_warn "Multiple nginx installations found:"
    echo ""
    local i=1
    for bin in "${multi_bins[@]}"; do
      local ver
      ver=$("$bin" -v 2>&1)
      echo -e "  ${BOLD}[$i]${RESET} ${bin}  ${CYAN}(${ver})${RESET}"
      (( i++ ))
    done
    echo ""
    ask "Which nginx serves your sites? Enter number" "1"
    local choice=$(( REPLY - 1 ))
    nginx_bin="${multi_bins[$choice]}"
    [[ -x "$nginx_bin" ]] || die "Invalid selection"

  else
    nginx_bin="$detect_result"
  fi

  local nginx_ver
  nginx_ver=$("$nginx_bin" -v 2>&1)
  log_ok "Using: ${nginx_bin}  (${nginx_ver})"

  # ── Step 2: Locate config directory ──────────────────────────────────────
  log_step "Step 2/5 — Locating nginx config directory"

  local nginx_conf_dir=""
  if [[ -n "$NGINX_PATH" ]]; then
    nginx_conf_dir="$NGINX_PATH"
    log_info "Using specified path: ${nginx_conf_dir}"
  elif nginx_conf_dir=$(detect_nginx_conf_dir "$nginx_bin"); then
    log_ok "Detected: ${nginx_conf_dir}"
  else
    log_warn "Could not detect config directory from nginx binary."
    ask "Enter the full path to your nginx config directory" ""
    nginx_conf_dir="$REPLY"
  fi

  [[ -d "$nginx_conf_dir" ]] || die "Directory not found: ${nginx_conf_dir}"

  local nginx_conf="${nginx_conf_dir}/nginx.conf"
  [[ -f "$nginx_conf" ]] || die "nginx.conf not found in ${nginx_conf_dir}"
  log_ok "Config:   ${nginx_conf}"

  local dest_file="${nginx_conf_dir}/${OUTPUT_FILE}"

  # ── Confirm before touching anything ─────────────────────────────────────
  echo ""
  echo -e "${BOLD}  About to:${RESET}"
  echo -e "  • Write Cloudflare IP ranges to  ${CYAN}${dest_file}${RESET}"
  echo -e "  • Patch                          ${CYAN}${nginx_conf}${RESET}"
  echo -e "  • Reload nginx using             ${CYAN}${nginx_bin}${RESET}"
  echo -e "  • Install weekly cron at         ${CYAN}/etc/cron.d/cf-nginx-realip${RESET}"
  echo ""
  confirm "Proceed?" || die "Aborted by user."

  # ── Step 3: Fetch IPs and write cfips.conf ───────────────────────────────
  log_step "Step 3/5 — Fetching Cloudflare IP ranges"

  fetch_cloudflare_ips
  build_config

  local ipv4_count ipv6_count
  ipv4_count=$(grep -c '\.' <<< "$IPV4_LIST" || true)
  ipv6_count=$(grep -c ':' <<< "$IPV6_LIST" || true)
  log_ok "Got ${ipv4_count} IPv4 and ${ipv6_count} IPv6 ranges"

  write_config "$dest_file" "$nginx_bin" || true

  # ── Step 4: Patch nginx.conf ─────────────────────────────────────────────
  log_step "Step 4/5 — Patching nginx.conf"

  # Remove any leftovers from previous installs (cfips.txt, old cfips.conf, etc.)
  cleanup_old_install "$nginx_conf" "$nginx_conf_dir"

  if include_exists "$nginx_conf" "$OUTPUT_FILE"; then
    log_ok "'include ${OUTPUT_FILE};' already present — nothing to change"
  else
    local bak_file="${nginx_conf}.bak.$(date +%Y%m%d%H%M%S)"
    cp "$nginx_conf" "$bak_file"
    log_info "Backup saved: ${bak_file}"

    if add_include_to_nginx_conf "$nginx_conf" "$OUTPUT_FILE"; then
      log_ok "Injected 'include ${OUTPUT_FILE};' into http block"
    else
      log_warn "Could not auto-patch nginx.conf (non-standard structure)."
      echo ""
      echo -e "  Add this line inside the ${BOLD}http { }${RESET} block of ${BOLD}${nginx_conf}${RESET}:"
      echo ""
      echo -e "      ${CYAN}include ${OUTPUT_FILE};${RESET}"
      echo ""
      confirm "Done? (press Y after saving the file)" || { cp "$bak_file" "$nginx_conf"; die "Aborted."; }
    fi

    if ! "$nginx_bin" -t &>/dev/null; then
      log_fail "nginx config test failed — restoring backup"
      cp "$bak_file" "$nginx_conf"
      die "nginx.conf restored. Fix the config and re-run --install."
    fi
    log_ok "nginx config test passed"
  fi

  # ── Step 5: Reload + cron ─────────────────────────────────────────────────
  log_step "Step 5/5 — Reloading nginx and installing cron"

  do_reload "$nginx_bin"
  install_cron "$nginx_bin" "$nginx_conf_dir"

  # ── Summary ───────────────────────────────────────────────────────────────
  echo ""
  echo -e "${BOLD}╔══════════════════════════════════════════════════╗"
  echo -e "║           Installation Complete!                 ║"
  echo -e "╚══════════════════════════════════════════════════╝${RESET}"
  echo ""
  echo -e "  ${GREEN}✔${RESET}  IP config:   ${dest_file}"
  echo -e "  ${GREEN}✔${RESET}  nginx.conf:  ${nginx_conf}"
  echo -e "  ${GREEN}✔${RESET}  Cron:        /etc/cron.d/cf-nginx-realip (weekly)"
  echo -e "  ${GREEN}✔${RESET}  nginx:       reloaded"
  echo ""
  echo -e "  ${CYAN}Verify:${RESET} tail -f /var/log/nginx/access.log"
  echo -e "  Visitor IPs should now be real IPs, not Cloudflare ranges."
  echo ""
}

# ══════════════════════════════════════════════════════════════════════════════
# UPDATE MODE — refresh IP list (run by cron or manually)
# ══════════════════════════════════════════════════════════════════════════════
run_update() {
  local nginx_bin
  nginx_bin=$(detect_nginx_bin 2>/dev/null) || nginx_bin=""

  if [[ -z "$NGINX_PATH" ]]; then
    [[ -n "$nginx_bin" ]] || die "Cannot detect nginx. Run: sudo ${SCRIPT_PATH} --install"
    NGINX_PATH=$(detect_nginx_conf_dir "$nginx_bin") \
      || die "Cannot detect nginx config directory. Run: sudo ${SCRIPT_PATH} --install"
  fi

  [[ -n "$nginx_bin" ]] || nginx_bin=$(detect_nginx_bin) || die "Cannot find nginx binary."

  local dest_file="${NGINX_PATH}/${OUTPUT_FILE}"
  [[ -d "$NGINX_PATH" ]] || die "Config directory not found: ${NGINX_PATH}"
  command -v curl &>/dev/null || die "curl is required but not installed"

  fetch_cloudflare_ips
  build_config

  if $DRY_RUN; then
    echo -e "\n${BOLD}--- dry-run (not written) ---${RESET}"
    cat /tmp/cfips-nginx-staging.conf
    rm -f /tmp/cfips-nginx-staging.conf
    return
  fi

  local changed=true
  write_config "$dest_file" "$nginx_bin" || changed=false

  if $changed; then
    case "$RELOAD_MODE" in
      yes|auto) do_reload "$nginx_bin" ;;
      no)       log_info "Skipping reload (--no-reload)" ;;
    esac
  fi

  log_ok "Done."
}

# ─── Entry point ──────────────────────────────────────────────────────────────
if $INSTALL_MODE; then
  run_install
else
  run_update
fi
