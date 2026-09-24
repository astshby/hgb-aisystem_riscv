// Module: core
// Description: Portable single-issue IF-D1-D2-EX-MEM-WB in-order core.
module core (
    // 端口声明中使用包类型时需要写完整包名
    input  logic                              clk,
    input  logic                              rst,
    output logic                              imem_req_valid,
    output logic [core_config_pkg::XLEN-1:0]  imem_req_addr,
    input  logic                              imem_req_ready,
    input  logic                              imem_rsp_valid,
    input  logic [31:0]                       imem_rsp_data,
    output logic                              imem_rsp_ready,
    output logic                              dmem_req_valid,
    output logic                              dmem_req_write,
    output logic [core_config_pkg::XLEN-1:0]  dmem_req_addr,
    output logic [core_config_pkg::XLEN-1:0]  dmem_req_wdata,
    output logic [core_config_pkg::DBUS_BYTES-1:0] dmem_req_wstrb,
    input  logic                              dmem_req_ready,
    input  logic                              dmem_rsp_valid,
    input  logic [core_config_pkg::XLEN-1:0]  dmem_rsp_rdata,
    output logic                              dmem_rsp_ready,
    // commit 用于退休统计、差分测试和波形调试。
    output logic                              commit_valid,
    output logic [core_config_pkg::XLEN-1:0]  commit_pc,
    output logic [31:0]                       commit_inst,
    output logic [core_config_pkg::GPR_ADDR_W-1:0] commit_rd,
    output logic                              commit_rd_we,
    output logic [core_config_pkg::XLEN-1:0]  commit_rd_data,
    output logic                              commit_exception
);
    import core_config_pkg::*;
    import core_types_pkg::*;
    import pipeline_pkg::*;
    import riscv_priv_pkg::*;

    // 六级流水线的五组级间寄存器；_q 表示真正的时序状态。
    if_d1_t if_d1_q;
    d1_d2_t d1_d2_q;
    d2_ex_t d2_ex_q;
    ex_mem_t ex_mem_q;
    mem_wb_t mem_wb_q;

    if_d1_t fetch_packet;
    d1_d2_t d1_packet;
    d2_ex_t d2_packet;
    ex_mem_t ex_packet;
    mem_wb_t mem_packet;

    // 预测、重定向与错误路径清理。
    pred_info_t prediction;
    redirect_t d1_redirect;
    redirect_t ex_redirect;
    redirect_t wb_redirect;
    redirect_t selected_redirect;
    pred_update_t d1_update_raw;
    pred_update_t ex_update_raw;
    pred_update_t d1_update;
    pred_update_t ex_update;
    pred_update_t predictor_update;
    logic predictor_overflow;
    logic d1_flush;

    // GPR 读写和前递。
    xlen_t rs1_data;
    xlen_t rs2_data;
    gpr_forward_t mem_gpr_forward;
    gpr_forward_t wb_gpr_write;

    // CSR 读取、旁路、提交与 Trap 状态。
    xlen_t csr_committed_data;
    csr_forward_t mem_csr_forward;
    csr_forward_t wb_csr_write;
    logic trap_enter;
    logic mret_commit;
    xlen_t trap_pc;
    exc_cause_e trap_cause;
    xlen_t trap_tval;
    logic retire_valid;
    xlen_t mtvec;
    xlen_t mepc;

    // 冒险、存储器反压、序列化与流水线动作。
    logic load_use_stall;
    logic mem_request_stall;
    logic wb_wait;
    logic execution_stall;
    logic mem_issue_enable;
    logic mdu_operands_ready;
    pipeline_actions_t pipeline_actions;
    logic fetch_ready;
    logic d1_stage_advance;
    logic ex_stage_advance;
    logic d1_serialize_req;
    logic ex_serialize_req;
    logic serialize_start;
    logic frontend_flush;
    logic fetch_request_enable;

    // 参数断言仅用于仿真与 lint。
