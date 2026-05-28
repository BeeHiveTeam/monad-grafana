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

# Deployment mode — set by prompt_deployment_mode() during interactive install.
#   MODE  = all-in-one | split
#   ROLE  = "" (all-in-one) | monitor | node    (only for split)
#   NODE_HOST = remote Monad node IP/hostname (split + monitor)
#   MONITOR_IP = monitoring server IP (split + node, for UFW allow)
#   MONAD_NETWORK_DETECTED = testnet | mainnet | "" — set by reachability test
MODE=""
ROLE=""
NODE_HOST=""
MONITOR_IP=""
MONAD_NETWORK_DETECTED=""

# Polling for split-monitor-side: wait this long for node-side to finish.
POLL_TIMEOUT_SEC="${POLL_TIMEOUT_SEC:-300}"   # 5 minutes
POLL_INTERVAL_SEC="${POLL_INTERVAL_SEC:-10}"

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

# Ask the user "1 or 2?" with no default — must explicitly type the choice.
# Returns the chosen number on stdout; loops on invalid input.
prompt_choice_1_or_2() {
  local question="$1"
  local ans
  while true; do
    read -rp "${C_YELLOW}?${C_RESET} $question [1/2] " ans
    case "$ans" in
      1|2) echo "$ans"; return 0 ;;
      *)   warn "Please type '1' or '2' (no default)." ;;
    esac
  done
}

# Two-step interactive deployment-mode selection. Sets globals:
#   MODE  = all-in-one | split
#   ROLE  = "" (all-in-one) | monitor | node    (only for split)
# Honors --non-interactive by defaulting to MODE=all-in-one ROLE="" (legacy behavior).
prompt_deployment_mode() {
  if [[ $NON_INTERACTIVE -eq 1 ]]; then
    MODE="all-in-one"
    ROLE=""
    info "(non-interactive: defaulting to MODE=all-in-one)"
    return
  fi

  cat <<EOF

${C_BOLD}How do you want to deploy?${C_RESET}

  [1] All-in-one
      Monitoring stack on the same server as your Monad node.
      Easier setup, but ${C_YELLOW}not recommended for production${C_RESET}.

  [2] Split (recommended)
      Monitoring on a separate server, node stays isolated.
      Per Monad Foundation security advisory.

EOF
  local choice
  choice=$(prompt_choice_1_or_2 "Choose:")

  if [[ "$choice" == "1" ]]; then
    show_security_warning_and_confirm || { info "Aborted by user."; exit 0; }
    MODE="all-in-one"
    ROLE=""
    return
  fi

  # Split mode: ask which side we're on
  MODE="split"
  cat <<EOF

${C_BOLD}Split deployment selected.${C_RESET}

You'll need to run this installer on BOTH servers:
  • One time on the ${C_BOLD}monitoring server${C_RESET}  (installs Prometheus + Grafana)
  • One time on the ${C_BOLD}Monad node${C_RESET}         (opens ports + installs node-exporter)

Which server are you on right now?

  [1] Monitoring server (Monad node is on another machine)
  [2] Monad node (preparing it for remote monitoring)

EOF
  choice=$(prompt_choice_1_or_2 "Choose:")
  if [[ "$choice" == "1" ]]; then
    ROLE="monitor"
  else
    ROLE="node"
  fi
}

show_security_warning_and_confirm() {
  cat <<EOF

${C_YELLOW}${C_BOLD}                  ⚠  SECURITY WARNING  ⚠${C_RESET}

You chose to install monitoring on the same server as your Monad node.

This is NOT recommended by Monad Foundation for the following reasons:

  • ${C_BOLD}Single attack surface${C_RESET} — a compromise of Grafana/Prometheus
    (e.g. weak admin password, plugin vulnerability) exposes your
    validator keys and signing process on the same host.

  • ${C_BOLD}Resource contention${C_RESET} — Prometheus and Grafana compete with
    monad-execution for RAM/CPU, can cause vote_delay spikes
    under load and VDP scoring degradation.

  • ${C_BOLD}Single point of failure${C_RESET} — disk full, OOM, network issue —
    you lose monitoring exactly when you need it most.

  • ${C_BOLD}Migration cost${C_RESET} — moving monitoring later means losing metric
    history (different volumes).

Recommended: run monitoring on a separate \$5-10/mo server.

EOF
  confirm "Continue with all-in-one install anyway?"
}

