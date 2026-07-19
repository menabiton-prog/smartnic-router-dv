"""
Cycle-accurate reference model of the 4x4 packet router.

The RTL in rtl/packet_router.sv follows exactly this behaviour, so this model
is used both as the golden reference for the scoreboard and as a fast way to
regress the routing/arbitration logic in Python (see scripts/run_regression.py).

Packet format (one 32-bit flit per beat):
    header flit : bits [1:0]   = destination port (0..3)
                  bits [15:2]  = packet length in flits (header included)
                  bits [31:16] = packet id
    payload     : arbitrary data flits
    the final flit of a packet carries TLAST.

Routing rules:
    * A packet is forwarded whole to the output port named in its header.
    * Per output port a round-robin arbiter picks one input at a time; the
      grant is held until the granted packet's TLAST, so packets never
      interleave on an output (packet-contiguous).
    * Nothing is dropped: input and output FIFOs apply back-pressure.
"""

from collections import deque

N_PORTS = 4
DATA_W = 32


def make_header(dest, length, pid):
    return (dest & 0x3) | ((length & 0x3FFF) << 2) | ((pid & 0xFFFF) << 16)


def hdr_dest(flit):
    return flit & 0x3


def hdr_len(flit):
    return (flit >> 2) & 0x3FFF


def hdr_pid(flit):
    return (flit >> 16) & 0xFFFF


class Flit:
    __slots__ = ("data", "last")

    def __init__(self, data, last):
        self.data = data & ((1 << DATA_W) - 1)
        self.last = bool(last)


class RouterModel:
    """One combinational grant phase + one transfer phase per step()."""

    def __init__(self, n=N_PORTS, out_depth=16):
        self.n = n
        self.out_depth = out_depth
        self.in_fifo = [deque() for _ in range(n)]     # Flit
        self.out_fifo = [deque() for _ in range(n)]    # Flit
        self.grant = [None] * n                        # per output: granted input
        self.active = [None] * n                       # per input: output it feeds
        self.rr = [0] * n                              # round-robin pointer per output
        # observability for coverage
        self.ev_contention = 0
        self.ev_out_full = 0
        self.max_out_occ = 0

    # ---- input side (driven by the testbench) ----
    def in_ready(self, port, in_depth):
        return len(self.in_fifo[port]) < in_depth

    def push(self, port, flit):
        self.in_fifo[port].append(flit)

    # ---- output side (drained by the testbench sink) ----
    def pop(self, port):
        return self.out_fifo[port].popleft() if self.out_fifo[port] else None

    def _hol_is_header(self, i):
        # An input's head flit is a header exactly when it is not mid-packet.
        return self.active[i] is None and len(self.in_fifo[i]) > 0

    def step(self):
        # ---- grant phase (round-robin per output) ----
        for o in range(self.n):
            if self.grant[o] is not None:
                continue
            requesters = [i for i in range(self.n)
                          if self._hol_is_header(i) and hdr_dest(self.in_fifo[i][0].data) == o]
            if len(requesters) >= 2:
                self.ev_contention += 1
            if requesters:
                # pick the first requester at or after the round-robin pointer
                start = self.rr[o]
                pick = min(requesters, key=lambda i: (i - start) % self.n)
                self.grant[o] = pick
                self.active[pick] = o
                self.rr[o] = (pick + 1) % self.n

        # ---- transfer phase ----
        for o in range(self.n):
            i = self.grant[o]
            if i is None:
                continue
            if not self.in_fifo[i]:
                continue
            if len(self.out_fifo[o]) >= self.out_depth:
                self.ev_out_full += 1
                continue
            flit = self.in_fifo[i].popleft()
            self.out_fifo[o].append(flit)
            if flit.last:
                self.grant[o] = None
                self.active[i] = None

        self.max_out_occ = max(self.max_out_occ,
                               max((len(f) for f in self.out_fifo), default=0))

    def idle(self):
        return (all(len(f) == 0 for f in self.in_fifo)
                and all(len(f) == 0 for f in self.out_fifo)
                and all(g is None for g in self.grant))