`ifndef SYNTHESIS
    initial begin
        assert ((XLEN == 32) || (XLEN == 64))
            else $error("CORE_XLEN must be 32 or 64");
    end
`endif

    // D1/EX 已排除本级异常，Core 只在流水级真正推进时放行训练。
    // WB/EX 清除 D1 及其后续时，pending 中的年轻预测更新也必须作废。
    always_comb begin
        d1_stage_advance = (pipeline_actions.d1_d2 == PIPE_ADVANCE);
        ex_stage_advance = d2_ex_q.valid &&
                           (pipeline_actions.ex_mem == PIPE_ADVANCE);
        d1_update = d1_update_raw;
        ex_update = ex_update_raw;
        d1_update.valid = d1_update_raw.valid && d1_stage_advance;
        ex_update.valid = ex_update_raw.valid && (pipeline_actions.ex_mem == PIPE_ADVANCE);
    end

    // 预测器裁决
    predictor_update_arbiter u_predictor_update_arbiter (
        .clk,
        .rst,
        .d1_flush,
        .d1_update,
        .ex_update,
        .update(predictor_update),
        .overflow(predictor_overflow)
    );

    // 分支预测器
    predictor u_predictor (
        .clk,
        .rst,
        .lookup_pc(imem_req_addr),
        .prediction,
        .update(predictor_update)
    );

    // 更新端口持续过载表示预测器丢失了一次训练，只在仿真中报错。
