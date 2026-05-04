#!/usr/bin/env bash
# Monad Grafana — auto-installer
# Usage:
#   sudo ./install.sh                   # interactive install to /opt/monad-grafana
#   sudo ./install.sh --non-interactive # all defaults, no prompts
#   sudo ./install.sh --upgrade         # git pull + docker compose pull + up
#   sudo ./install.sh --uninstall       # stop, remove, optionally clean UFW
#   sudo ./install.sh --help            # show options
#
# Or one-liner from internet (verify checksum first if you care):
#   curl -fsSL https://raw.githubusercontent.com/BeeHiveTeam/monad-grafana/main/install.sh | sudo bash

set -euo pipefail

# ===== Defaults =====
PREFIX="${PREFIX:-/opt/monad-grafana}"
REPO_URL="${REPO_URL:-https://github.com/BeeHiveTeam/monad-grafana.git}"
LOCAL_RPC_URL="${LOCAL_RPC_URL:-http://host.docker.internal:8080}"
PUBLIC_RPC_URL="${PUBLIC_RPC_URL:-https://testnet-rpc.monad.xyz}"
NON_INTERACTIVE="${NON_INTERACTIVE:-0}"
ACTION="install"
LOG_FILE="/tmp/monad-grafana-install-$(date +%Y%m%d-%H%M%S).log"

# ===== Colors (only if TTY) =====
if [[ -t 1 ]]; then
  C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'
  C_BLUE=$'\e[34m'; C_BOLD=$'\e[1m'; C_RESET=$'\e[0m'
else
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_BOLD=""; C_RESET=""
fi

info()  { echo "${C_BLUE}[i]${C_RESET} $*"; }
ok()    { echo "${C_GREEN}[✓]${C_RESET} $*"; }
warn()  { echo "${C_YELLOW}[!]${C_RESET} $*" >&2; }
err()   { echo "${C_RED}[✗]${C_RESET} $*" >&2; }
fatal() { err "$*"; exit 1; }

show_help() {
  cat <<EOF
Monad Grafana installer

Usage: sudo $0 [OPTIONS]

Actions (mutually exclusive):
  (default)             Install (interactive)
  --upgrade             git pull + docker compose pull + up
  --uninstall           Stop, remove, optionally clean UFW

Options:
  --prefix=PATH         Install dir (default: /opt/monad-grafana)
  --local-rpc=URL       Monad RPC URL (default: http://host.docker.internal:8080)
  --public-rpc=URL      Public RPC for sync gap (default: https://testnet-rpc.monad.xyz)
  --non-interactive     Skip prompts, abort on conflicts (for CI)
  -h, --help            Show this

Environment variables override flags: PREFIX, LOCAL_RPC_URL, PUBLIC_RPC_URL, NON_INTERACTIVE.
EOF
}

# ===== Parse args =====
while [[ $# -gt 0 ]]; do
  case $1 in
    --prefix=*)        PREFIX="${1#*=}";;
    --local-rpc=*)     LOCAL_RPC_URL="${1#*=}";;
    --public-rpc=*)    PUBLIC_RPC_URL="${1#*=}";;
    --non-interactive) NON_INTERACTIVE=1;;
    --uninstall)       ACTION="uninstall";;
    --upgrade)         ACTION="upgrade";;
    -h|--help)         show_help; exit 0;;
    *) fatal "Unknown option: $1 (try --help)";;
  esac
  shift
done

# ===== Helpers =====

require_root() {
  [[ $EUID -eq 0 ]] || fatal "Run as root: sudo $0 $*"
}

