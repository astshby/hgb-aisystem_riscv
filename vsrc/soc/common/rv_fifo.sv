// Module: rv_fifo
// Description: Registered elastic FIFO with capacity-only input ready and no payload reset.
module rv_fifo #(
    parameter int WIDTH = 32,
    parameter int DEPTH = 2,
    parameter int COUNT_W = $clog2(DEPTH+1)
) (
    input logic clk, rst,
    input logic in_valid,
    output logic in_ready,
    input logic [WIDTH-1:0] in_data,
    output logic out_valid,
    input logic out_ready,
    output logic [WIDTH-1:0] out_data,
    output logic [COUNT_W-1:0] occupancy
);
    localparam int PTR_W = DEPTH > 1 ? $clog2(DEPTH) : 1;
    logic [WIDTH-1:0] payload [DEPTH];
    logic [PTR_W-1:0] read_q, write_q;
    logic in_fire, out_fire;
    assign in_ready = !rst && occupancy < COUNT_W'(DEPTH);
    assign out_valid = !rst && occupancy != 0;
    assign out_data = payload[read_q];
    assign in_fire = in_valid && in_ready;
    assign out_fire = out_valid && out_ready;
    // ready 只读本地计数；满转非满允许一拍恢复，稳态仍可每拍传输。
    always_ff @(posedge clk) begin
        if (rst) begin
            read_q <= '0;
            write_q <= '0;
            occupancy <= '0;
        end else begin
            case ({in_fire, out_fire})
                2'b10: occupancy <= occupancy + 1'b1;
                2'b01: occupancy <= occupancy - 1'b1;
                default: ;
            endcase
            if (in_fire) write_q <= write_q == PTR_W'(DEPTH-1) ? '0 : write_q + 1'b1;
            if (out_fire) read_q <= read_q == PTR_W'(DEPTH-1) ? '0 : read_q + 1'b1;
        end
        if (in_fire) payload[write_q] <= in_data;
    end
`ifndef SYNTHESIS
    initial assert (DEPTH >= 2) else $fatal(1, "rv_fifo DEPTH must be >=2");
    assert property (@(posedge clk) disable iff (rst) out_valid && !out_ready |=>
                     rst || (out_valid && $stable(out_data)));
`endif
endmodule
