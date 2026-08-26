#!/usr/bin/env python3
"""Derived consensus-health signals from a running Monad node.

Reads the node's raw Prometheus exposition (:9143 by default), computes health
signals an off-node observer cannot (see SIGNALS.md), and emits them as Prometheus
metrics, a JSON snapshot, or a severity exit code.

Stdlib only. Network and version are read from metric labels, never hard-coded, so
one binary serves {full-node, validator} x {testnet, mainnet}.
"""
from __future__ import annotations
import re
from typing import NamedTuple, Optional

# ── T1: metrics parser ────────────────────────────────────────────────────────
# One exposition line is `name{labels} value [timestamp]`. The node omits the
# timestamp; a collector may add it, so the third field is tolerated and ignored.
# Label values are quoted and may contain commas, so labels are split on the
# comma-between-pairs, not on every comma.

def _now():
    import time as _t
    return _t.time()


_LINE = re.compile(r'^(?P<name>[a-zA-Z_:][a-zA-Z0-9_:]*)(?:\{(?P<labels>.*)\})?\s+(?P<value>[^\s]+)(?:\s+[^\s]+)?\s*$')
_LABEL = re.compile(r'([a-zA-Z_][a-zA-Z0-9_]*)="((?:[^"\\]|\\.)*)"')


class Sample(NamedTuple):
    name: str
    labels: dict
    value: float


class Metrics:
    """Parsed exposition. Keeps every sample; lookups return the first match."""

    def __init__(self, samples: list, scraped_at: float = 0.0):
        self._samples = samples
        self.scraped_at = scraped_at
        self._by_name: dict = {}
        for s in samples:
            self._by_name.setdefault(s.name, []).append(s)

    def get(self, name: str) -> Optional[Sample]:
        got = self._by_name.get(name)
        return got[0] if got else None

    def value(self, name: str, default=None):
        """Counter/gauge value, or `default` if the metric is absent.

        Absent is distinct from zero on purpose: a missing series means the node
        never emitted it (wrong role, wrong version), which a caller resolves to
        `skip`, not to a healthy-looking 0.
        """
        s = self.get(name)
        return s.value if s is not None else default

    def has(self, name: str) -> bool:
        return name in self._by_name

    def identity(self) -> dict:
        """network / service_version / service_name, read from labels rather than
        assumed. Empty dict if no labelled monad_ sample exists."""
        for s in self._samples:
            if s.name.startswith("monad_") and s.labels:
                return {k: s.labels.get(k, "") for k in ("network", "service_version", "service_name")}
        return {}


def parse_exposition(text: str) -> Metrics:
    samples = []
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        m = _LINE.match(line)
        if not m:
            continue
        try:
            value = float(m.group("value"))
        except ValueError:
            continue  # malformed value token: skip, do not crash
        if value != value or value in (float("inf"), float("-inf")):
            continue  # NaN/Inf: float() accepts them, but they would poison every
                      # comparison downstream, so drop them here — an absent sample,
                      # not a silent value.
        labels = dict(_LABEL.findall(m.group("labels"))) if m.group("labels") else {}
        samples.append(Sample(m.group("name"), labels, value))
    return Metrics(samples, _now())


# ── T2: signal computer ───────────────────────────────────────────────────────
# Data-driven so the signal set is auditable against SIGNALS.md at a glance.
#   ratio    num/(num+den) over the window     rate     num/den over the window
#   gauge    latest single gauge               liveness Δmetric > 0 over the window
# `hi` thresholds: value >= warn -> warn, >= crit -> crit (higher is worse).

import os as _os
LIVENESS_MIN_WINDOW = float(_os.getenv("CH_LIVENESS_MIN_WINDOW", "10"))
C = "monad_state_consensus_events_"

SIGNALS = [
    dict(name="tc_round_ratio", kind="ratio", unit="ratio",
         num=C+"enter_new_round_tc", den=C+"enter_new_round_qc", warn=0.05, crit=0.15),
    dict(name="local_timeout_rate", kind="rate", unit="per_round",
         num=C+"local_timeout", den=C+"enter_new_round_qc", warn=0.05, crit=0.15),
    dict(name="execution_lagging_rate", kind="rate", unit="per_block",
         num=C+"rx_execution_lagging", den=C+"commit_block", warn=0.10, crit=0.30),
    dict(name="out_of_order_rate", kind="rate", unit="per_proposal",
         num=C+"out_of_order_proposals", den=C+"handle_proposal", warn=0.01, crit=0.05),
    dict(name="round_recovery_rate", kind="rate", unit="per_round",
         num=C+"handle_round_recovery", den=C+"enter_new_round_qc", warn=0.001, crit=0.01),
    dict(name="vote_delay_p99_ms", kind="gauge", unit="ms",
         metric="monad_state_vote_delay_ready_after_timer_start_p99_ms", warn=None, crit=None),
    dict(name="raptorcast_p99_ms", kind="gauge", unit="ms",
         metric="monad_bft_raptorcast_udp_primary_broadcast_latency_p99_ms",
         count="monad_bft_raptorcast_udp_primary_broadcast_latency_count", warn=None, crit=None),
    dict(name="block_liveness", kind="liveness", unit="bool",
         metric=C+"commit_block", warn=None, crit=None),
]
VALIDATION_PREFIX = "monad_state_validation_errors_"


