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
PUBLIC_ACCESS="${PUBLIC_ACCESS:-0}"      # 1 = bind Grafana on 0.0.0.0:3000 + open UFW :3000/tcp
NON_INTERACTIVE="${NON_INTERACTIVE:-0}"
ACTION="install"
LOG_FILE="/tmp/monad-grafana-install-$(date +%Y%m%d-%H%M%S).log"

# Detected at runtime by detect_otelcol() — populated before any otelcol op.
# Override via env: OTELCOL_SVC=otelcol-contrib (or otelcol). The matching config
# path is derived; override OTELCOL_CONFIG only if you've moved the file.
OTELCOL_SVC="${OTELCOL_SVC:-}"
OTELCOL_CONFIG="${OTELCOL_CONFIG:-}"

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
  (default)               Install (interactive)
  --upgrade               git pull + docker compose pull + up
  --uninstall             Stop, remove, optionally clean UFW
  --enable-hostmetrics    Apply hostmetrics overlay to the active otelcol config
                          (auto-detects otelcol vs otelcol-contrib;
                           pin via OTELCOL_SVC=... if both are present)
                          (enables CPU/memory/disk/network panels; needs otelcol restart)

Options:
  --prefix=PATH         Install dir (default: /opt/monad-grafana)
  --local-rpc=URL       Monad RPC URL (default: http://host.docker.internal:8080)
  --public-rpc=URL      Public RPC for sync gap (default: https://testnet-rpc.monad.xyz)
  --public              Bind Grafana on 0.0.0.0:3000 + open UFW :3000/tcp.
                        Lets anyone reach http://<server-ip>:3000 and log in
                        with admin / <generated password>. Without this flag
                        Grafana listens on 127.0.0.1 only (SSH-tunnel access).
  --non-interactive     Skip prompts, abort on conflicts (for CI)
  -h, --help            Show this

Environment variables override flags: PREFIX, LOCAL_RPC_URL, PUBLIC_RPC_URL,
PUBLIC_ACCESS, NON_INTERACTIVE.
EOF
}

# ===== Parse args =====
while [[ $# -gt 0 ]]; do
  case $1 in
    --prefix=*)        PREFIX="${1#*=}";;
    --local-rpc=*)     LOCAL_RPC_URL="${1#*=}";;
    --public-rpc=*)    PUBLIC_RPC_URL="${1#*=}";;
    --public)          PUBLIC_ACCESS=1;;
    --non-interactive) NON_INTERACTIVE=1;;
    --uninstall)          ACTION="uninstall";;
    --upgrade)            ACTION="upgrade";;
    --enable-hostmetrics) ACTION="enable-hostmetrics";;
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

