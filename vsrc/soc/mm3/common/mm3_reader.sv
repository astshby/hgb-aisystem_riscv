// Module: mm3_reader
// Description: Bounded 128-byte DDR block reader with two-block FIFO and unaligned stream trimming.
module mm3_reader (
    input logic clk, rst, start,
    input logic [31:0] address, bytes,
    output logic busy, failed,
    output logic valid,
    input logic ready,
    output logic [255:0] data,
    output logic [5:0] count,
    output logic last,
    output logic rd_cmd_valid,
    input logic rd_cmd_ready,
    output block_types_pkg::block_cmd_t rd_cmd,
    input logic rd_valid,
    output logic rd_ready,
    input block_types_pkg::block_r_t rd_data
);
    import block_types_pkg::*;
    import bus_types_pkg::*;
    logic [255:0] fifo [8];
    logic [2:0] head_q, tail_q;
    logic [3:0] used_q;
    logic [31:0] issue_addr_q, beats_q, remaining_q;
    logic [4:0] offset_q;
    logic active_q, inflight_q, offer_q, fault_q;
    logic [2:0] burst_q;
    logic push, pop;
    logic [31:0] issue_beats;
    always_comb begin
        issue_beats = beats_q < 4 ? beats_q : 4;
        if (issue_beats > ((4096-{20'b0,issue_addr_q[11:0]}) >> 5))
            issue_beats = (4096-{20'b0,issue_addr_q[11:0]}) >> 5;
        rd_cmd = '0;
        rd_cmd.addr = core_types_pkg::xlen_t'(issue_addr_q);
        rd_cmd.len = 8'(burst_q-1'b1);
        rd_cmd.size = 5;
    end
    assign busy = active_q;
    assign failed = fault_q;
    assign rd_cmd_valid = offer_q;
    assign rd_ready = inflight_q && (fault_q || used_q < 8);
    assign valid = active_q && !fault_q && used_q != 0;
    assign data = fifo[head_q] >> (8*int'(offset_q));
    assign count = remaining_q < (32-int'(offset_q)) ? 6'(remaining_q) : 6'(32-int'(offset_q));
    assign last = remaining_q == 32'(count);
    assign push = rd_valid && rd_ready && !fault_q && rd_data.error == BUS_OK;
    assign pop = valid && ready;
    always_ff @(posedge clk) begin
        if (rst) begin
            head_q <= 0; tail_q <= 0; used_q <= 0;
            active_q <= 0; inflight_q <= 0; offer_q <= 0; fault_q <= 0;
            issue_addr_q <= 0; beats_q <= 0; remaining_q <= 0; offset_q <= 0; burst_q <= 0;
        end else begin
            if (start && !active_q) begin
                head_q <= 0; tail_q <= 0; used_q <= 0; fault_q <= 0;
                issue_addr_q <= address & 32'hffffffe0;
                beats_q <= (bytes+{27'b0,address[4:0]}+31) >> 5;
                remaining_q <= bytes; offset_q <= address[4:0]; active_q <= bytes != 0;
            end else begin
                unique case ({push,pop})
                    2'b10: used_q <= used_q+1'b1;
                    2'b01: used_q <= used_q-1'b1;
                    default: ;
                endcase
                if (push) begin fifo[tail_q] <= rd_data.data; tail_q <= tail_q+1'b1; end
                if (pop) begin
                    head_q <= head_q+1'b1; offset_q <= 0; remaining_q <= remaining_q-32'(count);
                    if (last) active_q <= 0;
                end
                if (active_q && !fault_q && !inflight_q && !offer_q && beats_q != 0 &&
                    32'(used_q)+issue_beats <= 8) begin
                    burst_q <= 3'(issue_beats); offer_q <= 1;
                end
                if (rd_cmd_valid && rd_cmd_ready) begin
                    offer_q <= 0; inflight_q <= 1;
                    issue_addr_q <= issue_addr_q+32'(burst_q)*32;
                    beats_q <= beats_q-32'(burst_q);
                end
                if (rd_valid && rd_ready) begin
                    if (rd_data.error != BUS_OK) fault_q <= 1;
                    if (rd_data.last) begin
                        inflight_q <= 0;
                        if (fault_q || rd_data.error != BUS_OK) active_q <= 0;
                    end
                end
            end
        end
    end
endmodule
