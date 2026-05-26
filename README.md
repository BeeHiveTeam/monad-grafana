# Monad Node — Grafana Stack

Self-hosted Prometheus + Grafana for a [Monad](https://www.monad.xyz/) testnet/mainnet node, with a 49-panel dashboard covering sync status, vote delay, consensus events, host resources, disk I/O, network, txpool, raptorcast traffic, and 20+ error categories.

Built on top of the **OpenTelemetry collector that Monad already bundles** (`monad_*` metrics on `:8889`) plus a Prometheus-standard `node_exporter` for host metrics — no agents on the host beyond Docker containers.

![Monad Node Overview Dashboard](docs/dashboard-screenshot.png)
*(screenshot — replace with your own)*

---

## What you get

Four Docker containers, ~160 MB RAM total, ~0.2% CPU:

| Container | Port (bind) | What |
|---|---|---|
| **Prometheus** | `127.0.0.1:9090` | Scrapes 4 targets (otelcol, rpc-exporter, node-exporter, self). 30-day / 10 GB retention. |
| **Grafana** | `127.0.0.1:3000` (or `0.0.0.0:3000` with `--public`) | Prometheus pre-provisioned, dashboard auto-loaded. |
| **monad-rpc-exporter** | `127.0.0.1:9101` | Python sidecar (stdlib only) — polls JSON-RPC for block height + sync gap, reads `/proc` for service uptime. Runs as `nobody` (uid 65534). |
| **node-exporter** | host `:9100` (UFW-restricted to bridge subnet) | Prometheus standard host metrics: CPU, memory, swap, load average, disk I/O, filesystem, network — fills the panels that `monad_*` metrics don't cover. |

**Dashboard**: 49 visible panels across 8 sections — Sync · Service uptime / peers · Vote delay · Host resources · Disk · Network · TxPool / Raptorcast · Errors. **Datasource templated** (works with multiple Prometheus instances) and **no hardcoded device/interface names** (adapts to whatever NVMe/NIC names your host uses).

Container logs are rotated (json-file driver, 10 MB × 3 files per service) — won't fill the disk. Each container has explicit `mem_limit` + `cpus` constraints so they can't starve the validator.

---

## Requirements

- Linux x86_64 host running a Monad node with `monad-bft.service`, `monad-execution.service`, `monad-rpc.service`
- An OpenTelemetry collector exposing Prometheus metrics on `:8889`. **Monad apt installs plain `otelcol`** (the Core OpenTelemetry distribution) — that's the default and works out of the box. The installer auto-detects which collector is active (`otelcol` or `otelcol-contrib`) and operates on the matching config path. Override with `OTELCOL_SVC=otelcol-contrib` if both are present.
- Docker 20+ with `docker compose` plugin (auto-installed by `install.sh` if missing)
- ~1 GB free disk for Prometheus data (30-day retention)
- `sudo` for initial `ufw` rules and (if you opt in) `otelcol` config edit
- Optional: a domain/Cloudflare account if you want TLS-protected public access

### Heads-up on host metrics — `node_exporter` vs `hostmetrics` overlay

`docs.monad.xyz` mandates the **plain `otelcol`** distribution for VDP push. Plain otelcol is Core-only — it **does not** ship the `hostmetrics` receiver (that's `otelcol-contrib` territory).

To fill the host panels (CPU/RAM/disk/network) without breaking VDP push, this stack ships **`node_exporter`** as a 4th container (Prometheus-standard, no otelcol config edit). It runs in `network_mode: host` + `pid: host` so it sees real NICs and the real `/proc`, not container namespaces.

If you actually run `otelcol-contrib`, the installer also offers a one-time `hostmetrics` overlay (with backup + auto-restore on restart failure). On plain `otelcol` it auto-detects the missing receiver and **skips the prompt** — no risk of breaking your collector. See [`docs/ENABLE_HOSTMETRICS.md`](docs/ENABLE_HOSTMETRICS.md) for the manual procedure.

### Heads-up on VDP OTel push (May 2026 onward)

If you've enabled the MF VDP push (see [BeeHive monad-tools `docs/vdp-otel-push.md`](https://github.com/BeeHiveTeam/monad-tools/blob/main/docs/vdp-otel-push.md)), your OTel collector pushes `monad_*` metrics to `otel-external.monadinfra.com:443`. This stack continues to work alongside: VDP push is a **second exporter** in the same pipeline, the local Prometheus exporter on `:8889` stays available for Grafana to scrape.

If you run a custom `otelcol-contrib` with `journald → Loki` plus VDP push (the recommended split-pipelines pattern), this stack also works — it just scrapes `:8889` regardless of how many other exporters are attached.

### Heads-up on NTP

`vote_delay_ready_after_timer_start` is sensitive to clock skew. `systemd-timesyncd` (Ubuntu/Debian default) drifts ~10–100 ms, which makes the p99 panels look 30–80 ms worse than reality and triggers false alerts. The installer offers to replace it with `chrony` (sub-ms accuracy, kernel discipline). Strongly recommended.

---

## Quick start

The installer asks two questions on first run:

1. **All-in-one or Split?** All-in-one puts monitoring on the same server as the Monad node (quick); Split puts monitoring on a separate server (recommended by Monad Foundation security advisory).
2. **If Split — which server are you on?** Monitor server or Monad node.

### Deployment mode 1 — All-in-one (monitoring on the same server as the node)

```bash
curl -fsSL https://raw.githubusercontent.com/BeeHiveTeam/monad-grafana/main/install.sh | sudo bash
```

Choose `[1] All-in-one` when prompted. The installer prints a **security warning** explaining the risk (single attack surface, resource contention with monad-execution, single point of failure) and asks for an explicit `y` to continue.

Grafana ends up on `127.0.0.1:3000`. Access from your laptop:

```
ssh -L 3000:127.0.0.1:3000 -L 9090:127.0.0.1:9090 user@your.server
# then open http://localhost:3000
```

### Deployment mode 2 — Split (monitoring on a separate server)

Run the same installer on **both** servers — it auto-detects which side it's on.

**Step 1: on the Monad node.**

```bash
curl -fsSL https://raw.githubusercontent.com/BeeHiveTeam/monad-grafana/main/install.sh | sudo bash
```

Choose `[2] Split` → `[2] Monad node`. Enter the monitor server's IP when asked.
The installer:
- installs `prometheus-node-exporter` (systemd, binds `0.0.0.0:9100`)
- opens UFW from monitor-IP → `:8889` (otelcol), `:9100` (node-exporter), `:8080` (RPC)
- self-tests all three endpoints
- prints "ready"

**Step 2: on the monitoring server.**

```bash
curl -fsSL https://raw.githubusercontent.com/BeeHiveTeam/monad-grafana/main/install.sh | sudo bash
```

Choose `[2] Split` → `[1] Monitoring server`. Enter the Monad node's IP when asked.
The installer:
- probes node:8889/9100/8080 to confirm reachability and detect testnet/mainnet
- if step 1 hasn't been done yet, prints the exact command to run on the node and **polls every 10s for 5 minutes** until ports come up — then auto-continues
- writes `prometheus.yml` with the remote node IP as scrape target
- brings up Prometheus + Grafana

**Either order works** — start on whichever server you have a terminal open on.

### One command — public access (browser direct, with admin password)

```bash
sudo bash -c 'curl -fsSL https://raw.githubusercontent.com/BeeHiveTeam/monad-grafana/main/install.sh -o /tmp/mg.sh && bash /tmp/mg.sh --public'
```

This binds Grafana on `0.0.0.0:3000` and opens UFW `:3000/tcp`. The installer prints the URL + auto-generated admin password at the end:

```
═══════════════════════════════════════════════
  Monad Grafana stack — installed and running
═══════════════════════════════════════════════

  Public access ENABLED — Grafana reachable from anywhere:

    URL:      http://<server-ip>:3000
    Login:    admin
    Password: <generated 32-char>

  Grafana is the only auth layer — there is no TLS by default (HTTP).
  Share these credentials only with people who should see the dashboard.
  Rotate password: edit GF_SECURITY_ADMIN_PASSWORD in /opt/monad-grafana/.env
                   then docker compose up -d
```

`--public` is suitable for **review / show-and-tell** (Foundation, delegators, auditors). For long-term public exposure, put nginx + Let's Encrypt or a Cloudflare Tunnel in front and run the installer without `--public` — see [Public access](#public-access-tls--auth) below.

### What the installer does end-to-end

1. **Pre-flight**: OS, free disk, available RAM, Docker ≥20.10, free ports `9090`/`3000`/`9101`
2. **Verifies Monad is running** — `monad-bft.service` + `:8889` (otelcol). RPC `:8080` is checked but non-fatal (validator-only setups may not expose it).
3. **Installs Docker** if missing (via official `get.docker.com`, with confirmation)
4. **Detects existing `/opt/monitoring/`** stack and offers to stop it (container-name conflicts)
5. **Clones repo** to `/opt/monad-grafana`
6. **`configure_prometheus`**: sets `external_labels: host: $(hostname -s)` automatically
7. **`check_chrony`**: warns if you're on `systemd-timesyncd` and offers to install chrony
8. **`check_hostmetrics`**:
   - On `otelcol-contrib`: detects whether `hostmetrics` is enabled and offers to apply the overlay (with backup + auto-restore on restart failure)
   - On plain `otelcol`: skips the prompt with an INFO that host panels will be filled by `node_exporter` (already part of the stack) — no risk to your collector
9. **`generate_env`**: generates Grafana admin password, writes `.env` (mode `0600` root-only)
10. **`apply_grafana_bind`**: sets `GRAFANA_BIND=127.0.0.1` (default) or `0.0.0.0` (if `--public`)
11. **`docker compose up -d`** — brings up all four containers
12. **`setup_ufw`** — auto-detects the Docker bridge subnet and adds allow rules: `:8889` (otelcol), `:8080` (Monad RPC), `:9100` (node-exporter). With `--public`, also opens `:3000/tcp` for anywhere.
13. **`verify`** — reloads Prometheus, waits 20s for first scrape, confirms all 4 targets UP
14. **`print_access`** — prints the right access pattern (SSH-tunnel command + URL + admin password, or direct URL with `--public`)

### Manual install (review the script first)

```bash
git clone https://github.com/BeeHiveTeam/monad-grafana.git
cd monad-grafana
less install.sh           # read what it does
sudo ./install.sh           # interactive
sudo ./install.sh --public  # bind Grafana on 0.0.0.0:3000 + open UFW :3000
```

### Installer flags

```
sudo ./install.sh --help
sudo ./install.sh --public                          # bind Grafana on 0.0.0.0:3000 + open UFW :3000
sudo ./install.sh --non-interactive                 # CI mode, no prompts
sudo ./install.sh --prefix=/srv/monitoring          # custom path
sudo ./install.sh --local-rpc=http://1.2.3.4:8080   # remote Monad RPC
sudo ./install.sh --public-rpc=https://...          # alternate public RPC for sync-gap calc
sudo ./install.sh --upgrade                         # git pull + docker pull + recreate
sudo ./install.sh --enable-hostmetrics              # apply hostmetrics overlay separately
                                                    # (refuses cleanly on plain otelcol)
sudo ./install.sh --uninstall                       # stop, remove, optionally clean UFW
```

Environment variables override flags: `PREFIX`, `LOCAL_RPC_URL`, `PUBLIC_RPC_URL`, `PUBLIC_ACCESS`, `NON_INTERACTIVE`, `OTELCOL_SVC`.

---

## Health check

After install, run anytime:

```bash
/opt/monad-grafana/scripts/healthcheck.sh
# ✓ container.prometheus: running
# ✓ container.grafana: running
# ✓ container.monad-rpc-exporter: running
# ✓ container.node-exporter: running
# ✓ prometheus.ready
# ✓ target.monad-otelcol
# ✓ target.monad-rpc-exporter
# ✓ target.node-exporter
# ✓ target.prometheus
# ✓ sync.gap: 0 blocks
# ✓ block.age: 4s
# ✓ grafana.health

./scripts/healthcheck.sh --quiet --json   # CI / cron / piped
```

Returns exit `0` if everything is healthy, `1` otherwise. Cron example:

```cron
*/5 * * * * /opt/monad-grafana/scripts/healthcheck.sh --quiet 2>&1 | logger -t monad-mon
```

---

## Repository layout

```
monad-grafana/
├── install.sh                             # auto-installer (preflight, deps, ufw, verify)
├── docker-compose.yml                     # 4 services: prometheus, grafana, rpc-exporter, node-exporter
├── .env.example                           # template for Grafana admin password
├── prometheus/
│   └── prometheus.yml                     # scrape config (otelcol :8889 + rpc-exporter :9101 + node-exporter :9100)
├── grafana/
│   ├── provisioning/
│   │   ├── datasources/prometheus.yaml    # auto-load Prometheus as default datasource
│   │   └── dashboards/monad.yaml          # auto-load dashboard on startup
│   └── dashboards/
│       └── monad-overview.json            # 49-panel dashboard, datasource-templated
├── exporter/
│   └── exporter.py                        # Python sidecar (stdlib only, runs as nobody)
├── scripts/
│   ├── healthcheck.sh                     # post-install verification (cron-friendly)
│   └── apply_hostmetrics_overlay.py       # adds hostmetrics receiver to otelcol-contrib config
└── docs/
    └── ENABLE_HOSTMETRICS.md              # manual procedure (review-then-apply)
```

---

## What's inside the dashboard (49 panels)

**Sync status** — Local block height · Public block height · Sync gap · Last block age · RPC up indicators · Block commit rate · Local timeouts/min

**Service uptime · Peers** — `monad-bft` / `monad-execution` / `monad-rpc` uptime · Active / pending peers · Upstream validators · Raptorcast groups

**Vote delay** — p50/p90/p99 stats with thresholds · over-time chart · consensus events rate

**Host resources** (via `node_exporter`) — CPU usage gauge · Load average bargauge (vs cores) · Memory breakdown (used/available/cached) · Swap usage · CPU per-mode timeseries · Memory + swap over time

**Disk · Filesystem** (via `node_exporter`) — IO bytes/sec per device · operations/sec · pending queue depth · filesystem usage % · free space

**Network** (via `node_exporter`) — Throughput per NIC · Errors · Dropped packets

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

### Grafana bind interface (loopback vs public)

Controlled by `GRAFANA_BIND` in `.env`:

| Value | Effect |
|---|---|
| `127.0.0.1` (default) | Grafana on loopback only — access via SSH tunnel |
| `0.0.0.0` (set by `--public`) | Grafana reachable from anywhere — admin/password auth is the only protection (no TLS) |

The installer rewrites this line every run based on the `--public` flag, so subsequent `--upgrade`s keep the chosen mode.

### Dashboard customization

The provisioned dashboard is read-only by default but `allowUiUpdates: true` (see `grafana/provisioning/dashboards/monad.yaml`) lets you edit and save in the UI. Saved JSON lives in the Grafana volume; to make it permanent in git, export and replace `grafana/dashboards/monad-overview.json`:

```bash
curl -s -u "admin:$PASS" http://127.0.0.1:3000/api/dashboards/uid/cfkugnwjq8kjkb \
  | jq '.dashboard | del(.id, .version)' > grafana/dashboards/monad-overview.json
git diff grafana/dashboards/
```

---

## Public access (TLS + auth)

The `--public` installer flag binds Grafana on `0.0.0.0:3000` over plain HTTP. That's fine for short-lived review/demo windows but **not** for long-term public exposure. For that, run the installer **without** `--public` and put a TLS-terminating reverse proxy in front.

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

1. Create a tunnel in Cloudflare Zero Trust dashboard, install `cloudflared` as a service with the connector token.
2. Add hostname `grafana.your-domain.com` → `http://localhost:3000`.
3. Add Access policy: allow only your email / SSO group.

Zero open ports, TLS by Cloudflare, double auth (Access + Grafana login).

### nginx + Let's Encrypt — classic

Open 80/443 in UFW, point a DNS A-record at your server, `certbot --nginx`, proxy_pass to `127.0.0.1:3000`. Optionally add IP allowlist (`allow x.x.x.x; deny all;`).

---

## Troubleshooting

**`node-exporter` target shows DOWN with `context deadline exceeded`.**
Either the container didn't recreate after `--upgrade` (still listening on the wrong interface), or UFW is blocking the bridge → host gateway on `:9100`. Check:

```bash
sudo docker inspect node-exporter --format '{{json .Args}}'   # should include --web.listen-address=0.0.0.0:9100
sudo ss -tlnp | grep :9100                                    # should be 0.0.0.0:9100, not 127.0.0.1:9100
sudo ufw status | grep 9100                                    # should ALLOW from <bridge-subnet>
```

If the listen address is wrong: `cd /opt/monad-grafana && sudo docker compose up -d --force-recreate node-exporter`. If UFW rule is missing: re-run `sudo /opt/monad-grafana/install.sh --upgrade`.

**`monad-otelcol` target shows DOWN with `context deadline exceeded`.**
The Docker bridge subnet isn't allowed through UFW to reach `:8889` on the host. Confirm subnet:

```bash
docker network inspect monad-grafana_monitoring --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}'
# e.g. 172.18.0.0/16
sudo ufw allow from 172.18.0.0/16 to any port 8889 proto tcp
```

**`monad-rpc-exporter` shows `monad_local_block_number 0`.**
The exporter can't reach Monad RPC. Check:

```bash
docker logs monad-rpc-exporter
docker exec monad-rpc-exporter wget -qO- --timeout=3 http://host.docker.internal:8080
```

If `wget` fails: missing UFW rule for `:8080` (the installer adds one for the bridge subnet — verify with `ufw status | grep 8080`), or RPC binds only to `127.0.0.1`. In the latter case set `LOCAL_RPC_URL=http://<bridge-gateway-ip>:8080` in `.env`.

**`monad_service_uptime_seconds` is missing.**
The exporter container needs `pid: host` (already in `docker-compose.yml`) AND your Docker build must support PID namespace sharing. Verify:

```bash
docker exec monad-rpc-exporter cat /proc/1/comm
# should print 'systemd' (host PID 1), not 'python3' (container PID 1)
```

**`hostmetrics` overlay failed and otelcol won't start.**
The installer's `apply_hostmetrics()` auto-restores the most recent `.bak.<ts>` file when otelcol fails to restart (since commit `1dcbdea`). If you're running an older version of this stack and got stuck: `sudo cp /etc/otelcol/config.yaml.bak.* /etc/otelcol/config.yaml && sudo systemctl reset-failed otelcol && sudo systemctl start otelcol`.

**Dashboard panels are empty.**
- Wait 30 sec after first start (Prometheus needs 1–2 scrape cycles).
- Open Prometheus directly: <http://localhost:9090/targets> — confirm all 4 jobs are UP.
- Try a query in <http://localhost:9090/graph>: `node_load1` for host metrics, `monad_bft_raptorcast_secondary_client_num_current_groups` for monad. If both return data, the dashboard's Prometheus datasource may be misconfigured.

**Disk fills up faster than expected.**
30-day retention with default scrape interval = ~1–2 GB. If higher, check `--storage.tsdb.retention.size=10GB` cap in `docker-compose.yml`.

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

- **Default (no `--public`)**: all ports bind to `127.0.0.1` only — nothing exposed to the internet. Access requires SSH tunnel.
- **`--public` mode**: Grafana `:3000` is bound on `0.0.0.0` and `:3000/tcp` is opened in UFW for anywhere. Grafana's `admin` login + 32-char generated password is the **only** auth layer. Plain HTTP — no TLS. Suitable for short review windows; for permanent public access put a TLS-terminating reverse proxy in front (see [Public access](#public-access-tls--auth)).
- **Grafana password** lives in `.env` (mode `0600`, root-only). Rotate with `sed -i s/.../.../ /opt/monad-grafana/.env && docker compose up -d`.
- **UFW rules** added by the installer scope access to the Docker bridge subnet only: `:8889` (otelcol), `:8080` (Monad RPC), `:9100` (node-exporter). Outside hosts cannot reach them.
- **RPC exporter** runs as `nobody` (uid 65534) with read-only filesystem mount and `pid: host` for `/proc` access. Reading `/proc/<pid>/comm` and `/proc/<pid>/stat` is world-readable so root isn't needed — drops the risk of accidentally reading the validator's `/proc/<bft-pid>/environ` if BLS keys leak there.
- **node-exporter** runs in `network_mode: host` + `pid: host` so it sees real NICs and `/proc`. Listens on `0.0.0.0:9100` (mandatory — `127.0.0.1` only would be unreachable from Prometheus via bridge-gateway), but UFW restricts `:9100` to the bridge subnet only, keeping it unreachable from the public internet.
- **Container logs** are bounded by `json-file` driver with `max-size: 10m`, `max-file: 3` per service — won't fill the disk.
- All four services have explicit `mem_limit` + `cpus` constraints (Prometheus 512m/1.0, Grafana 512m/0.5, exporter 64m/0.1, node-exporter 64m/0.1) so they can't starve the validator.

---

## Credits

- Built around the OpenTelemetry collector bundled with Monad's official node distribution.
- Host metrics via [`prometheus/node_exporter`](https://github.com/prometheus/node_exporter).
- Dashboard structure inspired by community Grafana dashboards for Cosmos / Solana validators.

## License

MIT — see [LICENSE](LICENSE).
