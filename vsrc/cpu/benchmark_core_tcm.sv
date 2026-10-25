// Module: benchmark_core_tcm
// Description: Runnable core/production-TCM benchmark with a local reset trampoline.
module benchmark_core_tcm #(
    parameter ITCM_INIT_FILE = "",
    parameter DTCM_INIT_FILE = ""
) (
    input logic clk_core, rst_core,
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
    import axi_types_pkg::*;
    import bus_types_pkg::*;
    axi_req_t local_axi [2];
    axi_rsp_t local_responses [2];

    // 复用生产热域接线、双 bank RAM 和访问延迟；两个本地 ROM 端口只供复位取指。
    // 系统 TCM 口及 Cache 块口被常量禁用，不接理想化取指/数据响应模型。
    pango_measure_hot #(.DDR_BYTES(0),.ICACHE_ENABLE(0),.DCACHE_ENABLE(0),
        .ITCM_INIT_FILE(ITCM_INIT_FILE),.DTCM_INIT_FILE(DTCM_INIT_FILE)) u_hot (
        .clk_core,.rst_core,.device_pending('0),.cache_command_valid(1'b0),
        .cache_command(cache_pkg::CACHE_CLEAN),.cache_command_ready(),.cache_busy(),.cache_fatal(),
        .cache_error(),.cache_fault_addr(),.local_axi,.local_responses,
        .system_tcm_req('0),.system_tcm_rsp(),
        .commit_valid,.commit_pc,.commit_inst,.commit_rd,.commit_rd_we,.commit_rd_data,
        .commit_exception,.commit_trace,.dmem_store_fire,.dmem_store_addr,.dmem_store_data,.dmem_store_strb);

    for (genvar m=0; m<2; m++) begin : g_boot
        logic req_valid, req_ready, rsp_valid, rsp_ready;
        bus_req_t request;
        bus_rsp_t response;
        axi_bus_target #(.READ_ONLY(1)) u_target (.clk(clk_core),.rst(rst_core),
            .axi_req(local_axi[m]),.axi_rsp(local_responses[m]),
            .req_valid,.req_ready,.request,.rsp_valid,.rsp_ready,.response);
        boot_rom u_rom (.clk(clk_core),.rst(rst_core),
            .req_valid,.req_ready,.request,.rsp_valid,.rsp_ready,.response);
    end
endmodule
