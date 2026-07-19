// ---------------------------------------------------------------------------
// packet_router.sv
// A small NxN packet switch. Each port is an AXI4-Stream. A packet is a run of
// flits ending in TLAST; the first flit is a header whose low two bits name the
// destination port. Packets are buffered per input, routed to the output named
// in their header, and kept contiguous on each output by a per-output
// round-robin arbiter (a granted input holds the output until its TLAST).
//
// This mirrors model/router_model.py, which is the golden reference for the
// UVM and cocotb scoreboards.
// ---------------------------------------------------------------------------
`timescale 1ns/1ps

module packet_router #(
    parameter int N      = 4,
    parameter int DATA_W = 32,
    parameter int IN_DEPTH  = 16,
    parameter int OUT_DEPTH = 16
)(
    input  logic                aclk,
    input  logic                aresetn,

    // input AXI4-Stream ports
    input  logic [DATA_W-1:0]   s_axis_tdata  [N],
    input  logic                s_axis_tvalid [N],
    output logic                s_axis_tready [N],
    input  logic                s_axis_tlast  [N],

    // output AXI4-Stream ports
    output logic [DATA_W-1:0]   m_axis_tdata  [N],
    output logic                m_axis_tvalid [N],
    input  logic                m_axis_tready [N],
    output logic                m_axis_tlast  [N]
);
    localparam int W    = $clog2(N);
    localparam int FW   = DATA_W + 1;          // {tlast, tdata}

    // ---- input FIFOs -------------------------------------------------------
    logic [FW-1:0] in_dout  [N];
    logic          in_empty [N];
    logic          in_full  [N];
    logic          in_rd    [N];

    genvar gi;
    generate
        for (gi = 0; gi < N; gi++) begin : g_in_fifo
            router_fifo #(.WIDTH(FW), .DEPTH(IN_DEPTH)) u_in (
                .clk(aclk), .rst_n(aresetn),
                .din  ({s_axis_tlast[gi], s_axis_tdata[gi]}),
                .wr_en(s_axis_tvalid[gi] & ~in_full[gi]),
                .full (in_full[gi]),
                .dout (in_dout[gi]),
                .rd_en(in_rd[gi]),
                .empty(in_empty[gi])
            );
            assign s_axis_tready[gi] = ~in_full[gi];
        end
    endgenerate

    // head-of-line fields for each input
    wire [DATA_W-1:0] in_data [N];
    wire              in_last [N];
    wire [W-1:0]      in_dest [N];
    generate
        for (gi = 0; gi < N; gi++) begin : g_hol
            assign in_data[gi] = in_dout[gi][DATA_W-1:0];
            assign in_last[gi] = in_dout[gi][DATA_W];
            assign in_dest[gi] = in_data[gi][W-1:0];   // header dest field
        end
    endgenerate

    // ---- per-input packet state -------------------------------------------
    logic          busy_in [N];   // input i is mid-packet (already granted)
    logic [W-1:0]  dst_in  [N];   // output it is streaming to

    // ---- per-output arbitration + datapath --------------------------------
    logic          out_busy [N];
    logic [W-1:0]  out_src  [N];

    logic [N-1:0]  req      [N];  // req[o][i]
    logic [N-1:0]  gnt      [N];
    logic [W-1:0]  gnt_idx  [N];
    logic          gnt_vld  [N];
    logic          arb_upd  [N];

    // output FIFOs
    logic [FW-1:0] out_din  [N];
    logic          out_wr   [N];
    logic          out_full [N];
    logic [FW-1:0] out_dout [N];
    logic          out_empty[N];

    genvar go;
    generate
        for (go = 0; go < N; go++) begin : g_out
            // request: idle inputs whose header targets this output
            for (gi = 0; gi < N; gi++) begin : g_req
                assign req[go][gi] = ~in_empty[gi] & ~busy_in[gi] & (in_dest[gi] == go[W-1:0]);
            end

            rr_arbiter #(.N(N)) u_arb (
                .clk(aclk), .rst_n(aresetn),
                .req(req[go]), .update(arb_upd[go]),
                .grant(gnt[go]), .gnt_idx(gnt_idx[go]), .grant_valid(gnt_vld[go])
            );

            // a granted, busy output transfers one flit whenever it can
            wire src_ne  = ~in_empty[out_src[go]];
            wire can_xfer = out_busy[go] & src_ne & ~out_full[go];

            assign arb_upd[go] = ~out_busy[go] & gnt_vld[go];       // pointer moves on grant
            assign out_wr[go]  = can_xfer;
            assign out_din[go] = in_dout[out_src[go]];

            router_fifo #(.WIDTH(FW), .DEPTH(OUT_DEPTH)) u_out (
                .clk(aclk), .rst_n(aresetn),
                .din  (out_din[go]),
                .wr_en(out_wr[go]),
                .full (out_full[go]),
                .dout (out_dout[go]),
                .rd_en(m_axis_tvalid[go] & m_axis_tready[go]),
                .empty(out_empty[go])
            );

            assign m_axis_tvalid[go] = ~out_empty[go];
            assign m_axis_tdata[go]  = out_dout[go][DATA_W-1:0];
            assign m_axis_tlast[go]  = out_dout[go][DATA_W];
        end
    endgenerate

    // input read enable: the (single) output currently draining input i
    always_comb begin
        for (int i = 0; i < N; i++) in_rd[i] = 1'b0;
        for (int o = 0; o < N; o++) begin
            if (out_busy[o] && ~in_empty[out_src[o]] && ~out_full[o])
                in_rd[out_src[o]] = 1'b1;
        end
    end

    // ---- sequential control ------------------------------------------------
    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            for (int i = 0; i < N; i++) begin
                busy_in[i]  <= 1'b0;
                dst_in[i]   <= '0;
                out_busy[i] <= 1'b0;
                out_src[i]  <= '0;
            end
        end else begin
            for (int o = 0; o < N; o++) begin
                if (!out_busy[o]) begin
                    // start a new packet if the arbiter picked a requester
                    if (gnt_vld[o]) begin
                        out_busy[o]        <= 1'b1;
                        out_src[o]         <= gnt_idx[o];
                        busy_in[gnt_idx[o]]<= 1'b1;
                        dst_in[gnt_idx[o]] <= o[W-1:0];
                    end
                end else begin
                    // stream flits; release on the packet's TLAST
                    if (~in_empty[out_src[o]] && ~out_full[o] && in_last[out_src[o]]) begin
                        out_busy[o]         <= 1'b0;
                        busy_in[out_src[o]] <= 1'b0;
                    end
                end
            end
        end
    end
endmodule