`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (!rst)
            assert (!predictor_overflow)
                else $error("predictor update pending buffer overflow");
    end
`endif

    // 各功能单元与流水级连线。
    // WB Trap/MRET 正常完成序列化；更老的 D1/EX 控制流重定向取消错误路径序列化。
    serialize_controller u_serialize_controller (
        .clk,
        .rst,
        .serialize_start,
        .serialize_complete(wb_redirect.valid),
        .serialize_cancel(selected_redirect.valid && !wb_redirect.valid), // 更老的重定向就能清除
        .frontend_flush,
        .fetch_request_enable
    );

    if_stage u_if_stage (
        .clk,
        .rst,
        .fetch_request_enable,
        .out_ready(fetch_ready),
        .flush(frontend_flush),
        .redirect(selected_redirect),
        .prediction,
        .out_packet(fetch_packet),
        .imem_req_valid,
        .imem_req_addr,
        .imem_req_ready,
        .imem_rsp_valid,
        .imem_rsp_data,
        .imem_rsp_ready
    );

    d1_stage u_d1_stage (
        .in_packet(if_d1_q),
        .out_packet(d1_packet),
        .redirect(d1_redirect),
        .pred_update(d1_update_raw),
        .serialize_req(d1_serialize_req)
    );

    regfile u_regfile (
        .clk,
        .rs1_addr(d1_d2_q.rs1),
        .rs2_addr(d1_d2_q.rs2),
        .rs1_data,
        .rs2_data,
        .write_enable(wb_gpr_write.valid),
        .write_addr(wb_gpr_write.addr),
        .write_data(wb_gpr_write.data)
    );

    d2_stage u_d2_stage (
        .in_packet(d1_d2_q),
        .rs1_data,
        .rs2_data,
        .out_packet(d2_packet)
    );

    mdu_issue_control u_mdu_issue_control (
        .ex_packet(d2_ex_q),
        .mem_packet(ex_mem_q),
        .mem_forward(mem_gpr_forward),
        .wb_packet(mem_wb_q),
        .wb_wait,
        .mdu_operands_ready
    );

    ex_stage u_ex_stage (
        .clk,
        .rst,
        .mdu_operands_ready,
        .advance(ex_stage_advance),
        .cancel(wb_redirect.valid),
        .in_packet(d2_ex_q),
        .mem_gpr_forward,
        .wb_gpr_forward(wb_gpr_write),
        .csr_committed_data,
        .mem_csr_forward,
        .wb_csr_forward(wb_csr_write),
        .out_packet(ex_packet),
        .redirect(ex_redirect),
        .pred_update(ex_update_raw),
        .serialize_req(ex_serialize_req),
        .execution_stall
    );

    csr_file u_csr_file (
        .clk,
        .rst,
        .read_addr(d2_ex_q.csr_addr),
        .read_data(csr_committed_data),
        .write_valid(wb_csr_write.valid),
        .write_addr(wb_csr_write.addr),
        .write_legal_data(wb_csr_write.data),
        .retire_valid,
        .trap_enter,
        .trap_pc,
        .trap_cause,
        .trap_tval,
        .mret_commit,
        .mtvec,
        .mepc
    );

    mem_stage u_mem_stage (
        .issue_enable(mem_issue_enable),
        .request_stall(mem_request_stall),
        .in_packet(ex_mem_q),
        .dmem_req_valid,
        .dmem_req_write,
        .dmem_req_addr,
        .dmem_req_wdata,
        .dmem_req_wstrb,
        .dmem_req_ready,
        .out_packet(mem_packet),
        .gpr_forward(mem_gpr_forward),
        .csr_forward(mem_csr_forward)
    );

    wb_stage u_wb_stage (
        .in_packet(mem_wb_q),
        .dmem_rsp_valid,
        .dmem_rsp_rdata,
        .dmem_rsp_ready,
        .wait_for_response(wb_wait),
        .gpr_write(wb_gpr_write),
        .csr_write(wb_csr_write),
        .commit_valid,
        .commit_pc,
        .commit_inst,
        .commit_rd,
        .commit_rd_we,
        .commit_rd_data,
        .commit_exception
    );

    trap_controller u_trap_controller (
        .commit_packet(mem_wb_q),
        .commit_valid,
        .mtvec,
        .mepc,
        .trap_enter,
        .mret_commit,
        .trap_pc,
        .trap_cause,
        .trap_tval,
        .retire_valid,
        .redirect(wb_redirect)
    );

    hazard_unit u_hazard_unit (
        .producer(d2_ex_q),
        .consumer(d1_d2_q),
        .load_use_stall
    );

    pipeline_ctrl u_pipeline_ctrl (
        .wb_redirect,
        .ex_redirect,
        .d1_redirect,
        .ex_serialize_req,
        .d1_serialize_req,
        .wb_wait,
        .mem_request_stall,
        .execution_stall,
        .load_use_stall,
        .redirect(selected_redirect),
        .serialize_start,
        .fetch_ready,
        .mem_issue_enable,
        .d1_flush,
        .actions(pipeline_actions)
    );

    // 流水级间寄存器：每个寄存器独立处理 ADVANCE/HOLD/CLEAR。
    always_ff @(posedge clk) begin
        if (rst)
            if_d1_q <= '0;
        else if (pipeline_actions.if_d1 == PIPE_CLEAR)
            if_d1_q.valid <= 1'b0;
        else if (pipeline_actions.if_d1 == PIPE_ADVANCE)
            if_d1_q <= fetch_packet;
    end

    always_ff @(posedge clk) begin
        if (rst)
            d1_d2_q <= '0;
        else if (pipeline_actions.d1_d2 == PIPE_CLEAR)
            d1_d2_q.valid <= 1'b0;
        else if (pipeline_actions.d1_d2 == PIPE_ADVANCE)
            d1_d2_q <= d1_packet;
    end

    always_ff @(posedge clk) begin
        if (rst)
            d2_ex_q <= '0;
        else if (pipeline_actions.d2_ex == PIPE_CLEAR)
            d2_ex_q.valid <= 1'b0;
        else if (pipeline_actions.d2_ex == PIPE_ADVANCE)
            d2_ex_q <= d2_packet;
        else begin
            // HOLD 时较老 WB 仍可能退休；保存其新值，避免旁路消失后使用过期操作数。
            // 已启动的 MDU 使用自己的请求快照，不受这里后续更新影响。
            if (wb_gpr_write.valid && d2_ex_q.uop.rs1_used &&
                (wb_gpr_write.addr == d2_ex_q.rs1))
                d2_ex_q.rs1_data <= wb_gpr_write.data;
            if (wb_gpr_write.valid && d2_ex_q.uop.rs2_used &&
                (wb_gpr_write.addr == d2_ex_q.rs2))
                d2_ex_q.rs2_data <= wb_gpr_write.data;
        end
    end

    always_ff @(posedge clk) begin
        if (rst)
            ex_mem_q <= '0;
        else if (pipeline_actions.ex_mem == PIPE_CLEAR)
            ex_mem_q.valid <= 1'b0;
        else if (pipeline_actions.ex_mem == PIPE_ADVANCE)
            ex_mem_q <= ex_packet;
    end

    always_ff @(posedge clk) begin
        if (rst)
            mem_wb_q <= '0;
        else if (pipeline_actions.mem_wb == PIPE_CLEAR)
            mem_wb_q.valid <= 1'b0;
        else if (pipeline_actions.mem_wb == PIPE_ADVANCE)
            mem_wb_q <= mem_packet;
    end
endmodule
