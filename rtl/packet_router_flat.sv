// Flattened wrapper around packet_router: turns the per-port unpacked-array
// interface into plain vectors, which is easier to drive from cocotb.
`timescale 1ns/1ps

module packet_router_flat #(
    parameter int N      = 4,
    parameter int DATA_W = 32
)(
    input  logic                aclk,
    input  logic                aresetn,

    input  logic [N*DATA_W-1:0] s_tdata,
    input  logic [N-1:0]        s_tvalid,
    output logic [N-1:0]        s_tready,
    input  logic [N-1:0]        s_tlast,

    output logic [N*DATA_W-1:0] m_tdata,
    output logic [N-1:0]        m_tvalid,
    input  logic [N-1:0]        m_tready,
    output logic [N-1:0]        m_tlast
);
    logic [DATA_W-1:0] sd [N], md [N];
    logic sv [N], sr [N], sl [N], mv [N], mr [N], ml [N];

    genvar i;
    generate
        for (i = 0; i < N; i++) begin : g_map
            assign sd[i]                    = s_tdata[i*DATA_W +: DATA_W];
            assign sv[i]                    = s_tvalid[i];
            assign s_tready[i]              = sr[i];
            assign sl[i]                    = s_tlast[i];
            assign m_tdata[i*DATA_W +: DATA_W] = md[i];
            assign m_tvalid[i]              = mv[i];
            assign mr[i]                    = m_tready[i];
            assign m_tlast[i]               = ml[i];
        end
    endgenerate

    packet_router #(.N(N), .DATA_W(DATA_W)) u_router (
        .aclk(aclk), .aresetn(aresetn),
        .s_axis_tdata(sd), .s_axis_tvalid(sv), .s_axis_tready(sr), .s_axis_tlast(sl),
        .m_axis_tdata(md), .m_axis_tvalid(mv), .m_axis_tready(mr), .m_axis_tlast(ml)
    );
endmodule
