# Consensus health signals — specification (source of truth)

Every signal is a **derived** quantity: the node exports cumulative counters and
instantaneous gauges; health is the movement and the ratios between them, which an
off-node observer cannot compute because the counters only exist inside a running client.

Each signal resolves to exactly one of three states — never a silent zero:

- `ok`     — measured, value present
- `warn` / `crit` — measured, value crossed a threshold
- `skip`   — could not be measured (metric absent, no delta yet, node out of set).
             A `skip` is reported with a reason and NEVER rendered as `0`.

Rates are computed over a rolling window from two scrapes (counters are cumulative).
Network and client version are read from the metric labels, never hard-coded, so the
same tool serves {full-node, validator} × {testnet, mainnet}.

| signal | formula (over window) | unit | source metric(s) | why it is health |
|---|---|---|---|---|
| `tc_round_ratio` | Δtc / (Δqc + Δtc) | ratio | enter_new_round_tc, enter_new_round_qc | rounds closed by timeout-certificate instead of quorum; the primary liveness-stress signal |
| `local_timeout_rate` | Δlocal_timeout / Δrounds | per round | local_timeout | how often THIS node times out a round locally |
| `execution_lagging_rate` | Δrx_execution_lagging / Δcommit | per block | rx_execution_lagging | execution falling behind consensus (deferred-exec gap widening) |
| `out_of_order_rate` | Δout_of_order_proposals / Δproposals | per proposal | out_of_order_proposals, handle_proposal | proposal delivery disorder |
| `round_recovery_rate` | Δhandle_round_recovery / Δrounds | per round | handle_round_recovery | rounds needing recovery — nonzero is a stress sign |
| `validation_error_rate` | Σ Δvalidation_errors_* / Δcommit | per block | 14× validation_errors_* | malformed/invalid consensus messages seen |
| `vote_delay_p99_ms` | gauge, trend vs baseline | ms | vote_delay_ready_after_timer_start_p99_ms | tail of vote readiness; region-sensitive |
| `raptorcast_p99_ms` | gauge | ms | raptorcast_udp_*_broadcast_latency_p99_ms | block dissemination tail latency |
| `block_liveness` | Δcommit_block > 0 over window | bool | commit_block | node is actually finalizing, not merely up (flag ≠ health) |

## Out-of-set behaviour (critical)

A registered-but-inactive validator (self_stake_bps = 0) and a plain full-node do NOT
produce the same counters a voting validator does. Signals that depend on participation
(`created_vote`, own timeouts under load) may read structurally low or zero. These MUST
resolve to `skip` with reason `node-not-in-active-set`, not to a healthy-looking `0`.
`created_vote` in particular is a known false friend and is deliberately NOT a signal.

## Thresholds

Ship with conservative defaults, overridable by env. Calibrate the real bands only
against in-active-set data — until then thresholds are advisory and every band is
documented as provisional. No threshold silently caps or drops a signal.

## Non-goals

- Not a general node monitor (disk, CPU, sync age already covered elsewhere).
- Not stake/geography analytics — that is observable off-node and already offered by others.
- Does not require Prometheus; a TSDB consumes the output but the tool stands alone.
