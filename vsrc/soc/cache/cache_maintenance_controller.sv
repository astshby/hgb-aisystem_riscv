// Module: cache_maintenance_controller
// Description: Serializes asynchronous software maintenance and FENCE.I clean-before-fetch.
module cache_maintenance_controller #(
    parameter bit ACTIVE = 1'b1
) (
    input logic clk, rst, fence_i_commit,
    input logic command_valid,
    output logic command_ready,
    input cache_pkg::cache_maint_op_e command,
    output logic busy, fetch_block, fatal,
    output cache_pkg::cache_maint_error_e error,
    output core_types_pkg::xlen_t fault_addr,
    output logic maint_req_valid,
    input logic maint_req_ready,
    output cache_pkg::cache_maint_op_e maint_op,
    input logic maint_rsp_valid,
    output logic maint_rsp_ready,
    input cache_pkg::cache_maint_error_e maint_error,
    input core_types_pkg::xlen_t maint_fault_addr,
    input logic cache_fault_valid,
    input cache_pkg::cache_maint_error_e cache_fault_code,
    input core_types_pkg::xlen_t cache_fault_addr
);
    import cache_pkg::*;
    typedef enum logic [1:0] {IDLE, START, WAIT_DONE} state_e;
    state_e state_q;
    logic fence_pending_q, fence_owner_q;
    assign busy = state_q != IDLE || fence_pending_q || (ACTIVE && fence_i_commit);
    assign command_ready = !rst && !busy && !fatal;
    assign fetch_block = fatal || fence_pending_q || (ACTIVE && fence_i_commit);
    assign maint_req_valid = state_q == START;
    assign maint_rsp_ready = state_q == WAIT_DONE;
    // MMIO 只确认命令入队，必须释放原 D 主事务后，维护才能借同一端口发出写回。
    always_ff @(posedge clk) begin
        if (rst) begin
            state_q <= IDLE; fence_pending_q <= 0; fence_owner_q <= 0;
            maint_op <= CACHE_NONE; fatal <= 0; error <= CACHE_OK; fault_addr <= '0;
        end else begin
            if (ACTIVE && fence_i_commit) fence_pending_q <= 1;
            if (cache_fault_valid) begin error <= cache_fault_code; fault_addr <= cache_fault_addr; end
            case (state_q)
                IDLE: if (!fatal) begin
                    if (fence_pending_q || (ACTIVE && fence_i_commit)) begin
                        maint_op <= CACHE_CLEAN; fence_owner_q <= 1; state_q <= START;
                    end else if (command_valid && command_ready) begin
                        maint_op <= command; fence_owner_q <= 0;
                        error <= CACHE_OK; fault_addr <= '0; state_q <= START;
                    end
                end
                START: if (maint_req_ready) state_q <= WAIT_DONE;
                WAIT_DONE: if (maint_rsp_valid) begin
                    if (maint_error != CACHE_OK) begin error <= maint_error; fault_addr <= maint_fault_addr; end
                    if (fence_owner_q) begin
                        // 无机器检查异常协议时，写回失败必须停取指；不能执行可能陈旧的代码。
                        if (maint_error != CACHE_OK) fatal <= 1;
                        else fence_pending_q <= 0;
                    end
                    state_q <= IDLE;
                end
                default: state_q <= IDLE;
            endcase
        end
    end
endmodule
