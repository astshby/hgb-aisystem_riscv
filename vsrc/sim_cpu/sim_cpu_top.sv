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
