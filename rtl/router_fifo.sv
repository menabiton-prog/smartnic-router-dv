// Synchronous FIFO used for the input and output buffers of the router.
// Standard first-word-fall-through style: dout is valid whenever the FIFO is
// not empty, and advances on rd_en.
`timescale 1ns/1ps

module router_fifo #(
    parameter int WIDTH = 33,
    parameter int DEPTH = 16
)(
    input  logic              clk,
    input  logic              rst_n,

    input  logic [WIDTH-1:0]  din,
    input  logic              wr_en,
    output logic              full,

    output logic [WIDTH-1:0]  dout,
    input  logic              rd_en,
    output logic              empty
);
    localparam int AW = (DEPTH <= 1) ? 1 : $clog2(DEPTH);

    logic [WIDTH-1:0] mem [0:DEPTH-1];
    logic [AW:0]      wptr, rptr;      // extra bit to tell full from empty
    wire  [AW-1:0]    waddr = wptr[AW-1:0];
    wire  [AW-1:0]    raddr = rptr[AW-1:0];

    assign empty = (wptr == rptr);
    assign full  = (waddr == raddr) && (wptr[AW] != rptr[AW]);
    assign dout  = mem[raddr];

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            wptr <= '0;
            rptr <= '0;
        end else begin
            if (wr_en && !full) begin
                mem[waddr] <= din;
                wptr <= wptr + 1'b1;
            end
            if (rd_en && !empty)
                rptr <= rptr + 1'b1;
        end
    end
endmodule