# Identify which OTel collector service is the active one on this host.
# Monad's apt package installs plain `otelcol` (and ships /etc/otelcol/config.yaml).
# Operators sometimes install `otelcol-contrib` for richer receivers (e.g. journald
# for logs-to-Loki); when active, contrib reads /etc/otelcol-contrib/config.yaml.
#
# We prefer the *active* service so operations apply where they take effect.
# Tie-breaker if both somehow active: prefer otelcol-contrib (richer, more likely
# what the operator actually intended).
#
# Sets OTELCOL_SVC and OTELCOL_CONFIG. Honours overrides set in env.
detect_otelcol() {
  if [[ -n "$OTELCOL_SVC" && -n "$OTELCOL_CONFIG" ]]; then
    info "OTel collector pinned via env: $OTELCOL_SVC ($OTELCOL_CONFIG)"
    return 0
  fi

  local active=()
  for svc in otelcol-contrib otelcol; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
      active+=("$svc")
    fi
  done

  if (( ${#active[@]} == 0 )); then
    err "No OTel collector service active. The Monad apt package ships 'otelcol' — enable it:"
    err "  sudo systemctl enable --now otelcol"
    err "Or install 'otelcol-contrib' for journald log-pipeline support."
    return 1
  fi

  OTELCOL_SVC="${active[0]}"
  case "$OTELCOL_SVC" in
    otelcol)         OTELCOL_CONFIG="/etc/otelcol/config.yaml" ;;
    otelcol-contrib) OTELCOL_CONFIG="/etc/otelcol-contrib/config.yaml" ;;
  esac

  if (( ${#active[@]} > 1 )); then
    warn "Both otelcol and otelcol-contrib are active — using $OTELCOL_SVC (pin with OTELCOL_SVC=... to override)"
  fi

  if [[ ! -f "$OTELCOL_CONFIG" ]]; then
    err "$OTELCOL_SVC.service active but config $OTELCOL_CONFIG missing — package may be broken"
    return 1
  fi
  ok "OTel collector: $OTELCOL_SVC ($OTELCOL_CONFIG)"
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

check_ram() {
  local total_mb avail_mb
  total_mb=$(free -m | awk '/^Mem:/ {print $2}')
  avail_mb=$(free -m | awk '/^Mem:/ {print $7}')
  # Stack reserves: prometheus 512m + grafana 512m + exporter 64m = ~1.1 GB
  if (( avail_mb < 512 )); then
    warn "Available RAM: ${avail_mb} MB — stack needs ~1.1 GB (prometheus 512m + grafana 512m + exporter 64m)."
    warn "Node may OOM kill containers under load."
  else
    ok "RAM: ${avail_mb} MB available (total: ${total_mb} MB)."
  fi
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

  detect_otelcol || fatal "OTel collector not detected. See messages above."

  ss -tln 2>/dev/null | grep -qE ":8889\b" \
    || fatal ":8889 not listening — $OTELCOL_SVC must expose Prometheus metrics on this port (check $OTELCOL_CONFIG)."
  ok "OTel metrics endpoint :8889 listening."

  # RPC reachability is best-effort — validator-only setups may not run monad-rpc.service.
  if ! curl -fsS -m 3 -X POST http://127.0.0.1:8080 \
       -H 'Content-Type: application/json' \
       -d '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' >/dev/null 2>&1; then
    warn "Monad RPC :8080 not responding on 127.0.0.1."
    warn "  → If monad-rpc.service is not running (validator-only setup), ignore this."
    warn "  → Otherwise: check 'systemctl status monad-rpc' and re-run, or set LOCAL_RPC_URL in .env after install."
    warn "  monad_local_block_number will read 0 until RPC is reachable from Docker."
  else
    # RPC responds on loopback — check binding so Docker exporter (uses host.docker.internal,
    # which resolves to the Docker bridge IP, NOT 127.0.0.1) can actually reach it.
    if ss -tln 2>/dev/null | grep -qE "127\.0\.0\.1:8080\b" \
       && ! ss -tln 2>/dev/null | grep -qE "(0\.0\.0\.0|\*):8080\b"; then
      warn "RPC :8080 is bound to 127.0.0.1 only."
      warn "  The exporter inside Docker uses host.docker.internal (→ bridge IP), not 127.0.0.1."
      warn "  Block height will read 0. Fix options:"
      warn "    a) Set LOCAL_RPC_URL=http://<bridge-ip>:8080 in $PREFIX/.env after install."
      warn "    b) Rebind RPC: add 'Environment=--rpc.listen-addr=0.0.0.0:8080' to monad-rpc.service."
    else
      ok "Monad RPC :8080 reachable."
    fi
  fi
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
  # host-gateway support (required for host.docker.internal) needs Docker ≥20.10
  local docker_ver_str docker_maj docker_min
  docker_ver_str=$(docker --version | grep -oE '[0-9]+\.[0-9]+' | head -1)
  docker_maj=${docker_ver_str%%.*}
  docker_min=${docker_ver_str##*.}
  if (( docker_maj < 20 || (docker_maj == 20 && docker_min < 10) )); then
    fatal "Docker ≥20.10 required for host-gateway (extra_hosts) support (have ${docker_ver_str}). Upgrade Docker and re-run."
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

# ===== Optional add-ons (run after monad check, before stack) =====

check_chrony() {
  if command -v chronyc >/dev/null 2>&1 && systemctl is-active --quiet chrony; then
    local last_offset_sec
    last_offset_sec=$(chronyc tracking 2>/dev/null | awk -F': ' '/Last offset/ {print $2}' | awk '{print $1}')
    ok "chrony active (offset ${last_offset_sec:-?}s)"
    return
  fi
  warn "chrony not installed/active — using systemd-timesyncd or no NTP."
  warn "systemd-timesyncd has ~10–100ms drift, which inflates vote_delay metrics by tens of ms"
  warn "(makes 'p99 vote delay' panels look worse than reality, may cause false alerts)."
  if confirm_default_yes "Install chrony now (replaces systemd-timesyncd)?"; then
    apt-get install -y chrony >> "$LOG_FILE" 2>&1 \
      && systemctl is-active --quiet chrony \
      && ok "chrony installed and active." \
      || warn "chrony install failed — see $LOG_FILE"
  fi
}

check_hostmetrics() {
  # Check whether otelcol exposes system_* metrics on :8889
  local sample
  sample=$(curl -fsS -m 3 http://127.0.0.1:8889/metrics 2>/dev/null | grep -c '^system_cpu_' || true)
  if [[ "${sample:-0}" -gt 0 ]]; then
    ok "hostmetrics receiver active (system_cpu_* metrics present)."
    return
  fi

  warn "hostmetrics NOT enabled in $OTELCOL_CONFIG."
  warn "Without it, these dashboard panels will be empty:"
  warn "  CPU usage / Load average / Memory / Swap / Disk IO / Filesystem / Network"
  warn "Reference: $PREFIX/docs/ENABLE_HOSTMETRICS.md (after install)"

  if confirm_default_yes "Apply hostmetrics overlay now? (backs up otelcol config, restarts $OTELCOL_SVC)"; then
    apply_hostmetrics
  fi
}

apply_hostmetrics() {
  local script
  if [[ -f "$PREFIX/scripts/apply_hostmetrics_overlay.py" ]]; then
    script="$PREFIX/scripts/apply_hostmetrics_overlay.py"
  elif [[ -f "$(dirname "$0")/scripts/apply_hostmetrics_overlay.py" ]]; then
    script="$(dirname "$0")/scripts/apply_hostmetrics_overlay.py"
  else
    err "scripts/apply_hostmetrics_overlay.py not found. Did clone fail?"
    return 1
  fi

  # Pre-flight: confirm the active otelcol BINARY actually has the
  # hostmetrics receiver compiled in. Plain `otelcol` (the Core
  # distribution that docs.monad.xyz mandates for VDP push) does NOT
  # ship hostmetrics — it's contrib-only. Writing the overlay against
  # plain otelcol would produce a config that fails to load and crashes
  # the collector on next restart.
  if command -v "$OTELCOL_SVC" >/dev/null 2>&1; then
    if ! "$OTELCOL_SVC" components 2>/dev/null | grep -qE '^\s+- hostmetrics$|^\s+hostmetrics:|^hostmetrics$'; then
      err "Active collector '$OTELCOL_SVC' does NOT include the hostmetrics receiver."
      err "  hostmetrics is part of otelcol-contrib only — plain otelcol (Core,"
      err "  which docs.monad.xyz requires for VDP push) does not ship it."
      err "  Skipping overlay to avoid breaking the running collector."
      err ""
      err "  Recommended path: install node_exporter as a sidecar — host metrics"
      err "  arrive on :9100 (Prometheus naming, scraped by our prometheus.yml)."
      err "  See docs/ENABLE_HOSTMETRICS.md (alternative paths section)."
      return 1
    fi
  else
    warn "Cannot find $OTELCOL_SVC binary on PATH — proceeding but verify after restart."
  fi

  # Need PyYAML for safe edit; fall back gracefully if unavailable
  if ! python3 -c 'import yaml' 2>/dev/null; then
    info "Installing python3-yaml for safe config edit…"
    apt-get install -y python3-yaml >> "$LOG_FILE" 2>&1 || warn "python3-yaml install failed — script will use text fallback."
  fi

  python3 "$script" "$OTELCOL_CONFIG" || { err "overlay script failed"; return 1; }

  info "Restarting $OTELCOL_SVC…"
  systemctl restart "$OTELCOL_SVC"
  sleep 5

  if systemctl is-active --quiet "$OTELCOL_SVC"; then
    ok "$OTELCOL_SVC restarted."
  else
    err "$OTELCOL_SVC failed to restart after applying hostmetrics overlay!"
    err "  Restoring config from most-recent backup to bring the collector back up…"
    # Find newest backup created by the overlay script.
    local latest_bak
    latest_bak=$(ls -t "${OTELCOL_CONFIG}".bak.* 2>/dev/null | head -1)
    if [[ -n "$latest_bak" ]]; then
      cp -a "$latest_bak" "$OTELCOL_CONFIG"
      systemctl restart "$OTELCOL_SVC"
      sleep 3
      if systemctl is-active --quiet "$OTELCOL_SVC"; then
        ok "Restored $OTELCOL_CONFIG from $latest_bak — $OTELCOL_SVC is up again."
      else
        err "Restore failed too. Manual recovery required:"
        err "  sudo cp $latest_bak $OTELCOL_CONFIG && sudo systemctl restart $OTELCOL_SVC"
      fi
    else
      err "No backup found at ${OTELCOL_CONFIG}.bak.* — manual recovery needed."
    fi
    err "Diagnostic: journalctl -u $OTELCOL_SVC --since '2 min ago'"
    return 1
  fi

  # Verify hostmetrics now appearing
  sleep 5
  local n
  n=$(curl -fsS -m 3 http://127.0.0.1:8889/metrics 2>/dev/null | grep -c '^system_cpu_' || true)
  if [[ "${n:-0}" -gt 0 ]]; then
    ok "hostmetrics confirmed — $n system_cpu_* series exposed."
  else
    warn "system_cpu_* still not in :8889 — check 'docker logs prometheus' or otelcol journal."
  fi
}

# ===== Install steps =====

configure_prometheus() {
  local prom="$PREFIX/prometheus/prometheus.yml"
  local h
  h=$(hostname -s 2>/dev/null || hostname)
  # Replace placeholder only — preserves any manual edits on re-run
  if grep -q 'host: monad-node' "$prom"; then
    sed -i "s/host: monad-node/host: ${h//\//\\/}/" "$prom"
    ok "Prometheus external_labels: host=$h"
  fi
}

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

apply_grafana_bind() {
  # docker-compose.yml uses ${GRAFANA_BIND:-127.0.0.1} for the Grafana port
  # binding. Set it explicitly in .env so the operator's choice survives
  # restarts and `install.sh --upgrade` (which calls `docker compose up -d`).
  local env="$PREFIX/.env"
  local desired
  if (( PUBLIC_ACCESS == 1 )); then
    desired="0.0.0.0"
  else
    desired="127.0.0.1"
  fi
  # Drop any prior GRAFANA_BIND line and append the current choice.
  if [[ -f "$env" ]]; then
    sed -i '/^GRAFANA_BIND=/d' "$env"
    printf 'GRAFANA_BIND=%s\n' "$desired" >> "$env"
  fi
  if (( PUBLIC_ACCESS == 1 )); then
    ok "Grafana bind set to 0.0.0.0:3000 (public access enabled)"
  fi
}

start_stack() {
  apply_grafana_bind
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

  if (( PUBLIC_ACCESS == 1 )); then
    info "Opening UFW :3000/tcp (--public — Grafana reachable from anywhere)…"
    ufw allow 3000/tcp comment 'monad-grafana web UI (public)' >> "$LOG_FILE" 2>&1 || true
    ok "UFW :3000/tcp open."
  fi
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

EOF

  if (( PUBLIC_ACCESS == 1 )); then
    cat <<EOF
  ${C_BOLD}${C_YELLOW}Public access ENABLED${C_RESET} — Grafana reachable from anywhere:

    ${C_BOLD}URL:      http://${ip}:3000${C_RESET}
    ${C_BOLD}Login:    admin${C_RESET}
    ${C_BOLD}Password: ${pass}${C_RESET}

  ${C_YELLOW}Share these credentials only with people who should see the dashboard.${C_RESET}
  Grafana is the only auth layer — there is no TLS by default (HTTP).
  Rotate password: edit GF_SECURITY_ADMIN_PASSWORD in ${PREFIX}/.env, then
                   sudo docker compose -f ${PREFIX}/docker-compose.yml up -d

  To switch to TLS via nginx + Let's Encrypt or a Cloudflare Tunnel, see
  README.md "Public access" — pointing the proxy at 127.0.0.1:3000 with
  --public DISABLED is the recommended long-term setup.

EOF
  else
    cat <<EOF
  ${C_BOLD}Open Grafana via SSH tunnel from your laptop:${C_RESET}

    ssh -L 3000:127.0.0.1:3000 -L 9090:127.0.0.1:9090 ${SUDO_USER:-$USER}@${ip}

  Then in browser:  ${C_BOLD}http://localhost:3000${C_RESET}

    Login:    admin
    Password: ${C_BOLD}${pass}${C_RESET}

  Re-run with --public to bind on 0.0.0.0:3000 + open UFW :3000/tcp.

EOF
  fi

  cat <<EOF
  (Password also stored in ${PREFIX}/.env, mode 600.)

  Dashboard "Monad Node — Overview" loads automatically.
  Install log: ${LOG_FILE}

${C_GREEN}═══════════════════════════════════════════════${C_RESET}

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
  check_ram
  check_monad
  check_docker
  check_existing_stack
  check_ports
  echo
  clone_or_update
  configure_prometheus
  echo
  info "─── Optional but recommended ───────────────────────────"
  check_chrony
  check_hostmetrics
  echo
  generate_env
  start_stack
  setup_ufw
  verify || warn "Verification incomplete — check Grafana manually after a minute."
  print_access
}

do_enable_hostmetrics() {
  detect_otelcol || fatal "OTel collector not detected — cannot apply overlay."
  info "Applying hostmetrics overlay to $OTELCOL_CONFIG…"
  apply_hostmetrics
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
      local _ufw_attempts=0
      while [[ $_ufw_attempts -lt 30 ]]; do
        local n
        n=$(ufw status numbered 2>/dev/null | grep 'monad-grafana' | head -1 | awk -F'[][]' '{print $2}')
        [[ -z "$n" ]] && break
        if ! yes y | ufw delete "$n" >/dev/null 2>&1; then
          warn "Failed to delete UFW rule $n — remove manually: sudo ufw delete $n"
          break
        fi
        _ufw_attempts=$(( _ufw_attempts + 1 ))
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
  install)             do_install             ;;
  upgrade)             do_upgrade             ;;
  uninstall)           do_uninstall           ;;
  enable-hostmetrics)  do_enable_hostmetrics  ;;
esac
