# Monad Node — Grafana Stack

Self-hosted Prometheus + Grafana for a [Monad](https://www.monad.xyz/) testnet/mainnet node, with a 47-panel dashboard covering sync status, vote delay, consensus events, system resources, disk, network, txpool, raptorcast traffic, and 20+ error categories.

Built on top of the **OpenTelemetry collector that Monad already bundles** with the node — no extra agents on the host, just three Docker containers.

![Monad Node Overview Dashboard](docs/dashboard-screenshot.png)
*(screenshot — replace with your own)*

---

## What you get

- **Prometheus** (port `9090`, loopback-only) — scrapes the OpenTelemetry collector exposing Prometheus metrics on `:8889` plus a sidecar RPC exporter. 30 days / 10 GB retention. **Works with either plain `otelcol`** (Monad apt default) **or `otelcol-contrib`** (richer receivers — required only if you want to ship logs to Loki via the journald receiver). The installer auto-detects which is active and operates on the matching config path; override with `OTELCOL_SVC=otelcol-contrib` if both are present.
- **Grafana** (port `3000`, loopback-only) — Prometheus pre-provisioned as default datasource, dashboard auto-loaded on startup.
- **monad-rpc-exporter** (port `9101`, loopback-only) — Python 3 sidecar (stdlib only, no pip deps) that polls JSON-RPC for block height + sync gap, reads `/proc` for service uptime. Runs as `nobody` (uid 65534) — not root.
- **47-panel dashboard** with sections: Sync · Service uptime / peers · Vote delay · System resources · Disk · TxPool / Raptorcast · Errors / failures. **Datasource templated** — works with multiple Prometheus instances. **No hardcoded device/interface names** — adapts to whatever NVMe/NIC names your host uses.

Total resource footprint: ~95 MB RAM, ~0.1% CPU. Designed not to interfere with the Monad node itself. Container logs are rotated (json-file driver, 10 MB × 3 files per service) — won't fill the disk.

---

## Requirements

- Linux x86_64 host running a Monad node with `monad-bft.service`, `monad-execution.service`, `monad-rpc.service`
- An OpenTelemetry collector exposing Prometheus metrics on `:8889`. **Monad apt installs plain `otelcol`** — that's the default and works out of the box for this stack. The installer auto-detects which OTel collector is active (`otelcol` or `otelcol-contrib`) and edits the correct config path when applying the hostmetrics overlay. If you want **journald → Loki** log pipelines (the contrib-only receiver), install `otelcol-contrib` separately (`apt install otelcol-contrib`).
- Docker 20+ with `docker compose` plugin (auto-installed by `install.sh` if missing)
- ~1 GB free disk for Prometheus data (30-day retention)
- `sudo` for initial `ufw` rule and otelcol config edit
- Optional: `cloudflared` if you want public HTTPS access without opening ports

### Heads-up on the default Monad config

The bundled OTel config (`/etc/otelcol/config.yaml` for plain `otelcol`, or `/etc/otelcol-contrib/config.yaml` if you switched) only forwards `monad_*` metrics from the node (vote delay, consensus events, peers, txpool). It does **not** include the **`hostmetrics`** receiver, so without an overlay these dashboard panels will be empty:

> CPU usage / Load average / Memory / Swap / Disk IO / Filesystem usage / Network errors

The auto-installer detects this gap and offers to apply a one-time overlay (with backup + restart). You can also run it later: `sudo /opt/monad-grafana/install.sh --enable-hostmetrics`. See [`docs/ENABLE_HOSTMETRICS.md`](docs/ENABLE_HOSTMETRICS.md) for the manual procedure if you'd rather review-then-apply by hand.

### Heads-up on VDP OTel push (May 2026 onward)

If you've enabled the MF VDP push (see [BeeHive monad-tools `docs/vdp-otel-push.md`](https://github.com/BeeHiveTeam/monad-tools/blob/main/docs/vdp-otel-push.md)), your OTel collector pushes `monad_*` metrics to `otel-external.monadinfra.com:443`. This stack continues to work alongside: VDP push is a **second exporter** in the same pipeline, the local Prometheus exporter on `:8889` stays available for our Grafana to scrape.

If you run a custom `otelcol-contrib` with `journald → Loki` plus VDP push (our recommended split-pipelines pattern), this stack also works — it just scrapes `:8889` regardless of how many other exporters are attached. The hostmetrics overlay shipped here is compatible with both setups.

### Heads-up on NTP

`vote_delay_ready_after_timer_start` is sensitive to clock skew. `systemd-timesyncd` (Ubuntu/Debian default) drifts ~10–100ms, which makes the p99 panels look 30–80ms worse than reality and triggers false alerts. The installer offers to replace it with `chrony` (sub-ms accuracy, kernel discipline). Strongly recommended.

---

## Quick start — one command (recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/BeeHiveTeam/monad-grafana/main/install.sh | sudo bash
```

The auto-installer does everything end-to-end:

1. Pre-flight: OS, free disk, **available RAM**, **Docker ≥20.10** (host-gateway), free ports `9090`/`3000`/`9101`
2. **Verifies Monad is running** — `monad-bft.service`, `:8889` (otelcol). RPC `:8080` is checked but non-fatal (validator-only setups may not run it).
3. **Installs Docker** if missing (via official `get.docker.com`, with confirmation)
4. **Detects existing `/opt/monitoring/`** stack and offers to stop it (container-name conflicts)
5. Clones repo to `/opt/monad-grafana`
6. **`configure_prometheus`**: sets `external_labels: host: $(hostname -s)` automatically — no manual edit needed
7. Optional **`check_chrony`**: warns if you're on `systemd-timesyncd` (drifts 10-100 ms, inflates p99 vote_delay) and offers to install chrony
8. Optional **`check_hostmetrics`**: detects whether otelcol exposes `system_*` metrics on `:8889` and offers to apply the overlay (backups + restart)
9. Generates Grafana password, writes `.env` (mode `0600`)
10. `docker compose up -d`
11. Auto-detects Docker bridge subnet, adds **UFW allow rules** for `:8889` + `:8080`
12. Reloads Prometheus, waits, verifies all targets `UP`
13. Prints SSH-tunnel command + URL + admin password

When done you'll see:

```
═══════════════════════════════════════════════
  Monad Grafana stack — installed and running
═══════════════════════════════════════════════

  Open Grafana via SSH tunnel from your laptop:

    ssh -L 3000:127.0.0.1:3000 -L 9090:127.0.0.1:9090 user@your.server

  Then in browser:  http://localhost:3000

    Login:    admin
    Password: <generated 32-char>
```

### Manual install (review the script first)

```bash
git clone https://github.com/BeeHiveTeam/monad-grafana.git
cd monad-grafana
less install.sh           # read what it does
sudo ./install.sh
```

### Installer flags

```
sudo ./install.sh --help
sudo ./install.sh --non-interactive                 # CI mode, no prompts
sudo ./install.sh --prefix=/srv/monitoring          # custom path
sudo ./install.sh --local-rpc=http://1.2.3.4:8080   # remote Monad RPC
sudo ./install.sh --public-rpc=https://...          # alternate public RPC
sudo ./install.sh --upgrade                         # git pull + docker pull + recreate
sudo ./install.sh --enable-hostmetrics              # apply hostmetrics overlay separately
sudo ./install.sh --uninstall                       # stop, remove, optionally clean UFW
```

## Health check

After install, run anytime:

```bash
/opt/monad-grafana/scripts/healthcheck.sh
# ✓ container.prometheus: running
# ✓ container.grafana: running
# ✓ container.monad-rpc-exporter: running
# ✓ prometheus.ready
# ✓ target.monad-otelcol
# ✓ target.monad-rpc-exporter
# ✓ target.prometheus
# ✓ sync.gap: 0 blocks
# ✓ block.age: 4s
# ✓ grafana.health

./scripts/healthcheck.sh --quiet --json   # CI / cron / piped
```

Returns exit `0` if everything is healthy, `1` otherwise. Add to cron for periodic check:

```cron
*/5 * * * * /opt/monad-grafana/scripts/healthcheck.sh --quiet 2>&1 | logger -t monad-mon
```

---

## Repository layout

```
monad-grafana/
├── install.sh                             # auto-installer (preflight, deps, ufw, verify)
├── docker-compose.yml                     # 3 services with logging rotation
├── .env.example                           # template for Grafana admin password
├── prometheus/
│   └── prometheus.yml                     # scrape config (otelcol :8889 + rpc-exporter :9101)
├── grafana/
│   ├── provisioning/
│   │   ├── datasources/prometheus.yaml    # auto-load Prometheus as default datasource
│   │   └── dashboards/monad.yaml          # auto-load dashboard on startup
│   └── dashboards/
│       └── monad-overview.json            # 47-panel dashboard, datasource-templated
├── exporter/
│   └── exporter.py                        # Python sidecar (stdlib only, runs as nobody)
├── scripts/
│   ├── healthcheck.sh                     # post-install verification (cron-friendly)
│   └── apply_hostmetrics_overlay.py       # adds hostmetrics receiver to /etc/otelcol-contrib
└── docs/
    └── ENABLE_HOSTMETRICS.md              # manual procedure (review-then-apply)
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

The installer **auto-sets** `external_labels.host` to `$(hostname -s)` during install. Override only if you want a custom moniker — edit `prometheus/prometheus.yml`:

```yaml
global:
  external_labels:
    host: my-custom-moniker
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
- The UFW rules added by the installer scope access to the Docker bridge subnet only — outside hosts cannot reach `:8889` or `:8080`.
- The **RPC exporter runs as `nobody` (uid 65534)** with read-only filesystem mount and `pid: host` for `/proc` access. Reading `/proc/<pid>/comm` and `/proc/<pid>/stat` is world-readable so root isn't needed — drops the risk of accidentally reading the validator's `/proc/<bft-pid>/environ` if BLS keys leak there.
- Container logs are bounded by `json-file` driver with `max-size: 10m`, `max-file: 3` per service — won't fill the disk.
- All three services have explicit `mem_limit` + `cpus` constraints (Prometheus 512m/1.0, Grafana 512m/0.5, exporter 64m/0.1) so they can't starve the validator.
- If exposing Grafana publicly, use Cloudflare Access or nginx + auth on top of Grafana login (defence in depth).

---

## Credits

- Built around the OpenTelemetry collector bundled with Monad's official node distribution.
- Dashboard structure inspired by community Grafana dashboards for Cosmos / Solana validators.

## License

MIT — see [LICENSE](LICENSE).
