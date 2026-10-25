// Module: sim_cpu_top
// Description: Simulation-only wrapper around the portable core and memories.
module sim_cpu_top #(
    parameter int unsigned IMEM_DEPTH_WORDS = 4096,
    parameter int unsigned DMEM_DEPTH_WORDS = 4096
) (
    input  logic                              clk,
    input  logic                              rst,
    output logic                              commit_valid,
    output logic [core_config_pkg::XLEN-1:0]  commit_pc,
    output logic [31:0]                       commit_inst,
    output logic [core_config_pkg::GPR_ADDR_W-1:0] commit_rd,
    output logic                              commit_rd_we,
    output logic [core_config_pkg::XLEN-1:0]  commit_rd_data,
    output logic                              commit_exception,
    output pipeline_pkg::retire_trace_t        commit_trace [2],
    output logic                              dmem_store_fire,
    output logic [core_config_pkg::XLEN-1:0]  dmem_store_addr,
    output logic [core_config_pkg::XLEN-1:0]  dmem_store_data,
    output logic [core_config_pkg::DBUS_BYTES-1:0] dmem_store_strb
);
    import core_config_pkg::*;
    import core_types_pkg::*;

    logic imem_req_valid;
    logic [XLEN-1:0] imem_req_addr;
    logic imem_req_ready;
    logic imem_rsp_valid;
    logic [FETCH_DATA_W-1:0] imem_rsp_data;
    logic imem_rsp_error, imem_rsp_error_1;
    logic imem_rsp_ready;
    logic dmem_req_valid;
    logic dmem_req_write;
    logic [XLEN-1:0] dmem_req_addr;
    logic [XLEN-1:0] dmem_req_wdata;
    logic [DBUS_BYTES-1:0] dmem_req_wstrb;
    logic dmem_req_ready;
    logic dmem_rsp_valid;
    logic [XLEN-1:0] dmem_rsp_rdata;
    logic dmem_rsp_ready;
    // 被动导出已握手的 Store；不改变 DMem ready/valid，也不解释测试协议。
    assign dmem_store_fire = dmem_req_valid && dmem_req_ready && dmem_req_write;
    assign dmem_store_addr = dmem_req_addr;
    assign dmem_store_data = dmem_req_wdata;
    assign dmem_store_strb = dmem_req_wstrb;

    // 仅仿真观察：统一两个后端的真实 MDU/分支事件，不改变生产 Core 端口或握手。
    pipeline_pkg::d2_ex_t observed_mdu_packet, observed_branch_packet;
    pipeline_pkg::retire_completion_t observed_mdu_completion;
    logic observed_mdu_complete_valid, observed_mdu_complete_ready, observed_mdu_wait;
    logic observed_ordinary_mdu, observed_serial_pending;
    logic observed_branch_fire, observed_branch_taken, observed_branch_wrong;
    core_types_pkg::xlen_t observed_branch_target;
`ifdef CORE_SCOREBOARD
    assign observed_mdu_packet = u_core.scheduled[u_core.mdu_lane];
    assign observed_mdu_completion = u_core.completion_input[2];
    assign observed_mdu_complete_valid = u_core.completion_input_valid[2];
    assign observed_mdu_complete_ready = u_core.completion_input_ready[2];
    assign observed_mdu_wait = !u_core.mdu_req_ready;
    assign observed_ordinary_mdu =
        (u_core.completion_input_valid[0] && u_core.scheduled[0].uop.fu == core_types_pkg::FU_MULDIV) ||
        (u_core.completion_input_valid[1] && u_core.scheduled[1].uop.fu == core_types_pkg::FU_MULDIV);
    assign observed_serial_pending =
        (u_core.decode_q[0].valid && (u_core.decode_q[0].exc.valid ||
         u_core.decode_q[0].uop.sys_op != core_types_pkg::SYS_NONE)) ||
        (u_core.decode_q[1].valid && (u_core.decode_q[1].exc.valid ||
         u_core.decode_q[1].uop.sys_op != core_types_pkg::SYS_NONE)) ||
        (u_core.raw_scheduled[0].valid && (u_core.raw_scheduled[0].exc.valid ||
         u_core.raw_scheduled[0].uop.sys_op != core_types_pkg::SYS_NONE));
    assign observed_branch_packet = u_core.raw_scheduled[u_core.mark_reported[0] ? 0 : 1];
    assign observed_branch_fire = u_core.branch_resolved;
    assign observed_branch_taken = u_core.branch_taken[u_core.mark_reported[0] ? 0 : 1];
    assign observed_branch_target = u_core.branch_target[u_core.mark_reported[0] ? 0 : 1];
    assign observed_branch_wrong = u_core.branch_wrong;
`else
    assign observed_mdu_packet = u_core.d2_ex_q;
    assign observed_mdu_completion = u_core.mdu_completion;
    assign observed_mdu_complete_valid = u_core.mdu_complete_valid;
    assign observed_mdu_complete_ready = u_core.mdu_complete_ready;
    assign observed_mdu_wait = u_core.execution_stall;
    assign observed_ordinary_mdu =
        (u_core.ex_mem_q.valid && u_core.ex_mem_q.uop.fu == core_types_pkg::FU_MULDIV) ||
        (u_core.mem_wb_q.valid && u_core.mem_wb_q.uop.fu == core_types_pkg::FU_MULDIV);
    assign observed_serial_pending = u_core.d1_serialize_req || u_core.d1_d2_q.exc.valid ||
                                     u_core.d2_ex_q.exc.valid;
    assign observed_branch_packet = u_core.d2_ex_q;
    assign observed_branch_fire = u_core.ex_stage_advance &&
                                  u_core.d2_ex_q.uop.branch_op != core_types_pkg::BR_NONE;
    assign observed_branch_taken = u_core.ex_packet.branch.taken;
    assign observed_branch_target = u_core.ex_packet.branch.target;
    assign observed_branch_wrong = u_core.ex_redirect.valid;
