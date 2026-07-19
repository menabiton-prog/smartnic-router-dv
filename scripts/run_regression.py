#!/usr/bin/env python3
"""
Constrained-random regression for the 4x4 packet router (reference-model level).

For each random seed it builds random packet traffic on the four input ports,
runs it through the cycle-accurate model, and self-checks the output with a
scoreboard: every packet must arrive at the port named in its header, with its
flits intact and in order, and nothing may be lost or duplicated. It also
gathers functional coverage and prints a pass/fail report per seed.

This is the "automation" layer of the project: one command runs the whole
regression across many seeds and returns a non-zero exit code on any failure,
which is how a CI job would gate a merge.

    python scripts/run_regression.py --seeds 25 --packets 40
"""

import argparse
import random
import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "model"))
from router_model import RouterModel, Flit, make_header, hdr_dest, hdr_pid, N_PORTS


def build_packet(pid, src, dest, length, rng):
    flits = [make_header(dest, length, pid)]
    for k in range(1, length):
        flits.append(((pid & 0xFFFF) << 16) | (k & 0xFFFF))   # traceable payload
    beats = [Flit(d, last=(k == length - 1)) for k, d in enumerate(flits)]
    return {"pid": pid, "src": src, "dest": dest, "flits": tuple(flits), "beats": beats}


def gen_traffic(rng, n_packets):
    packets, pid = [], 0
    for src in range(N_PORTS):
        for _ in range(n_packets):
            dest = rng.randrange(N_PORTS)
            length = rng.randint(1, 8)          # 1..8 flits, header included
            packets.append(build_packet(pid, src, dest, length, rng))
            pid += 1
    return packets


def run_one(seed, n_packets, in_depth=8, out_depth=16, max_cycles=200000):
    rng = random.Random(seed)
    dut = RouterModel(N_PORTS, out_depth=out_depth)
    packets = gen_traffic(rng, n_packets)

    # per-input injection queues (packet flits concatenated, order preserved)
    pending = [list() for _ in range(N_PORTS)]
    for p in sorted(packets, key=lambda p: p["pid"]):
        pending[p["src"]].extend(p["beats"])
    pending = [iter_deque(q) for q in pending]

    # expected: multiset of packets per destination + per-source order
    expected = {o: [] for o in range(N_PORTS)}
    for p in packets:
        expected[p["dest"]].append(p)

    total = len(packets)
    got_packets = {o: [] for o in range(N_PORTS)}
    recon = [[] for _ in range(N_PORTS)]         # partial flits per output
    received = 0

    cov = {"dest": set(), "src_dest": set(), "len": set(),
           "contention": False, "out_full": False, "deep_out": False}

    cyc = 0
    while cyc < max_cycles:
        cyc += 1
        # inject
        for port in range(N_PORTS):
            if pending[port].peek() is not None and dut.in_ready(port, in_depth) \
                    and rng.random() < 0.6:
                dut.push(port, pending[port].pop())
        # advance one clock
        dut.step()
        # drain outputs (randomised back-pressure)
        for o in range(N_PORTS):
            if rng.random() < 0.5:
                f = dut.pop(o)
                if f is not None:
                    recon[o].append(f.data)
                    if f.last:
                        pkt = tuple(recon[o]); recon[o] = []
                        got_packets[o].append(pkt)
                        received += 1
        if received == total and all(p.peek() is None for p in pending) and dut.idle():
            break

    cov["contention"] = dut.ev_contention > 0
    cov["out_full"] = dut.ev_out_full > 0
    cov["deep_out"] = dut.max_out_occ >= out_depth // 2

    # ---------------- scoreboard ----------------
    errors = []
    if received != total:
        errors.append(f"lost packets: received {received}/{total}")

    for o in range(N_PORTS):
        exp = expected[o]
        got = got_packets[o]
        exp_ms = sorted(p["flits"] for p in exp)
        got_ms = sorted(got)
        if exp_ms != got_ms:
            errors.append(f"output {o}: packet set mismatch "
                          f"(exp {len(exp)}, got {len(got)})")
        # per-source order must be preserved
        for src in range(N_PORTS):
            exp_seq = [p["pid"] for p in exp if p["src"] == src]
            got_seq = [hdr_pid(g[0]) for g in got
                       if any(p["src"] == src and p["flits"] == g for p in exp)]
            if exp_seq != got_seq:
                errors.append(f"output {o}: source {src} order not preserved")

    for p in packets:
        cov["dest"].add(p["dest"])
        cov["src_dest"].add((p["src"], p["dest"]))
        cov["len"].add(len(p["flits"]))

    cov_pct = coverage_percent(cov)
    return (len(errors) == 0), errors, cov, cov_pct, cyc


class iter_deque:
    """Tiny peekable queue."""
    def __init__(self, items):
        self._i = list(items); self._p = 0
    def peek(self):
        return self._i[self._p] if self._p < len(self._i) else None
    def pop(self):
        x = self._i[self._p]; self._p += 1; return x


def coverage_percent(cov):
    bins = 0; hit = 0
    bins += N_PORTS;            hit += len(cov["dest"])            # every dest reached
    bins += N_PORTS * N_PORTS;  hit += len(cov["src_dest"])        # every src->dest pair
    bins += 8;                 hit += len(cov["len"])              # every length 1..8
    for k in ("contention", "out_full", "deep_out"):
        bins += 1; hit += 1 if cov[k] else 0
    return 100.0 * hit / bins


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seeds", type=int, default=25)
    ap.add_argument("--packets", type=int, default=40, help="packets per input port")
    ap.add_argument("--base-seed", type=int, default=1000)
    args = ap.parse_args()

    print(f"Router regression: {args.seeds} seeds x "
          f"{args.packets * N_PORTS} packets each\n")
    print(f"{'seed':>6} {'result':>8} {'cycles':>8} {'cov%':>7}  notes")
    print("-" * 60)

    agg = {"dest": set(), "src_dest": set(), "len": set(),
           "contention": False, "out_full": False, "deep_out": False}
    failures = 0
    for s in range(args.base_seed, args.base_seed + args.seeds):
        ok, errs, cov, pct, cyc = run_one(s, args.packets)
        for k in ("dest", "src_dest", "len"):
            agg[k] |= cov[k]
        for k in ("contention", "out_full", "deep_out"):
            agg[k] = agg[k] or cov[k]
        note = "" if ok else errs[0]
        print(f"{s:>6} {'PASS' if ok else 'FAIL':>8} {cyc:>8} {pct:>6.1f}  {note}")
        if not ok:
            failures += 1

    print("-" * 60)
    print(f"Aggregate functional coverage: {coverage_percent(agg):.1f} %")
    print(f"  destinations reached : {len(agg['dest'])}/{N_PORTS}")
    print(f"  source->dest pairs   : {len(agg['src_dest'])}/{N_PORTS*N_PORTS}")
    print(f"  packet lengths        : {len(agg['len'])}/8")
    print(f"  contention seen       : {agg['contention']}")
    print(f"  output FIFO full seen : {agg['out_full']}")
    print(f"\n{args.seeds - failures}/{args.seeds} seeds passed.")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
