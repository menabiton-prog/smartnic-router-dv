// Round-robin arbiter. Grants the first requester at or after a rotating
// pointer, and advances the pointer past the winner when `update` is asserted,
// so no requester can starve.
`timescale 1ns/1ps

module rr_arbiter #(
    parameter int N = 4
)(
    input  logic               clk,
    input  logic               rst_n,
    input  logic [N-1:0]       req,
    input  logic               update,        // move the pointer past the winner
    output logic [N-1:0]       grant,
    output logic [$clog2(N)-1:0] gnt_idx,
    output logic               grant_valid
);
    localparam int W = $clog2(N);
    logic [W-1:0] ptr;

    always_comb begin
        grant       = '0;
        gnt_idx     = '0;
        grant_valid = 1'b0;
        for (int k = 0; k < N; k++) begin
            automatic int idx = (ptr + k) % N;
            if (!grant_valid && req[idx]) begin
                grant_valid = 1'b1;
                grant[idx]  = 1'b1;
                gnt_idx     = idx[W-1:0];
            end
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n)
            ptr <= '0;
        else if (update && grant_valid)
            ptr <= (gnt_idx + 1) % N;
    end
endmodule
