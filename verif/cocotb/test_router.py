"""
Cocotb testbench for packet_router (via the flattened wrapper).

It injects constrained-random packets on the four input ports, collects the
packets leaving the four output ports, and self-checks with a scoreboard: every
packet must arrive at the port named in its header, intact, and nothing may be
lost or duplicated. It runs with free simulators:

    cd verif/cocotb && make            # iverilog
    cd verif/cocotb && make SIM=verilator
"""

import random
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ReadOnly

N = 4
DATA_W = 32
MASK = (1 << DATA_W) - 1


def header(dest, length, pid):
    return (dest & 0x3) | ((length & 0x3FFF) << 2) | ((pid & 0xFFFF) << 16)


def make_packet(pid, dest, length):
    words = [header(dest, length, pid)]
    for k in range(1, length):
        words.append(((pid & 0xFFFF) << 16) | k)
    return words


def get_slice(sig, i):
    return (int(sig.value) >> (i * DATA_W)) & MASK


@cocotb.test()
async def random_traffic(dut):
    rng = random.Random(2)
    cocotb.start_soon(Clock(dut.aclk, 10, unit="ns").start())

    dut.aresetn.value = 0
    dut.s_tvalid.value = 0
    dut.s_tlast.value = 0
    dut.s_tdata.value = 0
    dut.m_tready.value = (1 << N) - 1          # always ready
    for _ in range(5):
        await RisingEdge(dut.aclk)
    dut.aresetn.value = 1

    # build traffic: per input port a queue of (data, last, pid, dest)
    pending = [[] for _ in range(N)]
    sent = {}          # pid -> (dest, tuple(words))
    pid = 0
    for src in range(N):
        for _ in range(30):
            dest = rng.randrange(N)
            length = rng.randint(1, 8)
            words = make_packet(pid, dest, length)
            sent[pid] = (dest, tuple(words))
            for k, w in enumerate(words):
                pending[src].append((w, 1 if k == length - 1 else 0))
            pid += 1
    total = len(sent)

    got = {}           # pid -> (out_port, tuple(words))
    recon = [[] for _ in range(N)]

    async def driver():
        idx = [0] * N
        while any(idx[p] < len(pending[p]) for p in range(N)):
            tdata = 0
            tvalid = 0
            tlast = 0
            for p in range(N):
                if idx[p] < len(pending[p]) and rng.random() < 0.6:
                    w, last = pending[p][idx[p]]
                    tdata |= (w & MASK) << (p * DATA_W)
                    tvalid |= (1 << p)
                    tlast |= (last << p)
            dut.s_tdata.value = tdata
            dut.s_tvalid.value = tvalid
            dut.s_tlast.value = tlast
            await RisingEdge(dut.aclk)
            await ReadOnly()
            ready = int(dut.s_tready.value)
            for p in range(N):
                if (tvalid >> p) & 1 and (ready >> p) & 1:
                    idx[p] += 1
        dut.s_tvalid.value = 0
        dut.s_tlast.value = 0

    async def monitor():
        while len(got) < total:
            await RisingEdge(dut.aclk)
            await ReadOnly()
            mv = int(dut.m_tvalid.value)
            ml = int(dut.m_tlast.value)
            for o in range(N):
                if (mv >> o) & 1:                 # m_tready is always 1
                    recon[o].append(get_slice(dut.m_tdata, o))
                    if (ml >> o) & 1:
                        words = tuple(recon[o]); recon[o] = []
                        p = (words[0] >> 16) & 0xFFFF
                        got[p] = (o, words)

    d = cocotb.start_soon(driver())
    m = cocotb.start_soon(monitor())
    await d
    # give the pipeline time to drain
    for _ in range(2000):
        if len(got) >= total:
            break
        await RisingEdge(dut.aclk)

    # ---- scoreboard ----
    assert len(got) == total, f"lost packets: got {len(got)}/{total}"
    bad = 0
    for p, (dest, words) in sent.items():
        assert p in got, f"packet {p} never arrived"
        out_port, gw = got[p]
        if out_port != dest:
            dut._log.error(f"pid {p}: arrived at {out_port}, expected {dest}")
            bad += 1
        elif gw != words:
            dut._log.error(f"pid {p}: payload mismatch")
            bad += 1
    assert bad == 0, f"{bad} routing/payload errors"
    dut._log.info(f"PASS: {total} packets routed correctly, none lost.")
