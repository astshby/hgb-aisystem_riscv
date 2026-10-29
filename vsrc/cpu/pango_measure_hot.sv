// Module: pango_measure_hot
// Description: Measurement-only composition of the unchanged soc_system core-domain modules.
// 与 soc_system 的 Core/维护/适配/TCM/AXI 接线逐项对应；不含任何跨域 FIFO。
module pango_measure_hot #(
    parameter int unsigned DDR_BYTES = 512 * 1024 * 1024,
    parameter bit ICACHE_ENABLE = 1,
    parameter int unsigned ICACHE_BYTES = 4096,
    parameter int unsigned ICACHE_LINE_BYTES = 32,
    parameter bit DCACHE_ENABLE = 1,
    parameter int unsigned DCACHE_BYTES = 4096,
    parameter int unsigned DCACHE_LINE_BYTES = 32,
    parameter ITCM_INIT_FILE = "",
    parameter DTCM_INIT_FILE = ""
) (
    input logic clk_core, rst_core,
    input logic [2:0] device_pending,
    input logic cache_command_valid,
    input cache_pkg::cache_maint_op_e cache_command,
    output logic cache_command_ready, cache_busy, cache_fatal,
    output cache_pkg::cache_maint_error_e cache_error,
    output core_types_pkg::xlen_t cache_fault_addr,
    output axi_types_pkg::axi_req_t local_axi [2],
    input axi_types_pkg::axi_rsp_t local_responses [2],
    input axi_types_pkg::axi_req_t system_tcm_req,
    output axi_types_pkg::axi_rsp_t system_tcm_rsp,
    output logic commit_valid,
    output core_types_pkg::xlen_t commit_pc,
    output logic [31:0] commit_inst,
    output logic [4:0] commit_rd,
    output logic commit_rd_we,
    output core_types_pkg::xlen_t commit_rd_data,
    output logic commit_exception,
    output pipeline_pkg::retire_trace_t commit_trace [2],
    output logic dmem_store_fire,
    output core_types_pkg::xlen_t dmem_store_addr, dmem_store_data,
    output logic [core_config_pkg::DBUS_BYTES-1:0] dmem_store_strb
);
    import core_config_pkg::*;
    import core_types_pkg::*;
    import bus_types_pkg::*;
    import block_types_pkg::*;
    import axi_types_pkg::*;
    logic [2:0] core_pending;
    (* ASYNC_REG = "TRUE", PAP_ASYNC_REG = 1, syn_allow_retiming = 0 *) logic [2:0] irq_sync1_q, irq_sync2_q;
    always_ff @(posedge clk_core) begin
        if (rst_core) begin irq_sync1_q <= 0; irq_sync2_q <= 0; end
        else begin irq_sync1_q <= device_pending; irq_sync2_q <= irq_sync1_q; end
    end
    irq_register u_irq (.clk(clk_core),.rst(rst_core),.device_pending(irq_sync2_q),.core_pending);
    logic imem_req_valid, imem_req_ready, imem_rsp_valid, imem_rsp_ready, imem_rsp_error, imem_rsp_error_1;
    xlen_t imem_req_addr;
    logic [63:0] imem_rsp_data;
    logic [1:0] data_req_valid, data_req_ready, data_rsp_valid, data_rsp_ready;
    scoreboard_pkg::memory_request_t tagged_request [2];
    scoreboard_pkg::memory_response_t tagged_response [2];
    logic fence_i_commit;
    scoreboard_core u_core (
        .clk(clk_core),.rst(rst_core),.irq_software(core_pending[0]),.irq_timer(core_pending[1]),.irq_external(core_pending[2]),
        .imem_req_valid,.imem_req_ready,.imem_req_addr,.imem_rsp_valid,.imem_rsp_ready,
        .imem_rsp_data,.imem_rsp_error,.imem_rsp_error_1,
        .mem_req_valid(data_req_valid),.mem_req_ready(data_req_ready),.mem_request(tagged_request),
        .mem_rsp_valid(data_rsp_valid),.mem_rsp_ready(data_rsp_ready),.mem_response(tagged_response),
        .commit_valid,.commit_pc,.commit_inst,.commit_rd,.commit_rd_we,.commit_rd_data,
        .commit_exception,.commit_trace,.fence_i_commit,.issue_fire());
    assign dmem_store_fire = data_req_valid[0] && data_req_ready[0] && tagged_request[0].write;
    assign dmem_store_addr = tagged_request[0].address;
    assign dmem_store_data = tagged_request[0].wdata;
    assign dmem_store_strb = tagged_request[0].wstrb;

    logic fetch_block;
    cache_pkg::cache_maint_op_e maint_op;
    cache_pkg::cache_maint_error_e maint_error, cache_fault_code;
    xlen_t maint_fault_addr, backend_fault_addr;
    logic maint_req_valid, maint_req_ready, maint_rsp_valid, maint_rsp_ready, cache_fault_valid;
    cache_maintenance_controller #(.ACTIVE(DCACHE_ENABLE && DDR_BYTES != 0)) u_maintenance (
        .clk(clk_core),.rst(rst_core),.fence_i_commit,.command_valid(cache_command_valid),
        .command_ready(cache_command_ready),.command(cache_command),.busy(cache_busy),.fetch_block,.fatal(cache_fatal),
        .error(cache_error),.fault_addr(cache_fault_addr),.maint_req_valid,.maint_req_ready,.maint_op,
        .maint_rsp_valid,.maint_rsp_ready,.maint_error,.maint_fault_addr,.cache_fault_valid,
        .cache_fault_code,.cache_fault_addr(backend_fault_addr));
    logic [1:0] m_req_valid, m_req_ready, m_rsp_valid, m_rsp_ready;
    bus_req_t m_request [2];
    bus_rsp_t m_response [2];
    logic [1:0] cache_rd_cmd_valid, cache_rd_cmd_ready, cache_rd_valid, cache_rd_ready;
    logic [1:0] cache_wr_cmd_valid, cache_wr_cmd_ready, cache_wr_valid, cache_wr_ready, cache_wr_rsp_valid, cache_wr_rsp_ready;
    block_cmd_t cache_rd_cmd [2], cache_wr_cmd [2];
    block_r_t cache_rd_data [2];
    block_w_t cache_wr_data [2];
    block_b_t cache_wr_rsp [2];
    logic [2:0] t_req_valid [2], t_req_ready [2], t_rsp_valid [2], t_rsp_ready [2];
    bus_req_t t_request [2][3];
    logic [63:0] t_rsp_data [2][3];
    cpu_memory_adapter #(.DDR_BYTES(DDR_BYTES),.ICACHE_ENABLE(ICACHE_ENABLE),.ICACHE_BYTES(ICACHE_BYTES),
        .ICACHE_LINE_BYTES(ICACHE_LINE_BYTES),.DCACHE_ENABLE(DCACHE_ENABLE),.DCACHE_BYTES(DCACHE_BYTES),
        .DCACHE_LINE_BYTES(DCACHE_LINE_BYTES),.CACHE_BLOCK_ENABLE(1)) u_memory (
        .clk(clk_core),.rst(rst_core),.fence_i_commit,.fetch_block,.imem_req_valid,.imem_req_ready,.imem_req_addr,
        .imem_rsp_valid,.imem_rsp_ready,.imem_rsp_data,.imem_rsp_error,.imem_rsp_error_1,
        .data_req_valid,.data_req_ready,.data_request(tagged_request),.data_rsp_valid,.data_rsp_ready,.data_response(tagged_response),
        .m_req_valid,.m_req_ready,.m_request,.m_rsp_valid,.m_rsp_ready,.m_response,
        .t_req_valid,.t_req_ready,.t_request,.t_rsp_valid,.t_rsp_ready,.t_rsp_data,
        .maint_req_valid,.maint_req_ready,.maint_op,.maint_rsp_valid,.maint_rsp_ready,.maint_error,.maint_fault_addr,
        .cache_fault_valid,.cache_fault_code,.cache_fault_addr(backend_fault_addr),
        .cache_rd_cmd_valid,.cache_rd_cmd_ready,.cache_rd_cmd,.cache_rd_valid,.cache_rd_ready,.cache_rd_data,
        .cache_wr_cmd_valid,.cache_wr_cmd_ready,.cache_wr_cmd,.cache_wr_valid,.cache_wr_ready,.cache_wr_data,
        .cache_wr_rsp_valid,.cache_wr_rsp_ready,.cache_wr_rsp);
    for (genvar m=0;m<2;m++) begin : g_cpu_master
        cache_axi_adapter u_adapter (.clk(clk_core),.rst(rst_core),
            .req_valid(m_req_valid[m]),.req_ready(m_req_ready[m]),.request(m_request[m]),
            .rsp_valid(m_rsp_valid[m]),.rsp_ready(m_rsp_ready[m]),.response(m_response[m]),
            .rd_cmd_valid(cache_rd_cmd_valid[m]),.rd_cmd_ready(cache_rd_cmd_ready[m]),.rd_cmd(cache_rd_cmd[m]),
            .rd_valid(cache_rd_valid[m]),.rd_ready(cache_rd_ready[m]),.rd_data(cache_rd_data[m]),
            .wr_cmd_valid(cache_wr_cmd_valid[m]),.wr_cmd_ready(cache_wr_cmd_ready[m]),.wr_cmd(cache_wr_cmd[m]),
            .wr_valid(cache_wr_valid[m]),.wr_ready(cache_wr_ready[m]),.wr_data(cache_wr_data[m]),
            .wr_rsp_valid(cache_wr_rsp_valid[m]),.wr_rsp_ready(cache_wr_rsp_ready[m]),.wr_rsp(cache_wr_rsp[m]),
            .axi_req(local_axi[m]),.axi_rsp(local_responses[m]));
    end
    logic [1:0] system_req_valid, system_req_ready, system_rsp_valid, system_rsp_ready;
    bus_req_t system_request [2];
    logic [63:0] system_rsp_data [2];
    tcm_system_target u_tcm_target (.clk(clk_core),.rst(rst_core),.axi_req(system_tcm_req),.axi_rsp(system_tcm_rsp),
        .req_valid(system_req_valid),.req_ready(system_req_ready),.request(system_request),
        .rsp_valid(system_rsp_valid),.rsp_ready(system_rsp_ready),.rsp_data(system_rsp_data));
    for (genvar b=0;b<2;b++) begin : g_tcm
        logic [3:0] req_v, req_r, rsp_v, rsp_r;
        bus_req_t requests [4];
        logic [63:0] responses [4];
        assign req_v = {system_req_valid[b],t_req_valid[b]};
        assign {system_req_ready[b],t_req_ready[b]} = req_r;
        assign {system_rsp_valid[b],t_rsp_valid[b]} = rsp_v;
        assign rsp_r = {system_rsp_ready[b],t_rsp_ready[b]};
        assign requests[3] = system_request[b];
        assign system_rsp_data[b] = responses[3];
        for (genvar p=0;p<3;p++) begin : g_local
            assign requests[p] = t_request[b][p];
            assign t_rsp_data[b][p] = responses[p];
        end
        tcm_bram #(.BYTES(65536),.INSTRUCTION(b==0),.INIT_FILE(b==0 ? ITCM_INIT_FILE : DTCM_INIT_FILE)) u_ram (
            .clk(clk_core),.rst(rst_core),.req_valid(req_v),.req_ready(req_r),.request(requests),
            .rsp_valid(rsp_v),.rsp_ready(rsp_r),.rsp_data(responses));
    end
endmodule