confirm() {
  [[ $NON_INTERACTIVE -eq 1 ]] && { info "(non-interactive: assuming No for: $1)"; return 1; }
  local ans
  read -rp "${C_YELLOW}?${C_RESET} $1 [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

confirm_default_yes() {
  [[ $NON_INTERACTIVE -eq 1 ]] && { info "(non-interactive: assuming Yes for: $1)"; return 0; }
  local ans
  read -rp "${C_YELLOW}?${C_RESET} $1 [Y/n] " ans
  [[ ! "$ans" =~ ^[Nn]$ ]]
}

# ===== Pre-flight checks =====

check_os() {
  command -v apt-get >/dev/null || fatal "apt-get not found — only Debian/Ubuntu supported by auto-installer."
  [[ "$(uname -m)" == "x86_64" ]] || fatal "Only x86_64 supported (got $(uname -m))."
  ok "OS: $(. /etc/os-release; echo "$PRETTY_NAME") on x86_64"
}

check_disk() {
  local free_gb
  free_gb=$(df -BG / | awk 'NR==2 {gsub("G","",$4); print $4}')
  (( free_gb >= 2 )) || fatal "Need ≥2 GB free on / (have ${free_gb} GB)."
  ok "Disk: ${free_gb} GB free on /"
}

check_ports() {
  local conflict=0
  for p in 9090 3000 9101; do
    if ss -tln 2>/dev/null | grep -qE "127.0.0.1:${p}\b|0.0.0.0:${p}\b|\*:${p}\b"; then
      err "Port ${p} already in use:"
      ss -tlnp 2>/dev/null | grep ":${p}\b" >&2 || true
      conflict=1
    fi
  done
  (( conflict == 0 )) || fatal "Free up the listed ports and re-run."
  ok "Ports 9090/3000/9101 free."
}

check_monad() {
  systemctl is-active --quiet monad-bft \
    || fatal "monad-bft.service not active. This installer is for Monad node operators only."
  ok "monad-bft.service active."

  ss -tln 2>/dev/null | grep -qE ":8889\b" \
    || fatal ":8889 not listening — Monad's bundled otelcol-contrib must be running and exposing Prometheus metrics."
  ok "otelcol metrics endpoint :8889 listening."

  if ! curl -fsS -m 3 -X POST http://127.0.0.1:8080 \
       -H 'Content-Type: application/json' \
       -d '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' >/dev/null 2>&1; then
    fatal "Monad RPC :8080 not responding to eth_blockNumber."
  fi
  ok "Monad RPC :8080 reachable."
}

check_docker() {
  if ! command -v docker >/dev/null; then
    warn "Docker not installed."
    if confirm_default_yes "Install Docker now via official get.docker.com script?"; then
      info "Downloading and running Docker installer…"
      curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
      sh /tmp/get-docker.sh >> "$LOG_FILE" 2>&1
      systemctl enable --now docker
      ok "Docker installed."
    else
      fatal "Docker is required. Install manually then re-run."
    fi
  fi
  if ! docker compose version >/dev/null 2>&1; then
    warn "docker compose plugin missing — installing docker-compose-plugin…"
    apt-get update -qq && apt-get install -y docker-compose-plugin >> "$LOG_FILE" 2>&1
  fi
  ok "Docker $(docker --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1) + compose $(docker compose version --short)"
}

check_existing_stack() {
  local conflicting_containers
  conflicting_containers=$(docker ps -a --format '{{.Names}}' 2>/dev/null \
    | grep -E '^(prometheus|grafana|monad-rpc-exporter)$' || true)

  if [[ -n "$conflicting_containers" ]]; then
    warn "Conflicting containers exist:"
    echo "$conflicting_containers" | sed 's/^/    /' >&2
    warn "Container names ('prometheus', 'grafana', 'monad-rpc-exporter') are global in Docker."
    warn "The new install cannot start until these are stopped/removed."

    if [[ -d /opt/monitoring && -f /opt/monitoring/docker-compose.yml ]]; then
      warn "Detected old stack at /opt/monitoring/."
      if confirm "Stop AND remove old stack at /opt/monitoring/ (volumes preserved)?"; then
        (cd /opt/monitoring && docker compose down) >> "$LOG_FILE" 2>&1 || true
        ok "Old stack stopped."
      else
        fatal "Aborted — resolve conflict manually (e.g. 'cd /opt/monitoring && sudo docker compose down')."
      fi
    else
      if confirm "Stop and remove these containers (no compose file found at /opt/monitoring)?"; then
        echo "$conflicting_containers" | xargs -r docker rm -f >> "$LOG_FILE" 2>&1
        ok "Containers removed."
      else
        fatal "Aborted — resolve conflict manually."
      fi
    fi
  fi
}

# ===== Install steps =====

clone_or_update() {
  if [[ -d "$PREFIX/.git" ]]; then
    info "Existing git checkout at $PREFIX — updating to latest main…"
    git -C "$PREFIX" fetch origin main >> "$LOG_FILE" 2>&1
    git -C "$PREFIX" reset --hard origin/main >> "$LOG_FILE" 2>&1
  elif [[ -d "$PREFIX" && -n "$(ls -A "$PREFIX" 2>/dev/null)" ]]; then
    fatal "$PREFIX exists and is not empty (and not a git checkout). Backup or remove it first."
  else
    info "Cloning $REPO_URL → $PREFIX…"
    git clone --quiet "$REPO_URL" "$PREFIX" >> "$LOG_FILE" 2>&1
  fi
  ok "Code in place at $PREFIX (commit $(git -C "$PREFIX" rev-parse --short HEAD))"
}

generate_env() {
  if [[ -f "$PREFIX/.env" ]]; then
    info "Keeping existing $PREFIX/.env (won't regenerate password)."
    return
  fi
  local pass
  pass=$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)
  cat > "$PREFIX/.env" <<EOF
# Auto-generated by install.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)
GF_SECURITY_ADMIN_PASSWORD=$pass
LOCAL_RPC_URL=$LOCAL_RPC_URL
PUBLIC_RPC_URL=$PUBLIC_RPC_URL
EOF
  chmod 600 "$PREFIX/.env"
  ok "Generated $PREFIX/.env (mode 600)."
}

