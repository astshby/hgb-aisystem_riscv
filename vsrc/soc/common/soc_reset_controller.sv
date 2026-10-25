// Module: soc_reset_controller
// Description: Common asynchronous assertion and per-domain synchronous release.
module soc_reset_controller (
    input logic reset_async,
    input logic clk_core, clk_sys, clk_ddr, clk_periph,
    output logic rst_core, rst_sys, rst_ddr, rst_periph
);
    wire [3:0] clocks = {clk_periph, clk_ddr, clk_sys, clk_core};
    logic [3:0] resets;
    for (genvar d = 0; d < 4; d++) begin : g_domain
        (* ASYNC_REG = "TRUE" *) logic [2:0] release_q;
        always_ff @(posedge clocks[d] or posedge reset_async) begin
            if (reset_async) release_q <= '1;
            else release_q <= {release_q[1:0], 1'b0};
        end
        assign resets[d] = release_q[2];
    end
    assign {rst_periph, rst_ddr, rst_sys, rst_core} = resets;
endmodule
