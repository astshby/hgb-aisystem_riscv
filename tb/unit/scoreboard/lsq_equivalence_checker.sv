// Module: lsq_equivalence_checker
// Description: Compares observable LSU handshakes and payloads against the frozen P0 implementation.
module lsq_equivalence_checker #(
    parameter int unsigned COMPLETION_PORTS = 2
) (
    input logic clk, rst, flush,
    input scoreboard_pkg::branch_recovery_t recovery,
    input logic [core_config_pkg::RETIRE_IDX_W-1:0] head_slot,
    input logic head_valid,
    input pipeline_pkg::retire_id_t head_id,
    input logic [1:0] offer_valid, issue_fire, issue_ready,
    input pipeline_pkg::lsu_descriptor_t descriptor [2],
    input logic [1:0] mem_req_valid, mem_req_ready,
    input scoreboard_pkg::memory_request_t mem_request [2],
    input logic [1:0] mem_rsp_valid, mem_rsp_ready,
    input scoreboard_pkg::memory_response_t mem_response [2],
    input logic [1:0] response_reject,
    input logic [COMPLETION_PORTS-1:0] complete_valid, complete_ready,
    input pipeline_pkg::retire_completion_t completion [COMPLETION_PORTS],
    input pipeline_pkg::retire_gpr_forward_t early_forward [2],
    input logic busy, draining, store_owner_valid,
    input pipeline_pkg::retire_id_t store_owner_id
);
    logic [1:0] ref_issue_ready, ref_req_valid, ref_rsp_ready, ref_reject;
    logic [COMPLETION_PORTS-1:0] ref_complete_valid;
    scoreboard_pkg::memory_request_t ref_request [2];
    pipeline_pkg::retire_completion_t ref_completion [COMPLETION_PORTS];
    pipeline_pkg::retire_gpr_forward_t ref_forward [2];
    logic ref_busy, ref_draining, ref_owner_valid;
    pipeline_pkg::retire_id_t ref_owner_id;
    load_store_queue_reference #(.COMPLETION_PORTS(COMPLETION_PORTS)) reference_lsq (
        .issue_ready(ref_issue_ready), .mem_req_valid(ref_req_valid), .mem_request(ref_request),
        .mem_rsp_ready(ref_rsp_ready), .response_reject(ref_reject),
        .complete_valid(ref_complete_valid), .completion(ref_completion), .early_forward(ref_forward),
        .busy(ref_busy), .draining(ref_draining), .store_owner_valid(ref_owner_valid),
        .store_owner_id(ref_owner_id), .*
    );
    // 在相同时钟沿比较有效包和全部握手；无效载荷不参与比较。
    always_ff @(posedge clk) if (!rst) begin
        assert (issue_ready == ref_issue_ready && mem_req_valid == ref_req_valid &&
            mem_rsp_ready == ref_rsp_ready && response_reject == ref_reject &&
            complete_valid == ref_complete_valid && busy == ref_busy && draining == ref_draining &&
            store_owner_valid == ref_owner_valid) else $fatal(1, "P0 LSU handshake mismatch");
        if (store_owner_valid)
            assert (store_owner_id == ref_owner_id) else $fatal(1, "P0 LSU Store owner mismatch");
        for (int portno = 0; portno < 2; portno++) begin
            if (mem_req_valid[portno])
                assert (mem_request[portno] == ref_request[portno]) else $fatal(1, "P0 LSU request mismatch");
            assert (early_forward[portno].valid == ref_forward[portno].valid)
                else $fatal(1, "P0 LSU early-forward valid mismatch");
            if (early_forward[portno].valid)
                assert (early_forward[portno] == ref_forward[portno]) else $fatal(1, "P0 LSU early-forward data mismatch");
        end
        for (int slot = 0; slot < COMPLETION_PORTS; slot++)
            if (complete_valid[slot])
                assert (completion[slot] == ref_completion[slot]) else $fatal(1, "P0 LSU completion mismatch");
    end
endmodule
bind load_store_queue lsq_equivalence_checker #(.COMPLETION_PORTS(COMPLETION_PORTS)) check_p0 (.*);
