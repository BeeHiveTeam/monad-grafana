#!/usr/bin/env bash
# Quick health check for monad-grafana stack.
# Exit 0 = healthy, non-zero = problem (see output).
# Use in cron / monitoring / CI.
#
# Usage:
#   ./scripts/healthcheck.sh
#   ./scripts/healthcheck.sh --quiet      # only print errors, exit code matters
#   ./scripts/healthcheck.sh --json       # machine-readable

set -uo pipefail

QUIET=0; JSON=0
for arg in "$@"; do
  case "$arg" in
    --quiet) QUIET=1 ;;
    --json)  JSON=1 ;;
    -h|--help) echo "Usage: $0 [--quiet] [--json]"; exit 0 ;;
  esac
done

PROM=http://127.0.0.1:9090
EXIT=0
declare -A RESULT

check() {
  local name="$1" status="$2" detail="${3:-}"
  RESULT["$name.status"]="$status"
  RESULT["$name.detail"]="$detail"
  if [[ "$status" != "ok" ]]; then
    EXIT=1
    [[ $QUIET -eq 0 ]] && echo "✗ $name: $detail" >&2
  else
    [[ $QUIET -eq 0 ]] && echo "✓ $name${detail:+: $detail}"
  fi
}

# 1. Containers up — try docker, fall back if no perms (rely on Prometheus targets instead)
docker_ps_output=""
if docker ps --format '{{.Names}} {{.Status}}' 2>/dev/null > /tmp/.hc-docker-ps; then
  docker_ps_output=$(cat /tmp/.hc-docker-ps); rm -f /tmp/.hc-docker-ps
elif sudo -n docker ps --format '{{.Names}} {{.Status}}' 2>/dev/null > /tmp/.hc-docker-ps; then
  docker_ps_output=$(cat /tmp/.hc-docker-ps); rm -f /tmp/.hc-docker-ps
fi

if [[ -n "$docker_ps_output" ]]; then
  for c in prometheus grafana monad-rpc-exporter; do
    if echo "$docker_ps_output" | grep -q "^${c} Up"; then
      check "container.$c" "ok" "running"
    else
      check "container.$c" "fail" "not running"
    fi
  done
else
  [[ $QUIET -eq 0 ]] && echo "ℹ container checks skipped (no docker access; relying on Prometheus targets below)"
fi

# 2. Prometheus ready
if curl -fsS -m 3 "$PROM/-/ready" >/dev/null 2>&1; then
  check "prometheus.ready" "ok"
else
  check "prometheus.ready" "fail" "endpoint unreachable"
fi

# 3. All scrape targets up
if targets=$(curl -fsS -m 5 "$PROM/api/v1/targets" 2>/dev/null); then
  while IFS=$'\t' read -r job health err; do
    if [[ "$health" == "up" ]]; then
      check "target.$job" "ok"
    else
      check "target.$job" "fail" "${err:-unknown}"
    fi
  done < <(echo "$targets" | python3 -c "
import json, sys
d = json.load(sys.stdin)
for t in d['data']['activeTargets']:
    print(f\"{t['labels'].get('job','?')}\t{t['health']}\t{(t.get('lastError') or '')[:80]}\")")
else
  check "prometheus.targets" "fail" "API unreachable"
fi

# 4. Sync gap reasonable
if gap=$(curl -fsS -m 3 "$PROM/api/v1/query?query=monad_sync_gap_blocks" 2>/dev/null \
         | python3 -c "import json,sys;d=json.load(sys.stdin);r=d.get('data',{}).get('result',[]);print(int(float(r[0]['value'][1])) if r else -1)" 2>/dev/null); then
  if (( gap < 0 )); then
    check "sync.gap" "fail" "no data"
  elif (( gap < 5 )); then
    check "sync.gap" "ok" "$gap blocks"
  elif (( gap < 50 )); then
    check "sync.gap" "warn" "$gap blocks (catching up)"
  else
    check "sync.gap" "fail" "$gap blocks (severely behind)"
  fi
fi

# 5. Last block age (liveness)
# Note: exporter polls every 10s, so block.age normally oscillates 0–10s.
# Real stall = age >> exporter poll interval. Thresholds tuned for that.
if age=$(curl -fsS -m 3 "$PROM/api/v1/query?query=monad_last_block_age_seconds" 2>/dev/null \
         | python3 -c "import json,sys;d=json.load(sys.stdin);r=d.get('data',{}).get('result',[]);print(int(float(r[0]['value'][1])) if r else -1)" 2>/dev/null); then
  if (( age < 0 )); then
    check "block.age" "fail" "no data"
  elif (( age < 15 )); then
    check "block.age" "ok" "${age}s"
  elif (( age < 60 )); then
    check "block.age" "warn" "${age}s (lagging)"
  else
    check "block.age" "fail" "${age}s — node may be stuck"
  fi
fi

# 6. Grafana healthy
if curl -fsS -m 3 http://127.0.0.1:3000/api/health >/dev/null 2>&1; then
  check "grafana.health" "ok"
else
  check "grafana.health" "fail" "API unreachable"
fi

# 7. Hostmetrics enabled in otelcol (System Resources panels need this)
if hm=$(curl -fsS -m 3 "$PROM/api/v1/query?query=system_cpu_load_average_1m" 2>/dev/null \
        | python3 -c "import json,sys;d=json.load(sys.stdin);r=d.get('data',{}).get('result',[]);print(1 if r else 0)" 2>/dev/null); then
  if [[ "$hm" == "1" ]]; then
    check "otelcol.hostmetrics" "ok" "system_* metrics flowing"
  else
    check "otelcol.hostmetrics" "warn" "not enabled — run install.sh --enable-hostmetrics"
  fi
fi

# 8. NTP / clock sync (vote_delay accuracy depends on this)
if command -v chronyc >/dev/null 2>&1 && systemctl is-active --quiet chrony 2>/dev/null; then
  off_us=$(chronyc tracking 2>/dev/null | awk '/Last offset/ {printf "%.0f", $4 * 1000000}')
  off_us_abs=${off_us#-}
  if [[ -n "$off_us_abs" ]] && [[ "$off_us_abs" -lt 1000 ]]; then
    check "clock.sync" "ok" "chrony, |offset|=${off_us_abs}µs"
  elif [[ -n "$off_us_abs" ]] && [[ "$off_us_abs" -lt 10000 ]]; then
    check "clock.sync" "warn" "chrony, |offset|=${off_us_abs}µs — fine but check Reference"
  else
    check "clock.sync" "fail" "chrony, |offset|=${off_us_abs}µs — significant drift"
  fi
elif systemctl is-active --quiet systemd-timesyncd 2>/dev/null; then
  check "clock.sync" "warn" "systemd-timesyncd (~10–100ms drift; chrony recommended)"
else
  check "clock.sync" "fail" "no NTP daemon active"
fi

# JSON output
if [[ $JSON -eq 1 ]]; then
  _hc_tmp=$(mktemp)
  for k in "${!RESULT[@]}"; do
    printf '%s\t%s\n' "$k" "${RESULT[$k]}"
  done > "$_hc_tmp"
  python3 - "$_hc_tmp" "$EXIT" <<'PYEOF'
import json, sys
checks = {}
with open(sys.argv[1]) as f:
    for line in f:
        k, _, v = line.rstrip('\n').partition('\t')
        group, _, field = k.rpartition('.')
        checks.setdefault(group, {})[field] = v
print(json.dumps({'overall': 'ok' if sys.argv[2] == '0' else 'fail', 'checks': checks}, indent=2))
PYEOF
  rm -f "$_hc_tmp"
fi

exit $EXIT