# Validate IPv4 / IPv6 / hostname. Returns 0 on valid, 1 on invalid.
validate_host() {
  local h="$1"
  [[ -z "$h" ]] && return 1
  # Accept IPv4, IPv6 in brackets-or-not, or hostname (letters/digits/dots/hyphens)
  if [[ "$h" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    # cheap IPv4 sanity check
    local IFS=.
    local -a o=( $h )
    for n in "${o[@]}"; do (( n >= 0 && n <= 255 )) || return 1; done
    return 0
  fi
  # Hostnames and IPv6 — let curl/ping handle the strict validation downstream.
  [[ "$h" =~ ^[a-zA-Z0-9.:_-]+$ ]]
}

# Probe an HTTP endpoint with short timeout. Returns 0 if responsive.
probe_http() {
  local url="$1"
  curl -sf -m 5 -o /dev/null "$url"
}

# Probe Monad RPC endpoint at host:8080. Echoes "testnet"/"mainnet"/"" — empty on failure.
probe_remote_network() {
  local host="$1"
  local hex
  hex=$(curl -sf -m 5 -X POST -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' \
    "http://$host:8080" 2>/dev/null \
    | python3 -c 'import json,sys;r=json.load(sys.stdin);print(int(r["result"],16))' 2>/dev/null)
  case "$hex" in
    10143) echo "testnet" ;;
    143)   echo "mainnet" ;;
    *)     echo "" ;;
  esac
}

