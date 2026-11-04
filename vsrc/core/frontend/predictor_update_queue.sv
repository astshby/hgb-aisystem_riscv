// Module: predictor_update_queue
// Description: Preserves both retirement training events in program order for a single predictor port.
module predictor_update_queue #(
    parameter int unsigned DEPTH = core_config_pkg::RETIRE_ENTRIES
) (
    input logic clk, rst,
    input pipeline_pkg::pred_update_t incoming [2],
    output logic [1:0] capacity,
    output pipeline_pkg::pred_update_t update
);
    import pipeline_pkg::*;
    localparam int PTR_W = $clog2(DEPTH);
    localparam int COUNT_W = $clog2(DEPTH+1);
    pred_update_t entries_q [DEPTH];
    logic [PTR_W-1:0] head_q, tail_q;
    logic [COUNT_W-1:0] count_q;
    logic [1:0] push_count;
    logic pop;
    always_comb begin
        update = entries_q[head_q];
        update.valid = !rst && count_q != 0;
        pop = update.valid;
        capacity = (count_q <= COUNT_W'(DEPTH - 2)) ? 2'd2 : 2'd1;
        push_count = {1'b0, incoming[0].valid} + {1'b0, incoming[1].valid};
    end
    always_ff @(posedge clk) begin
        if (rst) begin
            head_q <= '0; tail_q <= '0; count_q <= '0;
        end else begin
            head_q <= head_q + PTR_W'(pop);
            tail_q <= tail_q + PTR_W'(push_count);
            count_q <= count_q + COUNT_W'(push_count) - COUNT_W'(pop);
            if (incoming[0].valid) entries_q[tail_q] <= incoming[0];
            if (incoming[1].valid)
                entries_q[tail_q + PTR_W'(incoming[0].valid)] <= incoming[1];
        end
    end
`ifndef SYNTHESIS
    always_ff @(posedge clk) if (!rst)
        assert (push_count <= capacity) else $fatal(1, "predictor training overflow");
`endif
endmodule
