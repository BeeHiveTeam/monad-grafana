# Monad Node — Grafana Stack

Self-hosted Prometheus + Grafana for a [Monad](https://www.monad.xyz/) testnet/mainnet node, with a 47-panel dashboard covering sync status, vote delay, consensus events, system resources, disk, network, txpool, raptorcast traffic, and 20+ error categories.

Built on top of the **OpenTelemetry collector that Monad already bundles** with the node — no extra agents on the host, just three Docker containers.

![Monad Node Overview Dashboard](docs/dashboard-screenshot.png)
*(screenshot — replace with your own)*

---

## What you get

- **Prometheus** (port `9090`, loopback-only) — scrapes Monad's bundled `otelcol-contrib` on `:8889` plus a sidecar RPC exporter. 30 days / 10 GB retention.
- **Grafana** (port `3000`, loopback-only) — Prometheus pre-provisioned as default datasource, dashboard auto-loaded on startup.
- **monad-rpc-exporter** (port `9101`, loopback-only) — Python 3 sidecar (stdlib only, no pip deps) that polls JSON-RPC for block height + sync gap, reads `/proc` for service uptime.
- **47-panel dashboard** with sections: Sync · Service uptime / peers · Vote delay · System resources · Disk · TxPool / Raptorcast · Errors / failures.

Total resource footprint: ~95 MB RAM, ~0.1% CPU. Designed not to interfere with the Monad node itself.

---

## Requirements

- Linux x86_64 host running a Monad node with `monad-bft.service`, `monad-execution.service`, `monad-rpc.service`
- Monad's bundled `otelcol-contrib` running and exposing Prometheus metrics on `:8889` (default install does this)
- Docker 20+ with `docker compose` plugin
- ~1 GB free disk for Prometheus data (30-day retention)
- `sudo` for the initial `ufw` rule
- Optional: `cloudflared` if you want public HTTPS access without opening ports

---

## Quick start (5 minutes)

```bash
# 1. Clone
git clone https://github.com/YOUR-ORG/monad-grafana.git
cd monad-grafana

# 2. Generate Grafana admin password
cp .env.example .env
GRAFANA_PASS=$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)
sed -i "s|changeme-please-generate-strong-password|$GRAFANA_PASS|" .env
echo "Grafana admin password: $GRAFANA_PASS"   # save it now
chmod 600 .env

# 3. Allow Docker bridge to reach Monad's otelcol :8889 and JSON-RPC :8080.
# UFW default-deny INPUT will block the docker subnet otherwise.
DOCKER_SUBNET=172.18.0.0/16   # default monitoring_monitoring bridge subnet
sudo ufw allow from $DOCKER_SUBNET to any port 8889 proto tcp comment 'monitoring → otelcol'
sudo ufw allow from $DOCKER_SUBNET to any port 8080 proto tcp comment 'monitoring → monad-rpc'

# 4. Start the stack
docker compose up -d

# 5. Verify (give scrapes ~20 sec to populate)
sleep 20
curl -s http://127.0.0.1:9090/api/v1/targets | grep -oE '"health":"[a-z]+"'
# expect:  "health":"up"   "health":"up"   "health":"up"
```

Open Grafana via SSH tunnel from your laptop:

```bash
ssh -L 3000:127.0.0.1:3000 -L 9090:127.0.0.1:9090 ubuntu@YOUR.NODE.IP
```

Then browse to <http://localhost:3000>, login `admin` / `<the password from step 2>`. Dashboard «Monad Node — Overview» loads automatically.

---

## Repository layout

```
monad-grafana/
├── docker-compose.yml                     # 3 services: prometheus, grafana, rpc-exporter
├── .env.example                           # template for Grafana admin password
├── prometheus/
│   └── prometheus.yml                     # scrape config (otelcol :8889 + rpc-exporter :9101)
├── grafana/
│   ├── provisioning/
│   │   ├── datasources/prometheus.yaml    # auto-load Prometheus as default datasource
│   │   └── dashboards/monad.yaml          # auto-load dashboard on startup
│   └── dashboards/
│       └── monad-overview.json            # 47-panel dashboard
└── exporter/
    └── exporter.py                        # Python sidecar (stdlib only)
```

---

## What's inside the dashboard (47 panels)

**Sync status** — Local block height · Public block height · Sync gap · Last block age · RPC up indicators · Block commit rate · Local timeouts/min

**Service uptime · Peers** — `monad-bft` / `monad-execution` / `monad-rpc` uptime · Active / pending peers · Upstream validators · Raptorcast groups

**Vote delay** — p50/p90/p99 stats with thresholds · over-time chart · consensus events rate

**System resources** — CPU usage gauge · Load average bargauge (vs cores) · Memory donut · Swap usage gauge · CPU/memory/swap timeseries

**Disk · Filesystem** — IO bytes/sec per device · operations/sec · pending queue · filesystem usage % · free space

**TxPool · Raptorcast** — tracked txs · tracked addresses · insert/sec · drop reasons · UDP rx/tx bytes · broadcast latency p99

**Errors / failures** — 14 validation error types · 6 wireauth error types · blocksync failures · statesync · blocktree · network errors · raptorcast recv errors · consensus timeouts/failures

---

## Configuration

### Pointing at a non-standard RPC

Defaults assume Monad RPC on `localhost:8080` and public testnet at `https://testnet-rpc.monad.xyz`. Override in `.env`:

```ini
LOCAL_RPC_URL=http://host.docker.internal:8080
PUBLIC_RPC_URL=https://testnet-rpc.monad.xyz
```

### Hostname / network labels

Edit `prometheus/prometheus.yml`:

```yaml
global:
  external_labels:
    host: my-node-name
    network: testnet      # or mainnet
```

Then `docker compose restart prometheus`.

### Dashboard customization

The provisioned dashboard is read-only by default but `allowUiUpdates: true` (see `grafana/provisioning/dashboards/monad.yaml`) lets you edit and save in the UI. Saved JSON lives in the Grafana volume; to make it permanent in git, export and replace `grafana/dashboards/monad-overview.json`:

```bash
curl -s -u "admin:$PASS" http://127.0.0.1:3000/api/dashboards/uid/cfkugnwjq8kjkb \
  | jq '.dashboard | del(.id, .version)' > grafana/dashboards/monad-overview.json
git diff grafana/dashboards/
```

---

## Public access (optional)

The default setup exposes nothing to the internet. Pick one of these if you need browser access without SSH tunnel:

### Cloudflare Quick Tunnel — temporary, for one-off viewing

```bash
sudo curl -fsSL --output /usr/local/bin/cloudflared \
  https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
sudo chmod +x /usr/local/bin/cloudflared
nohup cloudflared tunnel --url http://127.0.0.1:3000 > /tmp/cf-tunnel.log 2>&1 &
grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' /tmp/cf-tunnel.log
```

Random `https://*.trycloudflare.com` URL, max 24h lifetime, killed by `kill $(pgrep cloudflared)`.

### Cloudflare Tunnel + Access — permanent, with email gate

Best long-term option:

1. Create a tunnel in Cloudflare Zero Trust dashboard, install `cloudflared` as a service with the connector token.
2. Add hostname `grafana.your-domain.com` → `http://localhost:3000`.
3. Add Access policy: allow only your email.

Zero open ports, TLS by Cloudflare, double auth (Access + Grafana login).

### nginx + Let's Encrypt — classic

Open 80/443 in UFW, point a DNS A-record at your server, `certbot --nginx`, proxy_pass to `127.0.0.1:3000`. Optionally add IP allowlist (`allow x.x.x.x; deny all;`).

---

## Troubleshooting

**`monad-otelcol` target shows DOWN with `context deadline exceeded`.**
The Docker bridge subnet isn't allowed through UFW to reach `:8889` on the host. Confirm subnet:

```bash
docker network inspect monad-grafana_monitoring --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}'
# e.g. 172.18.0.0/16
sudo ufw allow from 172.18.0.0/16 to any port 8889 proto tcp
```

If the subnet differs from the one in Quick Start, use the actual one from the command above.

**`monad-rpc-exporter` shows `monad_local_block_number 0`.**
The exporter can't reach Monad RPC. Check:

```bash
docker logs monad-rpc-exporter
docker exec monad-rpc-exporter wget -qO- --timeout=3 http://host.docker.internal:8080
```

If `wget` fails: missing UFW rule for `8080` (see Quick Start step 3) or RPC binds only to `127.0.0.1`. In the latter case set `LOCAL_RPC_URL=http://172.18.0.1:8080` (host-gateway IP) in `.env`.

**`monad_service_uptime_seconds` is missing.**
Container needs `pid: host` (already in `docker-compose.yml`) AND your `docker` build must support PID namespace sharing. Verify with:

```bash
docker exec monad-rpc-exporter ls /proc/1/comm
docker exec monad-rpc-exporter cat /proc/1/comm
# should print 'systemd' (host PID 1), not 'python3' (container PID 1)
```

**Dashboard panels are empty.**
- Wait 30 sec after first start (Prometheus needs 1-2 scrape cycles).
- Open Prometheus directly via tunnel: <http://localhost:9090/targets> — confirm all 3 jobs are UP.
- Try a query in <http://localhost:9090/graph>: `monad_local_block_number` — if returns data, Grafana datasource is misconfigured.

**Disk fills up faster than expected.**
30-day retention with default scrape interval = ~1-2 GB. If higher, check `--storage.tsdb.retention.size=10GB` cap in `docker-compose.yml`.

---

## Operations

```bash
docker compose ps           # service status
docker compose logs -f      # live logs
docker compose restart      # restart everything
docker compose down         # stop (volumes preserved)
docker compose down -v      # full wipe (data lost)
docker compose pull         # update images
docker compose up -d        # apply updates
```

Prometheus has reload endpoint (no restart needed for config changes):

```bash
curl -X POST http://127.0.0.1:9090/-/reload
```

---

## Security notes

- All ports bind to `127.0.0.1` only — nothing exposed to the internet by default.
- Grafana password lives in `.env` (mode `0600`, root-only).
- The UFW rules added in Quick Start scope access to the Docker bridge subnet only — outside hosts cannot reach `:8889` or `:8080`.
- The RPC exporter has read-only filesystem mount and `pid: host` for `/proc` access; no shell, no network listeners besides `:9101`.
- If exposing Grafana publicly, use Cloudflare Access or nginx + auth on top of Grafana login (defence in depth).

---

## Credits

- Built around the OpenTelemetry collector bundled with Monad's official node distribution.
- Dashboard structure inspired by community Grafana dashboards for Cosmos / Solana validators.

## License

MIT — see [LICENSE](LICENSE).
