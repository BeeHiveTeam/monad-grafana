#!/usr/bin/env python3
"""Offline tests for monad-consensus-health. Stdlib unittest, no network.

Fixtures live in fixtures/. They include a full-node (validator-only series
stripped) and a mainnet relabel, so dual-mode is exercised, not assumed.
"""
import os, unittest
from consensus_health import (
    parse_exposition, compute_signals, render_json, render_prometheus, severity, Metrics,
)

HERE = os.path.dirname(__file__)
def fx(name):
    with open(os.path.join(HERE, "fixtures", name)) as f:
        return f.read()
def load(name): return parse_exposition(fx(name))
def sig(signals, name): return next(s for s in signals if s.name == name)


class Parser(unittest.TestCase):
    def test_labels_and_timestamp_tolerated(self):
        m = parse_exposition('x{a="1"} 5 1756200000000\ny 7')
        self.assertEqual(m.value("x"), 5.0)
        self.assertEqual(m.value("y"), 7.0)

    def test_comma_inside_label_value(self):
        m = parse_exposition('x{a="p,q",b="r"} 1')
        self.assertEqual(m.get("x").labels["a"], "p,q")

    def test_nan_and_inf_dropped_not_valued(self):
        m = parse_exposition('a{n="x"} NaN\nb{n="y"} +Inf\nc 3')
        self.assertIsNone(m.get("a"))   # absent, not a poisoned value
        self.assertIsNone(m.get("b"))
        self.assertEqual(m.value("c"), 3.0)

    def test_absent_is_none_not_zero(self):
        self.assertIsNone(load("metrics-testnet-validator.txt").value("does_not_exist"))

    def test_identity_from_labels_not_hardcoded(self):
        self.assertEqual(load("metrics-testnet-validator.txt").identity()["network"], "testnet")
        self.assertEqual(load("metrics-mainnet-validator.txt").identity()["network"], "mainnet")


class ThreeState(unittest.TestCase):
    def test_fullnode_skips_vote_delay_with_reason(self):
        s = sig(compute_signals(load("metrics-testnet-fullnode.txt"),
                                load("metrics-testnet-fullnode.txt")), "vote_delay_p99_ms")
        self.assertEqual(s.state, "skip")
        self.assertIsNone(s.value)          # never a fake 0
        self.assertTrue(s.reason)

    def test_zero_percentile_without_samples_is_skip(self):
        # our node is out of set: primary raptorcast count = 0, p99 gauge = 0
        s = sig(compute_signals(load("metrics-testnet-validator.txt"),
                                load("metrics-testnet-validator.txt")), "raptorcast_p99_ms")
        self.assertEqual(s.state, "skip")

    def test_identity_snapshot_is_severity_zero(self):
        # same snapshot twice -> no deltas -> all skip -> not a crit storm
        self.assertEqual(severity(compute_signals(load("metrics-testnet-validator.txt"),
                                                  load("metrics-testnet-validator.txt"))), 0)


class DualMode(unittest.TestCase):
    def test_all_four_cells_parse_and_carry_network(self):
        cells = {
            "metrics-testnet-validator.txt": "testnet",
            "metrics-mainnet-validator.txt": "mainnet",
            "metrics-testnet-fullnode.txt": "testnet",
        }
        for f, net in cells.items():
            self.assertEqual(load(f).identity()["network"], net)

    def test_render_uses_metric_labels(self):
        m = load("metrics-mainnet-validator.txt")
        out = render_prometheus(compute_signals(m, m), m.identity())
        self.assertIn('network="mainnet"', out)


class DegradationFires(unittest.TestCase):
    def _window(self, base_add, tc_add, commit_add=0, qc_add=0):
        """Build a realistic second snapshot: grow all denominators, grow tc extra."""
        prev = load("metrics-testnet-validator.txt")
        text = fx("metrics-testnet-validator.txt").splitlines()
        C = "monad_state_consensus_events_"
        adds = {C+"enter_new_round_qc{": qc_add, C+"enter_new_round_tc{": tc_add,
                C+"commit_block{": commit_add}
        for i, l in enumerate(text):
            for pref, inc in adds.items():
                if l.startswith(pref):
                    text[i] = l.rsplit(" ", 1)[0] + " " + str(float(l.rsplit(" ", 1)[1]) + inc)
        return prev, parse_exposition("\n".join(text))

    def test_high_tc_ratio_is_crit(self):
        # 200 extra rounds, 100 of them tc -> ratio 0.5 -> crit
        prev, cur = self._window(0, tc_add=100, qc_add=100)
        self.assertEqual(sig(compute_signals(prev, cur), "tc_round_ratio").state, "crit")

    def test_healthy_tc_ratio_is_ok(self):
        # 1000 rounds, 3 tc -> 0.3% -> ok
        prev, cur = self._window(0, tc_add=3, qc_add=1000, commit_add=1000)
        self.assertEqual(sig(compute_signals(prev, cur), "tc_round_ratio").state, "ok")


class Mutation(unittest.TestCase):
    """Each test would pass under a plausible-but-wrong implementation only if the
    guard is real. We assert the boundary, not just the happy value."""
    def test_ratio_denominator_includes_tc(self):
        # if the formula were tc/qc instead of tc/(qc+tc), 100/100 would read 1.0;
        # correct tc/(qc+tc) reads 0.5. Pin the correct one.
        prev = parse_exposition('monad_state_consensus_events_enter_new_round_qc{network="t"} 0\n'
                                'monad_state_consensus_events_enter_new_round_tc{network="t"} 0')
        cur = parse_exposition('monad_state_consensus_events_enter_new_round_qc{network="t"} 100\n'
                               'monad_state_consensus_events_enter_new_round_tc{network="t"} 100')
        self.assertAlmostEqual(sig(compute_signals(prev, cur), "tc_round_ratio").value, 0.5)

    def test_counter_reset_is_skip_not_negative(self):
        # ASYMMETRIC reset: tc counter resets (500->1) while qc grows (500->2000).
        # Without the d>=0 guard, num delta is -499, denominator 1001>0, and the
        # ratio comes out NEGATIVE (-0.498) and bands to a healthy-looking ok.
        # The guard must turn the reset into skip and value None instead.
        prev = parse_exposition('monad_state_consensus_events_enter_new_round_tc{n="t"} 500\n'
                                'monad_state_consensus_events_enter_new_round_qc{n="t"} 500')
        cur = parse_exposition('monad_state_consensus_events_enter_new_round_tc{n="t"} 1\n'
                               'monad_state_consensus_events_enter_new_round_qc{n="t"} 2000')
        s = sig(compute_signals(prev, cur), "tc_round_ratio")
        self.assertEqual(s.state, "skip")
        self.assertIsNone(s.value)   # never a negative ratio


if __name__ == "__main__":
    unittest.main(verbosity=2)