class Signal(NamedTuple):
    name: str
    state: str          # ok | warn | crit | skip
    value: Optional[float]
    unit: str
    reason: Optional[str]


def _band(value, warn, crit) -> str:
    if crit is not None and value >= crit:
        return "crit"
    if warn is not None and value >= warn:
        return "warn"
    return "ok"


def _delta(prev: Metrics, cur: Metrics, name: str):
    """Counter delta over the window, or None if absent in either snapshot
    (absent != zero) or gone backwards (restart -> counter reset)."""
    a, b = prev.value(name), cur.value(name)
    if a is None or b is None:
        return None
    d = b - a
    return d if d >= 0 else None


def compute_signals(prev: Metrics, cur: Metrics) -> list:
    out = [_eval_signal(prev, cur, d) for d in SIGNALS]
    out.append(_eval_validation(prev, cur))
    return out


def _eval_signal(prev, cur, d) -> Signal:
    kind, name, unit = d["kind"], d["name"], d["unit"]
    if kind == "gauge":
        v = cur.value(d["metric"])
        if v is None:
            return Signal(name, "skip", None, unit, "metric-absent (role/version?)")
        cn = d.get("count")
        if cn is not None and (cur.value(cn) or 0) == 0:
            return Signal(name, "skip", None, unit, "no samples in window")
        return Signal(name, _band(v, d["warn"], d["crit"]), v, unit, None)
    if kind == "liveness":
        dv = _delta(prev, cur, d["metric"])
        if dv is None:
            return Signal(name, "skip", None, unit, "no delta (single scrape or reset)")
        if dv > 0:
            return Signal(name, "ok", 1.0, unit, None)
        # Zero blocks in the window is only "stalled" if the window was long enough
        # to have expected one. Otherwise it is an absence (window shorter than block
        # time), not a crit — the same trap as a zero percentile with no samples.
        elapsed = (cur.scraped_at or 0) - (prev.scraped_at or 0)
        if elapsed >= LIVENESS_MIN_WINDOW:
            return Signal(name, "crit", 0.0, unit, None)
        return Signal(name, "skip", None, unit, f"no block in {elapsed:.0f}s window (< {LIVENESS_MIN_WINDOW}s)")
    num = _delta(prev, cur, d["num"])
    den = _delta(prev, cur, d["den"])
    if num is None or den is None:
        return Signal(name, "skip", None, unit, "counter absent (role/version?)")
    denom = num + den if kind == "ratio" else den
    if denom <= 0:
        return Signal(name, "skip", None, unit, "no progress in window")
    return Signal(name, _band(num/denom, d["warn"], d["crit"]), num/denom, unit, None)


def _eval_validation(prev, cur) -> Signal:
    fam = [s.name for s in cur._samples if s.name.startswith(VALIDATION_PREFIX)]
    if not fam:
        return Signal("validation_error_rate", "skip", None, "per_block", "no validation series")
    total = 0.0
    for n in fam:
        dv = _delta(prev, cur, n)
        if dv is not None:
            total += dv
    commits = _delta(prev, cur, C+"commit_block")
    if not commits or commits <= 0:
        return Signal("validation_error_rate", "skip", None, "per_block", "no commits in window")
    return Signal("validation_error_rate", _band(total/commits, 0.001, 0.01), total/commits, "per_block", None)

# ── T3: output layer ──────────────────────────────────────────────────────────
_STATE_NUM = {"ok": 0, "warn": 1, "crit": 2, "skip": -1}


def severity(signals: list) -> int:
    """Worst measured state as a process exit code: 0 ok, 1 warn, 2 crit.
    `skip` is not a failure — it means not-measured — so it never raises severity."""
    worst = 0
    for s in signals:
        if s.state in ("warn", "crit"):
            worst = max(worst, _STATE_NUM[s.state])
    return worst


def render_prometheus(signals: list, identity: dict) -> str:
    net = identity.get("network", "")
    ver = identity.get("service_version", "")
    lbl = f'network="{net}",service_version="{ver}"'
    out = []
    out.append("# HELP monad_ch_up whether the health computation produced signals")
    out.append("# TYPE monad_ch_up gauge")
    out.append(f"monad_ch_up{{{lbl}}} 1")
    for s in signals:
        base = f'monad_ch_{s.name}'
        # state as a numeric series so a dashboard can alert on it; skip = -1
        out.append(f"# TYPE {base}_state gauge")
        out.append(f'{base}_state{{{lbl},state="{s.state}"}} {_STATE_NUM[s.state]}')
        if s.value is not None:
            out.append(f"# TYPE {base} gauge")
            out.append(f'{base}{{{lbl}}} {s.value}')
    return "\n".join(out) + "\n"


def render_json(signals: list, identity: dict) -> dict:
    return {
        "identity": identity,
        "severity": severity(signals),
        "signals": [dict(name=s.name, state=s.state, value=s.value,
                         unit=s.unit, reason=s.reason) for s in signals],
    }