start_stack() {
  info "Starting docker compose…"
  (cd "$PREFIX" && docker compose up -d) >> "$LOG_FILE" 2>&1
  ok "Containers started."
}

setup_ufw() {
  if ! command -v ufw >/dev/null || ! ufw status >/dev/null 2>&1; then
    info "ufw not active — skipping firewall step. If you use iptables/nftables/firewalld, manually allow docker-bridge → :8889 and :8080."
    return
  fi

  local network_name
  network_name=$(basename "$PREFIX")_monitoring
  local subnet
  subnet=$(docker network inspect "$network_name" \
    --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null || true)

  if [[ -z "$subnet" ]]; then
    warn "Couldn't detect docker network subnet — UFW step skipped. Add manually if Prometheus targets stay DOWN."
    return
  fi

  info "Adding UFW allow rules: $subnet → :8889, :8080…"
  ufw allow from "$subnet" to any port 8889 proto tcp comment 'monad-grafana → otelcol' >> "$LOG_FILE" 2>&1 || true
  ufw allow from "$subnet" to any port 8080 proto tcp comment 'monad-grafana → monad-rpc' >> "$LOG_FILE" 2>&1 || true
  ok "UFW rules added for subnet $subnet."
}

verify() {
  info "Waiting 20s for first Prometheus scrape cycle…"
  sleep 20
  curl -sS -X POST http://127.0.0.1:9090/-/reload >/dev/null 2>&1 || true
  sleep 3

  local targets
  targets=$(curl -fsS http://127.0.0.1:9090/api/v1/targets 2>/dev/null || echo '{"data":{"activeTargets":[]}}')
  local up_count down_count
  up_count=$(echo "$targets" | python3 -c "import json,sys;print(sum(1 for t in json.load(sys.stdin)['data']['activeTargets'] if t['health']=='up'))" 2>/dev/null || echo 0)
  down_count=$(echo "$targets" | python3 -c "import json,sys;print(sum(1 for t in json.load(sys.stdin)['data']['activeTargets'] if t['health']!='up'))" 2>/dev/null || echo 0)

  if (( down_count > 0 )); then
    warn "Some Prometheus targets DOWN:"
    echo "$targets" | python3 -c "
import json,sys
for t in json.load(sys.stdin)['data']['activeTargets']:
    if t['health']!='up':
        print(f\"  {t['labels'].get('job')}: {(t.get('lastError') or '')[:100]}\")" >&2
    return 1
  fi
  ok "All $up_count Prometheus targets UP."

  local block
  block=$(curl -fsS 'http://127.0.0.1:9090/api/v1/query?query=monad_local_block_number' 2>/dev/null \
    | python3 -c "import json,sys;d=json.load(sys.stdin);r=d.get('data',{}).get('result',[]);print(r[0]['value'][1] if r else 0)" 2>/dev/null || echo 0)
  if [[ "$block" -gt 0 ]] 2>/dev/null; then
    ok "Monad local block height: $block"
  else
    warn "monad_local_block_number = 0 (give exporter another minute, or check 'docker logs monad-rpc-exporter')."
  fi
}

print_access() {
  local pass ip
  pass=$(grep '^GF_SECURITY_ADMIN_PASSWORD=' "$PREFIX/.env" | cut -d= -f2-)
  ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "<server-ip>")
  cat <<EOF

${C_GREEN}${C_BOLD}═══════════════════════════════════════════════
  Monad Grafana stack — installed and running
═══════════════════════════════════════════════${C_RESET}

  ${C_BOLD}Open Grafana via SSH tunnel from your laptop:${C_RESET}

    ssh -L 3000:127.0.0.1:3000 -L 9090:127.0.0.1:9090 ${SUDO_USER:-$USER}@${ip}

  Then in browser:  ${C_BOLD}http://localhost:3000${C_RESET}

    Login:    admin
    Password: ${C_BOLD}${pass}${C_RESET}

  (Password also stored in ${PREFIX}/.env, mode 600.)

  Dashboard "Monad Node — Overview" loads automatically.
  Install log: ${LOG_FILE}

${C_GREEN}═══════════════════════════════════════════════${C_RESET}

For public access (Cloudflare Tunnel, nginx, etc.) — see README.md "Public access".
For health checks: ${PREFIX}/scripts/healthcheck.sh
To upgrade later:  sudo ${PREFIX}/install.sh --upgrade
To uninstall:      sudo ${PREFIX}/install.sh --uninstall

EOF
}

# ===== Actions =====

do_install() {
  info "Monad Grafana installer — log: $LOG_FILE"
  echo
  check_os
  check_disk
  check_monad
  check_docker
  check_existing_stack
  check_ports
  echo
  clone_or_update
  generate_env
  start_stack
  setup_ufw
  verify || warn "Verification incomplete — check Grafana manually after a minute."
  print_access
}

do_upgrade() {
  [[ -d "$PREFIX/.git" ]] || fatal "$PREFIX is not a git checkout — install first."
  info "Upgrading $PREFIX…"
  clone_or_update
  info "Pulling latest images…"
  (cd "$PREFIX" && docker compose pull) >> "$LOG_FILE" 2>&1
  info "Recreating containers…"
  (cd "$PREFIX" && docker compose up -d) >> "$LOG_FILE" 2>&1
  ok "Upgraded."
  verify || true
}

do_uninstall() {
  warn "This will:"
  warn "  - Stop and remove all monad-grafana containers"
  warn "  - Optionally remove $PREFIX (with all configs and dashboards)"
  warn "  - Optionally remove UFW rules added by installer"
  warn "  - Volumes (Prometheus/Grafana data) will be removed (-v)"
  echo
  confirm "Continue?" || { info "Aborted."; exit 0; }

  if [[ -f "$PREFIX/docker-compose.yml" ]]; then
    info "Stopping containers and removing volumes…"
    (cd "$PREFIX" && docker compose down -v) || true
    ok "Containers stopped."
  fi

  if command -v ufw >/dev/null && ufw status >/dev/null 2>&1; then
    if confirm "Remove UFW rules with comment 'monad-grafana'?"; then
      while true; do
        local n
        n=$(ufw status numbered 2>/dev/null | grep 'monad-grafana' | head -1 | awk -F'[][]' '{print $2}')
        [[ -z "$n" ]] && break
        yes y | ufw delete "$n" >/dev/null 2>&1 || break
      done
      ok "UFW rules removed."
    fi
  fi

  if [[ -d "$PREFIX" ]]; then
    if confirm "Remove $PREFIX directory (including .env)?"; then
      rm -rf "$PREFIX"
      ok "$PREFIX removed."
    fi
  fi

  ok "Uninstall complete."
}

# ===== Main =====
require_root

case "$ACTION" in
  install)   do_install   ;;
  upgrade)   do_upgrade   ;;
  uninstall) do_uninstall ;;
esac