# Test 3 endpoints on the node-side host. Returns 0 if all reachable, 1 otherwise.
# IMPORTANT: this sets globals (MONAD_NETWORK_DETECTED, REACHABILITY_ERRORS) and
# must therefore be called DIRECTLY — never inside $(...) command substitution,
# which would run it in a subshell and discard those assignments.
REACHABILITY_ERRORS=""
test_remote_node_reachability() {
  local host="$1"
  local errs=()
  local net
  net=$(probe_remote_network "$host")
  if [[ -n "$net" ]]; then
    MONAD_NETWORK_DETECTED="$net"
  else
    errs+=( ":8080 RPC unreachable (or wrong chain_id)" )
  fi
  probe_http "http://$host:8889/metrics" || errs+=( ":8889 otelcol metrics unreachable" )
  probe_http "http://$host:9100/metrics" || errs+=( ":9100 node-exporter unreachable" )
  if [[ ${#errs[@]} -eq 0 ]]; then REACHABILITY_ERRORS=""; return 0; fi
  REACHABILITY_ERRORS=$(printf '%s\n' "${errs[@]}")
  return 1
}

# Detect this machine's outward-facing IP (best effort).
detect_my_ip() {
  # Try the gateway interface IP first
  local ip
  ip=$(ip route get 1.1.1.1 2>/dev/null | awk '/src/ {for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
  if [[ -n "$ip" ]]; then echo "$ip"; return; fi
  # Fallback to hostname -I first token
  hostname -I 2>/dev/null | awk '{print $1}'
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

  # Pre-flight: if the active otelcol binary doesn't even SHIP the
  # hostmetrics receiver (plain `otelcol` Core distribution, which is
  # what docs.monad.xyz requires for VDP push), don't prompt at all —
  # there's nothing the operator can answer yes to.
  if command -v "$OTELCOL_SVC" >/dev/null 2>&1 \
     && ! "$OTELCOL_SVC" components 2>/dev/null | grep -qE '^\s+- hostmetrics$|^\s+hostmetrics:|^hostmetrics$'; then
    info "Active collector '$OTELCOL_SVC' is a Core build — hostmetrics receiver not compiled in."
    info "Host-level panels (CPU/RAM/disk/network) will stay empty."
    info "For host metrics on plain otelcol, run node_exporter as a sidecar"
    info "(planned addition to monad-grafana — Prometheus naming: node_*)."
    return
  fi

  warn "hostmetrics NOT enabled in $OTELCOL_CONFIG."
  warn "Without it, these dashboard panels will be empty:"
  warn "  CPU usage / Load average / Memory / Swap / Disk IO / Filesystem / Network"
  warn "Reference: $PREFIX/docs/ENABLE_HOSTMETRICS.md (after install)"

  if confirm_default_yes "Apply hostmetrics overlay now? (backs up otelcol config, restarts $OTELCOL_SVC)"; then
    # apply_hostmetrics may return 1 if the active otelcol binary lacks the
    # hostmetrics receiver (plain Core distribution). This is an EXPECTED
    # optional-step refusal, not a fatal installer error — keep going.
    # Without `|| true`, `set -e` at the top of this script would abort the
    # whole install at this point.
    apply_hostmetrics || warn "Hostmetrics overlay not applied — continuing install."
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

detect_monad_network() {
  # Probe local Monad RPC for chain_id. Known Monad chain IDs:
  #   testnet = 10143 (0x279f)
  #   mainnet = 143   (0x8f)
  # On any failure (no RPC, wrong chain, parse error) fall back to "testnet"
  # — the safer default for a fresh install that hasn't been pointed at mainnet.
  #
  # LOCAL_RPC_URL default is http://host.docker.internal:8080 — that hostname
  # only resolves INSIDE the docker network, not on the host where install.sh
  # runs. Translate to a host-side equivalent for the probe.
  local probe_url="$LOCAL_RPC_URL"
  probe_url="${probe_url/host.docker.internal/127.0.0.1}"
  local chain_id
  chain_id=$(curl -sf -m 3 -X POST -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' \
    "$probe_url" 2>/dev/null \
    | python3 -c 'import json,sys;r=json.load(sys.stdin);print(int(r["result"],16))' 2>/dev/null)
  case "$chain_id" in
    10143) echo "testnet" ;;
    143)   echo "mainnet" ;;
    *)     echo "" ;;
  esac
}

configure_prometheus() {
  local prom="$PREFIX/prometheus/prometheus.yml"
  local h
  h=$(hostname -s 2>/dev/null || hostname)
  # Replace placeholder only — preserves any manual edits on re-run
  if grep -q 'host: monad-node' "$prom"; then
    sed -i "s/host: monad-node/host: ${h//\//\\/}/" "$prom"
    ok "Prometheus external_labels: host=$h"
  fi

  # Auto-detect testnet vs mainnet via eth_chainId on the local Monad RPC,
  # and write the right network label. Operator override via env:
  #   NETWORK=mainnet sudo ./install.sh
  local net="${NETWORK:-}"
  if [[ -z "$net" ]]; then
    net=$(detect_monad_network)
  fi
  if [[ -n "$net" ]]; then
    # Replace network label everywhere in prometheus.yml: both in
    # global.external_labels AND in every scrape_configs[].static_configs[].labels
    # (the latter is what shows up in /api/v1/query results — external_labels
    # only propagate via federation/remote_write).
    sed -i -E "s/^([[:space:]]+network:[[:space:]]+).*/\1${net}/" "$prom"
    ok "Prometheus network label (external + per-job): $net (chain_id-detected)"
    # Switch PUBLIC_RPC_URL to the matching public endpoint if the operator
    # didn't pass --public-rpc= explicitly (we left default testnet-rpc.monad.xyz).
    if [[ "$net" == "mainnet" && "$PUBLIC_RPC_URL" == "https://testnet-rpc.monad.xyz" ]]; then
      PUBLIC_RPC_URL="https://rpc.monad.xyz"
      ok "PUBLIC_RPC_URL auto-switched to $PUBLIC_RPC_URL for mainnet"
    fi
  else
    warn "Could not detect Monad network (eth_chainId failed). Leaving network=testnet."
    warn "  Override with: NETWORK=mainnet sudo ./install.sh  (or edit prometheus.yml)"
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

  info "Adding UFW allow rules: $subnet → :8889, :8080, :9100…"
  ufw allow from "$subnet" to any port 8889 proto tcp comment 'monad-grafana → otelcol' >> "$LOG_FILE" 2>&1 || true
  ufw allow from "$subnet" to any port 8080 proto tcp comment 'monad-grafana → monad-rpc' >> "$LOG_FILE" 2>&1 || true
  ufw allow from "$subnet" to any port 9100 proto tcp comment 'monad-grafana → node-exporter' >> "$LOG_FILE" 2>&1 || true
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
  prompt_deployment_mode

  case "$MODE/$ROLE" in
    all-in-one/) do_install_all_in_one ;;
    split/monitor) do_install_monitor_side ;;
    split/node) do_install_node_side ;;
    *) fatal "Unrecognized mode/role: $MODE/$ROLE" ;;
  esac
}

