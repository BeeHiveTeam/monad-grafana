#!/usr/bin/env bash
# Export TrieDB capacity/usage as Prometheus metrics via the node_exporter textfile collector.
#
# Why this exists: /dev/triedb is a RAW block device with no filesystem, so node_exporter's
# filesystem collector never sees it — `node_filesystem_*` covers only /, /boot and the tmpfs
# mounts. The node's primary data device could fill up completely and no alert could fire,
# because no metric described it. The only source of truth is `monad-mpt --storage`, which is a
# host binary and cannot be run from inside the exporter container.
#
# Install (see install.sh / docs): drop this script on the host, point node-exporter at
#   --collector.textfile.directory=/host/var/lib/node_exporter/textfile
# and run it from a systemd timer every minute.
#
# Read-only: only ever invokes `monad-mpt --storage <dev>` without mutating flags.
set -u

TRIEDB_DEV="${TRIEDB_DEV:-/dev/triedb}"
OUT_DIR="${OUT_DIR:-/var/lib/node_exporter/textfile}"
OUT="${OUT_DIR}/monad_triedb.prom"

mkdir -p "$OUT_DIR"
TMP=$(mktemp "${OUT}.XXXXXX") || exit 1
trap 'rm -f "$TMP"' EXIT

emit_header() {
  cat >>"$TMP" <<'EOF'
# HELP monad_triedb_capacity_bytes Total capacity of the TrieDB storage device
# TYPE monad_triedb_capacity_bytes gauge
# HELP monad_triedb_used_bytes Bytes used inside the TrieDB storage device
# TYPE monad_triedb_used_bytes gauge
# HELP monad_triedb_used_ratio Fraction of the TrieDB device in use (0..1)
# TYPE monad_triedb_used_ratio gauge
# HELP monad_triedb_probe_ok 1 if monad-mpt could be read this cycle, 0 otherwise
# TYPE monad_triedb_probe_ok gauge
EOF
}

# "1.75 Tb" / "290.99 Gb" / "512.00 Mb" -> bytes. monad-mpt prints binary multiples with these
# labels, so scale by 1024 (checked against the device's real size).
to_bytes() {
  awk -v v="$1" -v u="$2" 'BEGIN {
    m = 1
    if (u ~ /^[Kk]/) m = 1024
    else if (u ~ /^[Mm]/) m = 1024*1024
    else if (u ~ /^[Gg]/) m = 1024*1024*1024
    else if (u ~ /^[Tt]/) m = 1024*1024*1024*1024
    printf "%.0f", v * m
  }'
}

emit_header

if ! command -v monad-mpt >/dev/null 2>&1 || [[ ! -e "$TRIEDB_DEV" ]]; then
  # No device or no tool: publish probe_ok=0 and NOTHING else. Absence of the capacity series
  # is the honest signal — a zero would read as "empty disk".
  printf 'monad_triedb_probe_ok 0\n' >>"$TMP"
  chmod 0644 "$TMP"; mv -f "$TMP" "$OUT"; trap - EXIT; exit 0
fi

out=$(timeout 30 monad-mpt --storage "$TRIEDB_DEV" 2>/dev/null)
rc=$?

# The capacity line looks like:
#        1.75 Tb      290.99 Gb 16.27%  "/dev/nvme1n1p1"
line=$(grep -E '^[[:space:]]*[0-9.]+[[:space:]]+[KMGT]b[[:space:]]+[0-9.]+[[:space:]]+[KMGT]b[[:space:]]+[0-9.]+%' <<<"$out" | head -1)

if (( rc != 0 )) || [[ -z "$line" ]]; then
  printf 'monad_triedb_probe_ok 0\n' >>"$TMP"
  chmod 0644 "$TMP"; mv -f "$TMP" "$OUT"; trap - EXIT; exit 0
fi

cap_v=$(awk '{print $1}' <<<"$line"); cap_u=$(awk '{print $2}' <<<"$line")
use_v=$(awk '{print $3}' <<<"$line"); use_u=$(awk '{print $4}' <<<"$line")
pct=$(awk '{print $5}' <<<"$line" | tr -d '%')
dev=$(grep -oE '"/dev/[^"]+"' <<<"$line" | tr -d '"')

cap_b=$(to_bytes "$cap_v" "$cap_u")
use_b=$(to_bytes "$use_v" "$use_u")
ratio=$(awk -v p="$pct" 'BEGIN {printf "%.4f", p/100}')

{
  printf 'monad_triedb_capacity_bytes{device="%s"} %s\n' "${dev:-$TRIEDB_DEV}" "$cap_b"
  printf 'monad_triedb_used_bytes{device="%s"} %s\n'     "${dev:-$TRIEDB_DEV}" "$use_b"
  printf 'monad_triedb_used_ratio{device="%s"} %s\n'     "${dev:-$TRIEDB_DEV}" "$ratio"
  printf 'monad_triedb_probe_ok 1\n'
} >>"$TMP"

chmod 0644 "$TMP"   # node_exporter reads this from inside its container; mktemp gives 0600
mv -f "$TMP" "$OUT"
trap - EXIT