`endif

`ifdef CORE_SCOREBOARD
    logic [1:0] tagged_req_valid, tagged_req_ready, tagged_rsp_valid, tagged_rsp_ready;
    scoreboard_pkg::memory_request_t tagged_request [2];
    scoreboard_pkg::memory_response_t tagged_response [2];
    logic store_lane;
    assign store_lane = !(tagged_req_valid[0] && tagged_request[0].write);
    assign dmem_req_valid = tagged_req_valid[store_lane];
    assign dmem_req_ready = tagged_req_ready[store_lane];
    assign dmem_req_write = tagged_request[store_lane].write;
    assign dmem_req_addr = tagged_request[store_lane].address;
    assign dmem_req_wdata = tagged_request[store_lane].wdata;
    assign dmem_req_wstrb = tagged_request[store_lane].wstrb;
    scoreboard_core u_core (
        .clk, .rst, .irq_software(1'b0), .irq_timer(1'b0), .irq_external(1'b0),
        .imem_req_valid, .imem_req_addr, .imem_req_ready, .imem_rsp_valid, .imem_rsp_data,
        .imem_rsp_error, .imem_rsp_error_1, .imem_rsp_ready,
        .mem_req_valid(tagged_req_valid), .mem_req_ready(tagged_req_ready), .mem_request(tagged_request),
        .mem_rsp_valid(tagged_rsp_valid), .mem_rsp_ready(tagged_rsp_ready), .mem_response(tagged_response),
        .commit_valid, .commit_pc, .commit_inst, .commit_rd, .commit_rd_we, .commit_rd_data,
        .commit_exception, .commit_trace, .fence_i_commit(), .issue_fire()
    );
`else
    // .name是sv特性，可以用 .* 替代（原理：扫描已有同名信号并直接连接，没有的不连接）
    core u_core (
        .irq_software(1'b0), .irq_timer(1'b0), .irq_external(1'b0),
        .clk,
        .rst,
        .imem_req_valid,
        .imem_req_addr,
        .imem_req_ready,
        .imem_rsp_valid,
        .imem_rsp_data,
        .imem_rsp_error, .imem_rsp_error_1,
        .imem_rsp_ready,
        .dmem_req_valid,
        .dmem_req_write,
        .dmem_req_size(),
        .dmem_req_addr,
        .dmem_req_wdata,
        .dmem_req_wstrb,
        .dmem_req_ready,
        .dmem_rsp_valid,
        .dmem_rsp_rdata,
        .dmem_rsp_error(1'b0),
        .dmem_rsp_ready,
        .commit_valid,
        .commit_pc,
        .commit_inst,
        .commit_rd,
        .commit_rd_we,
        .commit_rd_data,
        .commit_exception, .commit_trace,
        .fence_i_commit()
    );
    // 等价于 core u_core ( .* );
`endif

    sim_imem #(
        .DEPTH_WORDS(IMEM_DEPTH_WORDS)
    ) u_imem (
        .clk,
        .rst,
        .req_valid(imem_req_valid),
        .req_addr(imem_req_addr),
        .req_ready(imem_req_ready),
        .rsp_valid(imem_rsp_valid),
        .rsp_data(imem_rsp_data),
        .rsp_error(imem_rsp_error), .rsp_error_1(imem_rsp_error_1),
        .rsp_ready(imem_rsp_ready)
    );

`ifdef CORE_SCOREBOARD
    sim_dmem_dual #(.DEPTH_WORDS(DMEM_DEPTH_WORDS)) u_dmem (
        .clk, .rst, .req_valid(tagged_req_valid), .req_ready(tagged_req_ready), .request(tagged_request),
        .rsp_valid(tagged_rsp_valid), .rsp_ready(tagged_rsp_ready), .response(tagged_response)
    );
`else
    sim_dmem #(
        .DEPTH_WORDS(DMEM_DEPTH_WORDS)
    ) u_dmem (
        .clk,
        .rst,
        .req_valid(dmem_req_valid),
        .req_write(dmem_req_write),
        .req_addr(dmem_req_addr),
        .req_wdata(dmem_req_wdata),
        .req_wstrb(dmem_req_wstrb),
        .req_ready(dmem_req_ready),
        .rsp_valid(dmem_rsp_valid),
        .rsp_rdata(dmem_rsp_rdata),
        .rsp_ready(dmem_rsp_ready)
    );
`endif
endmodule
