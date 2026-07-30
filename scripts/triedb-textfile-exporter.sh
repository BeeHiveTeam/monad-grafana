#!/usr/bin/env bash
# Export TrieDB capacity/usage as Prometheus metrics via the node_exporter textfile collector.
#
# Why this exists: /dev/triedb is a RAW block device with no filesystem, so node_exporter's
# filesystem collector never sees it — `node_filesystem_*` covers only /, /boot and the tmpfs
# mounts. The node's primary data device could fill up completely and no alert could fire,
# because no metric described it. The only source of truth is `monad-mpt --storage`, which is a
# host binary and cannot be run from inside the exporter container.
#
# Install (see install.sh): drop this script on the host, point node-exporter at
#   --collector.textfile.directory=/host/var/lib/node_exporter/textfile
# and run it from a systemd timer every minute.
#
# Read-only by construction: `monad-mpt` is invoked exactly once, as
#   timeout -k 5 30 monad-mpt --storage "$TRIEDB_DEV"
# with no eval, no string-built command and every expansion quoted, so no destructive flag can
# be reached through TRIEDB_DEV or OUT_DIR. Verified by strace: the device is opened O_RDONLY
# only, with no flock and no writes.
set -u

TRIEDB_DEV="${TRIEDB_DEV:-/dev/triedb}"
OUT_DIR="${OUT_DIR:-/var/lib/node_exporter/textfile}"
OUT="${OUT_DIR}/monad_triedb.prom"
PROBE_TIMEOUT="${PROBE_TIMEOUT:-30}"

mkdir -p "$OUT_DIR" || exit 1
# NOTE the suffix: the temp name must NOT end in .prom, or the collector's *.prom glob would
# pick up a half-written file.
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

# "1.75 Tb" / "290.99 Gb" / "0.00 bytes" -> bytes. monad-mpt prints BINARY multiples under these
# labels (checked against blockdev --getsize64), and switches to a plain "bytes" unit for small
# values — a fresh database right after a hard reset prints "0.00 bytes", which the unit pattern
# must accept or the whole probe is reported as broken exactly while the disk grows fastest.
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

finish() {   # $1 = 0|1 probe_ok
  printf 'monad_triedb_probe_ok %s\n' "$1" >>"$TMP"
  # Refuse to publish a truncated file (ENOSPC on /): a file missing probe_ok would make the
  # "probe failing" rule silently unable to fire.
  if [[ ! -s "$TMP" ]] || ! grep -q '^monad_triedb_probe_ok ' "$TMP"; then
    rm -f "$TMP"; trap - EXIT; exit 1
  fi
  chmod 0644 "$TMP"    # node_exporter reads this from its container; mktemp gives 0600
  mv -f "$TMP" "$OUT"
  trap - EXIT
  exit 0
}

emit_header

if ! command -v monad-mpt >/dev/null 2>&1 || [[ ! -e "$TRIEDB_DEV" ]]; then
  # No device or no tool: publish probe_ok=0 and NOTHING else. Absence of the capacity series
  # is the honest signal — a zero would read as "empty disk".
  finish 0
fi

# stderr is kept (not sent to /dev/null): when monad-mpt aborts it prints a stacktrace, and
# throwing that away leaves nothing in the journal to diagnose with.
out=$(timeout -k 5 "$PROBE_TIMEOUT" monad-mpt --storage "$TRIEDB_DEV" 2>&1)
rc=$?
(( rc != 0 )) && printf '%s\n' "$out" >&2

# Capacity lines look like:
#        1.75 Tb      290.99 Gb 16.27%  "/dev/nvme1n1p1"
# The header says "MPT database on storageS" — there can be more than one. Iterate over all of
# them: taking only the first silently dropped a second device, so filling it to 100% would be
# invisible while the dashboard showed the first one comfortably green.
mapfile -t lines < <(grep -E '^[[:space:]]*[0-9.]+[[:space:]]+([KMGT]b|bytes)[[:space:]]+[0-9.]+[[:space:]]+([KMGT]b|bytes)[[:space:]]+[0-9.]+%' <<<"$out")

if (( rc != 0 )) || (( ${#lines[@]} == 0 )); then
  finish 0
fi

for line in "${lines[@]}"; do
  cap_v=$(awk '{print $1}' <<<"$line"); cap_u=$(awk '{print $2}' <<<"$line")
  use_v=$(awk '{print $3}' <<<"$line"); use_u=$(awk '{print $4}' <<<"$line")
  pct=$(awk '{print $5}' <<<"$line" | tr -d '%')
  dev=$(grep -oE '"/dev/[^"]+"' <<<"$line" | tr -d '"')
  dev="${dev:-$TRIEDB_DEV}"

  cap_b=$(to_bytes "$cap_v" "$cap_u")
  # monad-mpt rounds capacity to two decimals (1.75 Tb overstates a 1 920 382 009 344-byte
  # device by ~3.5 GiB). Prefer the exact size from the kernel when the path is a block device.
  if [[ -b "$dev" ]]; then
    exact=$(blockdev --getsize64 "$dev" 2>/dev/null || true)
    [[ "$exact" =~ ^[0-9]+$ ]] && cap_b="$exact"
  fi
  use_b=$(to_bytes "$use_v" "$use_u")
  ratio=$(awk -v p="$pct" 'BEGIN {printf "%.4f", p/100}')

  {
    printf 'monad_triedb_capacity_bytes{device="%s"} %s\n' "$dev" "$cap_b"
    printf 'monad_triedb_used_bytes{device="%s"} %s\n'     "$dev" "$use_b"
    printf 'monad_triedb_used_ratio{device="%s"} %s\n'     "$dev" "$ratio"
  } >>"$TMP"
done

finish 1
