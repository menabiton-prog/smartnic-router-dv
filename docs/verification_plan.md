# Verification plan — 4x4 packet router

## 1. Purpose
Verify that the router forwards every packet to the output port named in its
header, keeps each packet intact and contiguous, applies back-pressure instead
of dropping data, and never starves an input.

## 2. Device under test
`packet_router` (N = 4, 32-bit flits). Each port is AXI4-Stream. A packet is a
run of flits ending in TLAST; the header's low two bits are the destination.

## 3. Features to verify
| ID | Feature | Priority |
|----|---------|----------|
| F1 | Header decode: packet leaves on the port in its header | high |
| F2 | Payload integrity: output flits equal input flits, in order | high |
| F3 | No loss / no duplication: #out packets == #in packets | high |
| F4 | Packet contiguity: no interleaving of two packets on one output | high |
| F5 | Contention: several inputs targeting one output are all served | high |
| F6 | Round-robin fairness: no input is starved under sustained load | medium |
| F7 | Back-pressure: TREADY low stalls, never drops | medium |
| F8 | Single-flit packets (header is also TLAST) | medium |

## 4. Stimulus
Constrained-random packets on all four inputs at once:
- destination: uniform over 0..3
- length: 1..8 flits (header included), so single-flit and long packets both occur
- payload: traceable pattern (packet id in the upper bits) so the scoreboard can
  identify any flit
- injection and drain pacing are randomized to create bursts, contention and
  FIFO-full conditions

## 5. Checkers
- **Scoreboard** keyed by packet id: on each output packet, confirm the output
  port equals the header destination and the full flit list matches what was
  sent. At end of test, the expected set must be empty (nothing lost).
- **Assertions** (SVA, in the UVM env): AXI4-Stream handshake stability and no
  writes into a full FIFO.

## 6. Coverage model
- destination reached: all of 0..3
- source to destination: all 16 pairs
- packet length: 1..8
- events: contention (>= 2 inputs request one output), output FIFO full
- Goal: 100% of the functional bins above.

## 7. Pass criteria
All directed and random tests pass with zero scoreboard errors and the
functional coverage goal met. The reference-model regression
(`scripts/run_regression.py`) is used to close coverage quickly across seeds.
