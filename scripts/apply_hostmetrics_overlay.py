#!/usr/bin/env python3
"""
Idempotently add a `hostmetrics` receiver to an OTel collector config and
reference it from the metrics pipeline. Works with both plain `otelcol`
(/etc/otelcol/config.yaml) and `otelcol-contrib` (/etc/otelcol-contrib/config.yaml).

Usage:
  sudo python3 apply_hostmetrics_overlay.py [/path/to/config.yaml]

When no path is given, picks /etc/otelcol-contrib/config.yaml if it exists,
otherwise /etc/otelcol/config.yaml.

Behaviour:
  - Backs up to <config>.bak.<unix-ts> first
  - No-op if hostmetrics already in receivers
  - Adds 'hostmetrics' to service.pipelines.metrics.receivers if missing
  - Returns 0 on success/no-op, non-zero on error
Falls back to plain text manipulation if PyYAML is not installed.
"""
import os, sys, shutil, time

def _default_config():
    for path in ('/etc/otelcol-contrib/config.yaml', '/etc/otelcol/config.yaml'):
        if os.path.isfile(path):
            return path
    return '/etc/otelcol-contrib/config.yaml'  # let downstream fail with clear msg

CONFIG = sys.argv[1] if len(sys.argv) > 1 else _default_config()

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

    # Prefer comment-preserving text insertion. PyYAML's safe_dump rewrites the
    # WHOLE file and strips every comment — destructive for a hand-maintained
    # otelcol config (VDP push creds, operator notes). Only fall back to PyYAML
    # if the text editor couldn't place the receiver (unusual layout).
    edited = _text_edit(text)
    if 'hostmetrics:' in edited and _pipeline_has_hostmetrics(edited):
        text = edited
    else:
        try:
            import yaml
            print("Text insertion couldn't place hostmetrics — using PyYAML "
                  "(NOTE: comments in the config are not preserved).")
            text = _yaml_edit(text, yaml)
        except ImportError:
            print("PyYAML unavailable and text insertion incomplete — wrote a "
                  "best-effort text edit; verify hostmetrics is in the metrics pipeline.")
            text = edited

    _write(CONFIG, text)
    print(f"Wrote updated {CONFIG}.")
    # Hint matches the config path the operator actually pointed us at.
    svc = 'otelcol-contrib' if 'otelcol-contrib' in CONFIG else 'otelcol'
    print(f"Run 'sudo systemctl restart {svc}' to apply.")


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
    # Inline flow list: receivers: [a, b]
    m = re.search(
        r'service:\s*\n(?:.*\n)*?\s*pipelines:\s*\n(?:.*\n)*?\s*metrics:\s*\n(?:.*\n)*?\s*receivers:\s*\[([^\]]*)\]',
        text)
    if m:
        return 'hostmetrics' in m.group(1)
    # Block list: receivers:\n  - a\n  - b
    bm = re.search(
        r'service:\s*\n(?:.*\n)*?\s*pipelines:\s*\n(?:.*\n)*?\s*metrics:\s*\n(?:.*\n)*?^\s*receivers:[ \t]*\n'
        r'((?:[ \t]*-[ \t]*\S+[ \t]*\n)+)',
        text, re.MULTILINE)
    return bool(bm and 'hostmetrics' in bm.group(1))


def _add_to_metrics_pipeline(text):
    import re
    # Style 1 — inline flow list:  receivers: [otlp, prometheus]
    pat = re.compile(
        r'(service:\s*\n(?:.*\n)*?\s*pipelines:\s*\n(?:.*\n)*?\s*metrics:\s*\n(?:.*\n)*?\s*receivers:\s*\[)([^\]]*)(\])')
    m = pat.search(text)
    if m:
        existing = m.group(2).strip()
        if 'hostmetrics' in existing:
            return text
        new_list = (existing + ', hostmetrics') if existing else 'hostmetrics'
        return text[:m.start(2)] + new_list + text[m.end(2):]

    # Style 2 — block list:
    #   metrics:
    #     receivers:
    #       - otlp
    #       - prometheus
    block_pat = re.compile(
        r'service:\s*\n(?:.*\n)*?\s*pipelines:\s*\n(?:.*\n)*?\s*metrics:\s*\n(?:.*\n)*?^(\s*)receivers:[ \t]*\n'
        r'((?:[ \t]*-[ \t]*\S+[ \t]*\n)+)',
        re.MULTILINE)
    bm = block_pat.search(text)
    if bm:
        listblock = bm.group(2)
        if 'hostmetrics' in listblock:
            return text
        im = re.match(r'([ \t]*)-', listblock)
        item_indent = im.group(1) if im else (bm.group(1) + '  ')
        insert_at = bm.start(2)   # start of the first '- item' line
        return text[:insert_at] + f"{item_indent}- hostmetrics\n" + text[insert_at:]

    print("WARNING: couldn't find 'service.pipelines.metrics.receivers' (inline or block) — manual edit needed.", file=sys.stderr)
    return text


def _write(path, content):
    # Preserve the original file's mode + ownership so the service user
    # (otelcol / otelcol-contrib / nobody) can still read it after the
    # atomic replace. Previously we hardcoded mode 0640 which on a fresh
    # `apt install otelcol` (where the package ships /etc/otelcol/config.yaml
    # mode 0644, root:root) silently dropped world-read and made the file
    # unreadable to the service user — otelcol then exited with "permission
    # denied" on the next restart, leaving the operator with a dead VDP
    # push and no host metrics.
    try:
        st = os.stat(path)
        mode = st.st_mode & 0o777
        uid, gid = st.st_uid, st.st_gid
    except FileNotFoundError:
        mode, uid, gid = 0o644, 0, 0

    tmp = f"{path}.tmp.{os.getpid()}"
    with open(tmp, 'w') as f: f.write(content)
    os.chmod(tmp, mode)
    try:
        os.chown(tmp, uid, gid)
    except PermissionError:
        # Not running as root — leave whatever owner we ended up with.
        pass
    os.replace(tmp, path)


if __name__ == '__main__':
    main()
