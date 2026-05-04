# Enable hostmetrics in otelcol

The default Monad install ships an OpenTelemetry collector at `/etc/otelcol-contrib/config.yaml` that **only forwards `monad_*` metrics from the node** (vote delay, consensus events, peers, txpool, etc.) but does **not** collect host-level metrics like CPU usage, memory, disk I/O, or filesystem usage.

Without `hostmetrics`, these panels in the dashboard will be empty:

- CPU usage % / Load average vs cores / CPU usage by state over time
- Memory donut / Memory + swap over time / Swap usage %
- Disk IO bytes / Disk operations / Disk pending queue
- Filesystem usage % / Free space
- Network errors / Network throughput

## What `hostmetrics` adds

A receiver in otelcol that scrapes Linux `/proc` and `/sys` every 10 seconds and produces:

- `system_cpu_*` (24 metrics — utilization by state, load average)
- `system_memory_*` (used/free/cached/buffered/etc.)
- `system_disk_*` (IO bytes/ops, pending, await)
- `system_filesystem_*` (used/free per mount)
- `system_network_*` (bytes/packets, errors, dropped)
- `system_paging_*` (swap usage, faults)

Total: ~24 series, ~50 KB extra memory in otelcol, negligible CPU.

## Automatic — via `install.sh --enable-hostmetrics`

If you used the auto-installer, it will detect the gap and offer to apply the overlay. To apply later:

```bash
sudo /opt/monad-grafana/install.sh --enable-hostmetrics
```

This:

1. Backs up `/etc/otelcol-contrib/config.yaml` to `config.yaml.bak.<timestamp>`
2. Uses Python+PyYAML (or fallback) to merge in `hostmetrics` receiver and pipeline reference
3. Restarts `otelcol-contrib.service`
4. Verifies `system_cpu_*` metrics appear at `http://127.0.0.1:8889/metrics`

## Manual — apply this overlay yourself

Edit `/etc/otelcol-contrib/config.yaml` (root only).

### 1. Add to `receivers:` block

```yaml
receivers:
  # ... existing receivers (otlp, etc.) ...

  hostmetrics:
    collection_interval: 10s
    scrapers:
      cpu:
        metrics:
          system.cpu.utilization:
            enabled: true
      memory:
        metrics:
          system.memory.utilization:
            enabled: true
      load:
      disk:
      filesystem:
        include_fs_types:
          fs_types: [ext4, xfs, btrfs, zfs]
          match_type: strict
        include_mount_points:
          mount_points: ['/', '/home', '/dev/triedb']
          match_type: strict
      network:
      paging:
```

Adjust `mount_points:` to match your filesystem layout (`df -hT`).

### 2. Reference `hostmetrics` in the metrics pipeline

In `service.pipelines.metrics.receivers`, append `hostmetrics`:

```yaml
service:
  pipelines:
    metrics:
      receivers: [otlp, hostmetrics]    # was: [otlp]
      processors: [batch]
      exporters: [prometheus]
```

### 3. Restart otelcol

```bash
sudo systemctl restart otelcol-contrib
sleep 5
sudo systemctl status otelcol-contrib --no-pager | head
```

### 4. Verify metrics arrive

```bash
curl -s http://127.0.0.1:8889/metrics | grep -c '^system_cpu_'
# Should print 1+ (e.g. 24)
```

After 30 seconds Prometheus will scrape and the dashboard System Resources panels will populate.

## Troubleshooting

**`otelcol-contrib` fails to start after edit:**

```bash
sudo journalctl -u otelcol-contrib --since '5 min ago' | tail -30
```

Common issues:
- YAML indentation broken — restore from backup `cp /etc/otelcol-contrib/config.yaml.bak.* /etc/otelcol-contrib/config.yaml`
- `mount_points` unmatched — remove paths that don't exist on your system
- `fs_types: strict` rejects your FS — change `match_type: strict` to `regexp` and use a regex

**`system_*` metrics still missing after restart:**

```bash
# Confirm receiver is loaded:
curl -s http://127.0.0.1:8888/metrics | grep otelcol_receiver_accepted_metric_points
# Should show non-zero for receiver=hostmetrics
```

If receiver is loaded but no `system_*` in `:8889`, your pipeline isn't routing them — re-check step 2.

## Why upstream Monad doesn't enable this by default

The bundled config at `/opt/monad/scripts/otel-config.yaml` keeps to the bare-minimum metrics needed by the node itself. Hostmetrics is opt-in because:

- Different operators want different scraper sets (e.g. add `processes` if running multiple binaries)
- Mount points vary (`/dev/triedb` is Monad-specific raw block)
- Some operators run separate `node_exporter` / `cadvisor` for host metrics

Our overlay is conservative: only the scrapers needed by the dashboard, with mount points pinned to common Monad layout.
