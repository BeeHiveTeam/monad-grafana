#!/usr/bin/env python3
"""
Idempotently add a `hostmetrics` receiver to /etc/otelcol-contrib/config.yaml
and reference it from the metrics pipeline.

Usage:
  sudo python3 apply_hostmetrics_overlay.py [/path/to/config.yaml]

Default path: /etc/otelcol-contrib/config.yaml
Behaviour:
  - Backs up to <config>.bak.<unix-ts> first
  - No-op if hostmetrics already in receivers
  - Adds 'hostmetrics' to service.pipelines.metrics.receivers if missing
  - Returns 0 on success/no-op, non-zero on error
Falls back to plain text manipulation if PyYAML is not installed.
"""
import os, sys, shutil, time

CONFIG = sys.argv[1] if len(sys.argv) > 1 else '/etc/otelcol-contrib/config.yaml'

HOSTMETRICS_BLOCK = """
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
"""


def main():
    if not os.path.isfile(CONFIG):
        print(f"ERROR: {CONFIG} not found", file=sys.stderr); sys.exit(1)
    if os.geteuid() != 0:
        print("ERROR: must run as root (sudo)", file=sys.stderr); sys.exit(1)

    text = open(CONFIG).read()

    if 'hostmetrics:' in text:
        print(f"hostmetrics already configured in {CONFIG} — no-op")
        # Ensure pipeline references it (idempotent path)
        if not _pipeline_has_hostmetrics(text):
            text = _add_to_metrics_pipeline(text)
            _write(CONFIG, text)
            print("Added 'hostmetrics' to metrics pipeline.")
        return

    # Backup
    backup = f"{CONFIG}.bak.{int(time.time())}"
    shutil.copy2(CONFIG, backup)
    print(f"Backed up {CONFIG} → {backup}")

    # Try PyYAML for safer edit; fall back to text insertion
    try:
        import yaml
        text = _yaml_edit(text, yaml)
    except ImportError:
        print("PyYAML not installed — falling back to text insertion (less robust).")
        text = _text_edit(text)

    _write(CONFIG, text)
    print(f"Wrote updated {CONFIG}.")
    print("Run 'sudo systemctl restart otelcol-contrib' to apply.")


def _yaml_edit(text, yaml):
    cfg = yaml.safe_load(text)
    if cfg is None:
        cfg = {}

    # Insert hostmetrics receiver
    receivers = cfg.setdefault('receivers', {})
    receivers['hostmetrics'] = yaml.safe_load(HOSTMETRICS_BLOCK)['hostmetrics']

    # Reference in metrics pipeline
    pipelines = cfg.setdefault('service', {}).setdefault('pipelines', {})
    metrics_pipeline = pipelines.setdefault('metrics', {'receivers': [], 'exporters': []})
    rcv_list = metrics_pipeline.setdefault('receivers', [])
    if 'hostmetrics' not in rcv_list:
        rcv_list.append('hostmetrics')

    return yaml.safe_dump(cfg, sort_keys=False, default_flow_style=False)


def _text_edit(text):
    """
    Naive text insertion when PyYAML isn't available.
    Inserts hostmetrics block after `receivers:` line, then patches metrics pipeline.
    """
    # 1. Insert hostmetrics block right after 'receivers:' line
    lines = text.splitlines(keepends=True)
    out = []
    inserted_block = False
    for i, ln in enumerate(lines):
        out.append(ln)
        if not inserted_block and ln.strip().startswith('receivers:'):
            out.append(HOSTMETRICS_BLOCK.rstrip() + '\n')
            inserted_block = True
    if not inserted_block:
        # No `receivers:` section — append one
        out.append('\nreceivers:\n')
        out.append(HOSTMETRICS_BLOCK.rstrip() + '\n')

    text2 = ''.join(out)
    return _add_to_metrics_pipeline(text2)


def _pipeline_has_hostmetrics(text):
    import re
    # Find the metrics pipeline receivers list
    m = re.search(
        r'service:\s*\n(?:.*\n)*?\s*pipelines:\s*\n(?:.*\n)*?\s*metrics:\s*\n(?:.*\n)*?\s*receivers:\s*\[([^\]]*)\]',
        text)
    return m and 'hostmetrics' in m.group(1)


def _add_to_metrics_pipeline(text):
    import re
    pat = re.compile(
        r'(service:\s*\n(?:.*\n)*?\s*pipelines:\s*\n(?:.*\n)*?\s*metrics:\s*\n(?:.*\n)*?\s*receivers:\s*\[)([^\]]*)(\])')
    m = pat.search(text)
    if m:
        existing = m.group(2).strip()
        if 'hostmetrics' in existing:
            return text
        new_list = (existing + ', hostmetrics') if existing else 'hostmetrics'
        return text[:m.start(2)] + new_list + text[m.end(2):]
    print("WARNING: couldn't find 'service.pipelines.metrics.receivers' — manual edit needed.", file=sys.stderr)
    return text


def _write(path, content):
    tmp = f"{path}.tmp.{os.getpid()}"
    with open(tmp, 'w') as f: f.write(content)
    os.chmod(tmp, 0o640)
    os.replace(tmp, path)


if __name__ == '__main__':
    main()
