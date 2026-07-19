// AXI4-Stream interface bundling all N input and output ports of the router.
// Agents pick their port with an index handed over through the config DB.
`timescale 1ns/1ps

interface router_if #(parameter int N = 4, parameter int DATA_W = 32)
                     (input logic aclk, input logic aresetn);

    logic [DATA_W-1:0] s_tdata  [N];
    logic              s_tvalid [N];
    logic              s_tready [N];
    logic              s_tlast  [N];

    logic [DATA_W-1:0] m_tdata  [N];
    logic              m_tvalid [N];
    logic              m_tready [N];
    logic              m_tlast  [N];
endinterface
