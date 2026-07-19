// Top-level for the UVM simulation: clock/reset, DUT, interface, run_test.
`timescale 1ns/1ps

module tb_top;
    import uvm_pkg::*;
    import router_pkg::*;
    `include "uvm_macros.svh"

    localparam int N      = 4;
    localparam int DATA_W = 32;

    logic aclk = 0;
    logic aresetn = 0;
    always #5 aclk = ~aclk;

    router_if #(N, DATA_W) rif (aclk, aresetn);

    // outputs are always ready in this test (add random back-pressure to extend)
    genvar o;
    generate
        for (o = 0; o < N; o++) begin : g_rdy
            assign rif.m_tready[o] = 1'b1;
        end
    endgenerate

    packet_router #(.N(N), .DATA_W(DATA_W)) dut (
        .aclk(aclk), .aresetn(aresetn),
        .s_axis_tdata (rif.s_tdata),
        .s_axis_tvalid(rif.s_tvalid),
        .s_axis_tready(rif.s_tready),
        .s_axis_tlast (rif.s_tlast),
        .m_axis_tdata (rif.m_tdata),
        .m_axis_tvalid(rif.m_tvalid),
        .m_axis_tready(rif.m_tready),
        .m_axis_tlast (rif.m_tlast)
    );

    initial begin
        uvm_config_db#(virtual router_if #(N, DATA_W))::set(null, "*", "vif", rif);
        repeat (5) @(posedge aclk);
        aresetn = 1;
    end

    initial run_test("router_test");
endmodule
