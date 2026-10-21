// Module: lsu_transaction
// Description: Owns one head-authorized memory transaction and its existing registered response slot.
module lsu_transaction (
    input logic clk, rst, cancel,
    input logic issue_valid,
    output logic issue_ready,
    input pipeline_pkg::lsu_descriptor_t descriptor,
    input logic head_valid,
    input pipeline_pkg::retire_id_t head_id,
    output logic dmem_req_valid,
    input logic dmem_req_ready,
    output logic dmem_req_write,
    output core_types_pkg::mem_size_e dmem_req_size,
    output core_types_pkg::xlen_t dmem_req_addr, dmem_req_wdata,
    output logic [core_config_pkg::DBUS_BYTES-1:0] dmem_req_wstrb,
    input logic dmem_rsp_valid,
    output logic dmem_rsp_ready,
    input core_types_pkg::xlen_t dmem_rsp_rdata,
    input logic dmem_rsp_error,
    output logic complete_valid,
    input logic complete_ready,
    output pipeline_pkg::retire_completion_t completion,
    output pipeline_pkg::retire_gpr_forward_t registered_forward,
    output logic busy, draining, owner_valid, request_pending,
    output pipeline_pkg::retire_id_t owner_id
);
    import core_types_pkg::*;
    import pipeline_pkg::*;
    import riscv_priv_pkg::*;

    typedef enum logic [1:0] {IDLE, PREP, WAIT, DRAIN} state_e;
    state_e state_q;
    lsu_descriptor_t owner_q;
    logic issue_fire, dmem_req_fire, dmem_rsp_fire, complete_fire;
    logic response_ready, response_valid, response_error, response_consume;
    xlen_t load_data;

    // cancel 由调用者依据队列年龄选择当前 owner；模块不复制队列年龄或完成状态。
    // issue 仅交付已通过 EX 早期异常检查的访存；异常指令直接完成，不进入本事务槽。
    // rst 必须与总线从端协调：仅复位 Core 而保留外部旧事务不属于此接口契约。
    assign busy = state_q != IDLE;
    assign owner_valid = busy;
    assign owner_id = owner_q.id;
    assign draining = state_q == DRAIN;
    // 只导出既有状态的译码，不在 Core 复制 pending/响应状态。
    assign request_pending = state_q == PREP;
    assign complete_fire = complete_valid && complete_ready;
    assign issue_ready = !rst && !cancel && (state_q == IDLE || complete_fire);
    assign issue_fire = issue_valid && issue_ready;

    // 全部外部 Load/Store 都必须属于完整 ID 的队头，不等待 head_complete/retire_fire。
    // 队头一旦展示请求，调用方必须保持资格直至握手，不能用重定向撤回总线 valid。
    assign dmem_req_valid = !rst && state_q == PREP && head_valid && head_id == owner_q.id;
    assign dmem_req_write = owner_q.write;
    assign dmem_req_size = owner_q.size;
    assign dmem_req_addr = owner_q.address;
    assign dmem_req_wdata = owner_q.wdata;
    assign dmem_req_wstrb = owner_q.wstrb;
    assign dmem_req_fire = dmem_req_valid && dmem_req_ready;

    // 接受请求之后才接响应：E0 req_fire，最快 E1 rsp_fire，E2 complete_fire。
    // DRAIN 直接丢弃旧响应，不再生成有效结果；未排空前 descriptor/ID 不可复用。
    assign dmem_rsp_ready = !rst && ((state_q == WAIT && response_ready) || state_q == DRAIN);
    assign dmem_rsp_fire = dmem_rsp_valid && dmem_rsp_ready;
    assign response_consume = complete_fire || cancel;
    wb_response_register u_response_register (
        .clk, .rst, .memory_pending(state_q == WAIT),
        .address(owner_q.address), .size(owner_q.size), .unsigned_load(owner_q.unsigned_load),
        .rsp_valid(dmem_rsp_valid && state_q == WAIT), .rsp_ready(response_ready),
        .rsp_data(dmem_rsp_rdata), .rsp_error(dmem_rsp_error), .consume(response_consume),
        .response_valid, .load_data, .response_error
    );

    // 唯一结果数据槽由 wb_response_register 持有；取消不组合压低完成 valid。
    // 完成触发队头 Trap 时仍可交付原包，队列在同沿依 flush/年龄决定接纳或拒绝。
    assign complete_valid = !rst && state_q == WAIT && response_valid;
    always_comb begin
        completion = '0;
        completion.id = owner_q.id;
        if (!owner_q.write) completion.result.gpr_data = load_data;
        if (response_error) begin
            completion.result.exc.valid = 1'b1;
            completion.result.exc.cause = owner_q.write ? EXC_STORE_ACCESS_FAULT : EXC_LOAD_ACCESS_FAULT;
            completion.result.exc.tval = owner_q.address;
        end
        registered_forward = '0;
        registered_forward.valid = complete_valid && !owner_q.write && !response_error;
        registered_forward.id = owner_q.id;
        registered_forward.data = load_data;
    end

    // 响应有效位本身表达 RESULT，不再复制一个状态或数据寄存器。
    // 完成与下一描述符可同沿周转；取消当拍拒收新项，确保旧 owner 清除与新 ID 隔离。
    always_ff @(posedge clk) begin
        if (rst) begin
            state_q <= IDLE;
        end else if (cancel) begin
            unique case (state_q)
                PREP: state_q <= dmem_req_fire ? DRAIN : IDLE;
                WAIT: state_q <= (response_valid || dmem_rsp_fire) ? IDLE : DRAIN;
                DRAIN: if (dmem_rsp_fire) state_q <= IDLE;
                default: state_q <= IDLE;
            endcase
        end else if (issue_fire) begin
            state_q <= PREP;
        end else begin
            unique case (state_q)
                PREP: if (dmem_req_fire) state_q <= WAIT;
                WAIT: if (complete_fire) state_q <= IDLE;
                DRAIN: if (dmem_rsp_fire) state_q <= IDLE;
                default: state_q <= IDLE;
            endcase
        end
    end
    always_ff @(posedge clk) begin
        if (issue_fire) owner_q <= descriptor;
    end

    // 单元取消边界：已展示而未接受的请求不可撤回；严格队头架构必须排除此取消。
    // cancel+req_fire 仍保存 owner 排空，但不能撤销已发生的写/MMIO 副作用。
    // 后续 Core 接入还必须证明该组合不会取消架构上已授权的副作用。
`ifndef SYNTHESIS
    logic request_held_q;
    always_ff @(posedge clk) begin
        if (rst) begin
            request_held_q <= 1'b0;
        end else begin
            assert (!(cancel && dmem_req_valid && !dmem_req_ready))
                else $fatal(1, "LSU cancel cannot withdraw a blocked request");
            if (request_held_q)
                assert (dmem_req_valid)
                    else $fatal(1, "LSU head permission cannot withdraw a blocked request");
            request_held_q <= dmem_req_valid && !dmem_req_ready;
        end
    end
`endif
endmodule