do_install_all_in_one() {
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

# Split + monitor: install Prometheus/Grafana here, scrape remote node.
do_install_monitor_side() {
  check_os
  check_disk
  check_ram
  check_docker
  check_existing_stack
  check_ports

  echo
  info "─── Remote node configuration ─────────────────────────"
  prompt_node_host
  wait_for_node_side
  echo
  ok "Remote node $NODE_HOST is reachable (network: ${MONAD_NETWORK_DETECTED:-unknown})."

  # Point everything at the remote node
  LOCAL_RPC_URL="http://${NODE_HOST}:8080"

  echo
  clone_or_update
  configure_prometheus_remote
  echo
  generate_env
  start_stack
  # No UFW step for scrape targets — we're scraping outbound, not exposing locally.
  if (( PUBLIC_ACCESS == 1 )); then
    setup_ufw_grafana_only
  fi
  verify || warn "Verification incomplete — check Grafana manually after a minute."
  print_access
}

# Prompt for the Monad node IP. Loops on invalid/unreachable input.
prompt_node_host() {
  while true; do
    local h
    read -rp "${C_YELLOW}?${C_RESET} Enter Monad node IP or hostname: " h
    if ! validate_host "$h"; then
      warn "Invalid hostname/IP format. Try again."
      continue
    fi
    NODE_HOST="$h"
    return 0
  done
}

# Test remote-node reachability; if any port is down, print the copy-paste
# node-side command and poll until reachable (or POLL_TIMEOUT_SEC elapses).
wait_for_node_side() {
  info "Testing connectivity to $NODE_HOST..."
  # Call directly (NOT in $()) so MONAD_NETWORK_DETECTED + REACHABILITY_ERRORS
  # set inside the function survive into this scope.
  if test_remote_node_reachability "$NODE_HOST"; then
    info "All endpoints reachable on first try (network: ${MONAD_NETWORK_DETECTED:-unknown})."
    return 0
  fi

  while IFS= read -r line; do [[ -n "$line" ]] && err "  ${line}"; done <<< "$REACHABILITY_ERRORS"

  local my_ip
  my_ip=$(detect_my_ip)

  cat <<EOF

${C_YELLOW}The Monad node hasn't been prepared yet.${C_RESET}

${C_BOLD}Run this single command on your Monad node ($NODE_HOST):${C_RESET}

  ┌──────────────────────────────────────────────────────────────────┐
  │  curl -sSL https://raw.githubusercontent.com/BeeHiveTeam/         │
  │    monad-grafana/main/install.sh | sudo bash                      │
  │                                                                   │
  │  Then choose: [2] Split → [2] Monad node                          │
  │  Enter monitor IP when asked: ${C_BOLD}${my_ip}${C_RESET}${C_RESET}                              │
  └──────────────────────────────────────────────────────────────────┘

Waiting for node-side setup to complete (timeout ${POLL_TIMEOUT_SEC}s, Ctrl+C to abort)...
EOF

  local elapsed=0
  while (( elapsed < POLL_TIMEOUT_SEC )); do
    if test_remote_node_reachability "$NODE_HOST" >/dev/null 2>&1; then
      echo
      ok "Node-side ready after ${elapsed}s. Continuing."
      return 0
    fi
    printf "  [%02d:%02d] still waiting...\r" $((elapsed/60)) $((elapsed%60))
    sleep "$POLL_INTERVAL_SEC"
    elapsed=$(( elapsed + POLL_INTERVAL_SEC ))
  done

  echo
  fatal "Node-side did not become reachable within ${POLL_TIMEOUT_SEC}s. Verify UFW rules on $NODE_HOST and re-run."
}

# Write prometheus.yml with NODE_HOST instead of host.docker.internal.
# Also handle network label / hostname like configure_prometheus() does.
configure_prometheus_remote() {
  local prom="$PREFIX/prometheus/prometheus.yml"
  local h
  h=$(hostname -s 2>/dev/null || hostname)
  sed -i "s/host: monad-node/host: ${h//\//\\/}/" "$prom" || true

  # Swap localhost docker DNS name for remote node IP
  sed -i "s|host.docker.internal|${NODE_HOST}|g" "$prom"
  ok "Prometheus targets pointed at remote node: ${NODE_HOST}"

  # Network label
  local net="${NETWORK:-${MONAD_NETWORK_DETECTED:-}}"
  if [[ -n "$net" ]]; then
    sed -i -E "s/^([[:space:]]+network:[[:space:]]+).*/\1${net}/" "$prom"
    ok "Prometheus network label: $net"
    if [[ "$net" == "mainnet" && "$PUBLIC_RPC_URL" == "https://testnet-rpc.monad.xyz" ]]; then
      PUBLIC_RPC_URL="https://rpc.monad.xyz"
      ok "PUBLIC_RPC_URL auto-switched to $PUBLIC_RPC_URL for mainnet"
    fi
  fi
}

# Open just UFW :3000/tcp for --public — no inbound scrape rules needed here
# because Prometheus reaches out to the remote node, not the other way.
setup_ufw_grafana_only() {
  if ! command -v ufw >/dev/null || ! ufw status >/dev/null 2>&1; then
    return
  fi
  info "Opening UFW :3000/tcp (--public — Grafana reachable from anywhere)…"
  ufw allow 3000/tcp comment 'monad-grafana web UI (public)' >> "$LOG_FILE" 2>&1 || true
  ok "UFW :3000/tcp open."
}

# Split + node: install node-exporter, open UFW for the monitoring server IP.
# No Prometheus/Grafana installed here.
do_install_node_side() {
  check_os
  check_monad

  echo
  info "─── Node-side preparation for remote monitoring ──────────"
  prompt_monitor_ip

  # node-exporter will bind 0.0.0.0:9100 and we open RPC/otelcol to the monitor.
  # Without an active firewall those ports (host CPU/mem/disk, RPC) are exposed
  # to the whole internet. Refuse to proceed unless UFW is active or the
  # operator explicitly opts out (e.g. they run an external/cloud firewall).
  require_firewall_or_optout

  install_node_exporter_systemd
  configure_ufw_for_monitor "$MONITOR_IP"
  selftest_node_side
  print_node_side_done
}

# Guard the node-side install: node-exporter on 0.0.0.0:9100 + opened RPC ports
# must sit behind a firewall. Hard-fail if UFW is inactive, unless
# ALLOW_UNFIREWALLED=1 (operator manages an external firewall).
require_firewall_or_optout() {
  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    return 0
  fi
  if [[ "${ALLOW_UNFIREWALLED:-0}" == "1" ]]; then
    warn "UFW inactive but ALLOW_UNFIREWALLED=1 — proceeding. Ensure an external"
    warn "firewall restricts :9100/:8889/:8080 to the monitor host ${MONITOR_IP}."
    return 0
  fi
  fatal "UFW is not active. node-exporter binds 0.0.0.0:9100 (exposes host metrics)
  and this step opens :8889/:8080 — leaving them world-reachable without a firewall.
  Enable UFW first:   sudo ufw --force enable
  Or, if you run an external/cloud firewall that already restricts these ports to
  ${MONITOR_IP}, re-run with:   ALLOW_UNFIREWALLED=1 sudo ./install.sh"
}

prompt_monitor_ip() {
  # If we know the SSH client (admin coming from monitor), suggest it as default.
  local suggested="${SSH_CLIENT%% *}"
  while true; do
    local h
    if [[ -n "$suggested" ]] && validate_host "$suggested"; then
      read -rp "${C_YELLOW}?${C_RESET} Monitor server IP [${suggested}]: " h
      h="${h:-$suggested}"
    else
      read -rp "${C_YELLOW}?${C_RESET} Monitor server IP: " h
    fi
    if ! validate_host "$h"; then
      warn "Invalid IP/hostname. Try again."
      continue
    fi
    MONITOR_IP="$h"
    return 0
  done
}

# Install node-exporter via apt (Debian/Ubuntu) as a systemd service bound on 0.0.0.0:9100.
install_node_exporter_systemd() {
  if systemctl is-active --quiet prometheus-node-exporter 2>/dev/null; then
    info "prometheus-node-exporter already active. Ensuring it binds 0.0.0.0:9100..."
  else
    info "Installing prometheus-node-exporter..."
    apt-get update -qq >> "$LOG_FILE" 2>&1
    apt-get install -y prometheus-node-exporter >> "$LOG_FILE" 2>&1
  fi

  # Force 0.0.0.0 bind via systemd override
  local override_dir=/etc/systemd/system/prometheus-node-exporter.service.d
  mkdir -p "$override_dir"
  cat > "$override_dir/override.conf" <<EOF
[Service]
Environment=
Environment="ARGS=--web.listen-address=0.0.0.0:9100"
EOF
  systemctl daemon-reload
  systemctl restart prometheus-node-exporter
  systemctl enable prometheus-node-exporter >> "$LOG_FILE" 2>&1

  if curl -sf -m 3 http://127.0.0.1:9100/metrics | head -1 | grep -q '^# HELP'; then
    ok "node-exporter listening on 0.0.0.0:9100"
  else
    fatal "node-exporter failed to start. Check: journalctl -u prometheus-node-exporter"
  fi
}

configure_ufw_for_monitor() {
  local monitor="$1"
  if ! command -v ufw >/dev/null || ! ufw status >/dev/null 2>&1; then
    warn "ufw not active. Manually allow ${monitor} → :8889, :9100, :8080 on your firewall."
    return
  fi
  info "Adding UFW allow rules: ${monitor} → :8889, :9100, :8080…"
  ufw allow from "$monitor" to any port 8889 proto tcp comment 'monad-grafana monitor → otelcol' >> "$LOG_FILE" 2>&1 || true
  ufw allow from "$monitor" to any port 9100 proto tcp comment 'monad-grafana monitor → node-exporter' >> "$LOG_FILE" 2>&1 || true
  ufw allow from "$monitor" to any port 8080 proto tcp comment 'monad-grafana monitor → monad-rpc' >> "$LOG_FILE" 2>&1 || true
  ok "UFW rules added for monitor ${monitor}."
}

selftest_node_side() {
  info "Self-test from this host..."
  probe_http "http://127.0.0.1:8889/metrics" && ok "  :8889 (otelcol) OK" || warn "  :8889 not responding locally"
  probe_http "http://127.0.0.1:9100/metrics" && ok "  :9100 (node-exporter) OK" || warn "  :9100 not responding locally"
  probe_http "http://127.0.0.1:8080" && ok "  :8080 (monad-rpc) OK" || warn "  :8080 not responding locally (RPC unused if monad-rpc.service inactive)"
}

print_node_side_done() {
  local my_ip
  my_ip=$(detect_my_ip)
  cat <<EOF

${C_GREEN}${C_BOLD}═══════════════════════════════════════════════
  ✓ Node-side setup complete
═══════════════════════════════════════════════${C_RESET}

  This node ($my_ip) is now ready for remote monitoring by ${C_BOLD}${MONITOR_IP}${C_RESET}.

  Go back to the monitor server and continue the installer there.
  It will auto-detect connectivity and proceed.

EOF
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
  # clone_or_update does `git reset --hard origin/main` which wipes any
  # operator-side edits to prometheus.yml (host hostname, network label).
  # Re-apply configure_prometheus so external_labels stay correct after
  # every --upgrade.
  configure_prometheus
  info "Pulling latest images…"
  (cd "$PREFIX" && docker compose pull) >> "$LOG_FILE" 2>&1
  info "Recreating containers…"
  (cd "$PREFIX" && docker compose up -d) >> "$LOG_FILE" 2>&1
  # `docker compose up -d` is a no-op for services whose container spec
  # didn't change — but prometheus reads its config file from a bind-mount,
  # so we need to force-restart it to pick up our just-rewritten external_labels.
  info "Restarting prometheus to load updated external_labels…"
  (cd "$PREFIX" && docker compose restart prometheus) >> "$LOG_FILE" 2>&1
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
