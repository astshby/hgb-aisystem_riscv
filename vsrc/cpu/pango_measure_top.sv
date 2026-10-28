// Package: pango_measure_pkg
// Description: Packed, fully serialized diagnostic boundary layouts; MSB is shifted first.
package pango_measure_pkg;
    typedef struct packed {
        logic commit_valid;
        core_types_pkg::xlen_t commit_pc;
        logic [31:0] commit_inst;
        logic [4:0] commit_rd;
        logic commit_rd_we;
        core_types_pkg::xlen_t commit_rd_data;
        logic commit_exception;
        pipeline_pkg::retire_trace_t [1:0] trace;
        logic store_fire;
        core_types_pkg::xlen_t store_addr, store_data;
        logic [core_config_pkg::DBUS_BYTES-1:0] store_strb;
    } arch_observe_t;
    typedef struct packed {
        logic [2:0] irq;
        logic imem_req_ready, imem_rsp_valid;
        logic [63:0] imem_rsp_data;
        logic imem_rsp_error, imem_rsp_error_1;
        logic [1:0] mem_req_ready, mem_rsp_valid;
        scoreboard_pkg::memory_response_t [1:0] mem_response;
    } core_drive_t;
    typedef struct packed {
        logic imem_req_valid;
        core_types_pkg::xlen_t imem_req_addr;
        logic imem_rsp_ready;
        logic [1:0] mem_req_valid, mem_rsp_ready;
        scoreboard_pkg::memory_request_t [1:0] mem_request;
        logic fence_i_commit;
        logic [1:0] issue_fire;
        arch_observe_t arch;
    } core_observe_t;
    typedef struct packed {
        logic [2:0] irq;
        logic command_valid;
        cache_pkg::cache_maint_op_e command;
        axi_types_pkg::axi_rsp_t [1:0] cpu_response;
        axi_types_pkg::axi_req_t tcm_request;
    } hot_drive_t;
    typedef struct packed {
        logic command_ready, cache_busy, cache_fatal;
        cache_pkg::cache_maint_error_e cache_error;
        core_types_pkg::xlen_t cache_fault_addr;
        axi_types_pkg::axi_req_t [1:0] cpu_request;
        axi_types_pkg::axi_rsp_t tcm_response;
        arch_observe_t arch;
    } hot_observe_t;
    typedef struct packed {
        axi_types_pkg::axi_req_t external_request;
        axi_types_pkg::axi_rsp_t npu_response;
        logic flash_miso;
    } sys_drive_t;
    typedef struct packed {
        axi_types_pkg::axi_rsp_t external_response;
        axi_types_pkg::axi_req_t npu_request;
        logic flash_cs_n, flash_sck, flash_mosi;
    } sys_observe_t;
    typedef struct packed {
        logic ready;
        axi_types_pkg::axi_rsp_t response;
    } ddr_drive_t;
    typedef struct packed {
        logic [1:0] uart_rx;
        logic [2:0][31:0] gpio_in;
    } periph_drive_t;
    typedef struct packed {
        logic [1:0] uart_tx;
        logic [2:0][31:0] gpio_out, gpio_oe;
    } periph_observe_t;
endpackage

// Module: pango_measure_top
// Description: H0 core, H1 local-memory hot domain, H2 complete soft-SoC diagnostic boundaries.
// 四个端口钟用于独立物理诊断，不代表板上 PLL/DDR PHY；扫描壳资源须与 DUT 分列。
module pango_measure_top #(
    parameter int unsigned MEASURE_LAYER = 0,
    parameter int unsigned DDR_BYTES = 512 * 1024 * 1024,
    parameter int unsigned FLASH_BYTES = 16 * 1024 * 1024,
    parameter int unsigned NPU_BYTES = 64 * 1024,
    parameter logic [31:0] CORE_CLOCK_HZ = 100000000,
    parameter logic [31:0] SYS_CLOCK_HZ = 80000000,
    parameter logic [31:0] DDR_CLOCK_HZ = 125000000,
    parameter logic [31:0] PERIPH_CLOCK_HZ = 25000000
) (
    input logic clk_core, clk_sys, clk_ddr, clk_periph, reset_async,
    input logic [3:0] scan_shift, scan_update, scan_capture, scan_din,
    output logic [3:0] scan_dout
);
    import pango_measure_pkg::*;
    // H2 的 Core 域没有外部功能输入；保留一位回读标记，仅属于测量壳。
    localparam int CORE_INPUT_BITS = MEASURE_LAYER == 0 ? $bits(core_drive_t) :
        (MEASURE_LAYER == 1 ? $bits(hot_drive_t) : 1);
    localparam int CORE_OUTPUT_BITS = MEASURE_LAYER == 0 ? $bits(core_observe_t) :
        (MEASURE_LAYER == 1 ? $bits(hot_observe_t) : $bits(arch_observe_t) + 1);
    localparam int SYS_INPUT_BITS = MEASURE_LAYER == 2 ? $bits(sys_drive_t) : 0;
    localparam int SYS_OUTPUT_BITS = MEASURE_LAYER == 2 ? $bits(sys_observe_t) : 0;
    localparam int DDR_INPUT_BITS = MEASURE_LAYER == 2 ? $bits(ddr_drive_t) : 0;
    localparam int DDR_OUTPUT_BITS = MEASURE_LAYER == 2 ? $bits(axi_types_pkg::axi_req_t) : 0;
    localparam int PERIPH_INPUT_BITS = MEASURE_LAYER == 2 ? $bits(periph_drive_t) : 0;
    localparam int PERIPH_OUTPUT_BITS = MEASURE_LAYER == 2 ? $bits(periph_observe_t) : 0;
    logic rst_core, rst_sys, rst_ddr, rst_periph;
    logic [CORE_INPUT_BITS-1:0] core_drive;
    logic [CORE_OUTPUT_BITS-1:0] core_observe;
    arch_observe_t arch;
    pipeline_pkg::retire_trace_t commit_trace [2];
    assign arch.trace[0] = commit_trace[0];
    assign arch.trace[1] = commit_trace[1];
    soc_reset_controller u_reset (.reset_async, .clk_core, .clk_sys, .clk_ddr, .clk_periph,
        .rst_core, .rst_sys, .rst_ddr, .rst_periph, .rst_sys_local());
    if (1) begin : g_scan_core
        pango_measure_scan #(.INPUT_BITS(CORE_INPUT_BITS), .OUTPUT_BITS(CORE_OUTPUT_BITS)) u_scan (
            .clk(clk_core), .rst(rst_core), .shift(scan_shift[0]), .update(scan_update[0]),
            .capture(scan_capture[0]), .serial_in(scan_din[0]), .serial_out(scan_dout[0]),
            .drive(core_drive), .observe(core_observe));
    end

    if (MEASURE_LAYER == 0) begin : g_core
        core_drive_t inputs;
        core_observe_t outputs;
        scoreboard_pkg::memory_request_t request [2];
        scoreboard_pkg::memory_response_t response [2];
        assign inputs = core_drive;
        assign core_observe = outputs;
        assign outputs.arch = arch;
        for (genvar p = 0; p < 2; p++) begin : g_port
            assign response[p] = inputs.mem_response[p];
            assign outputs.mem_request[p] = request[p];
        end
        assign arch.store_fire = outputs.mem_req_valid[0] && inputs.mem_req_ready[0] && request[0].write;
        assign arch.store_addr = request[0].address;
        assign arch.store_data = request[0].wdata;
        assign arch.store_strb = request[0].wstrb;
        scoreboard_core u_core (
            .clk(clk_core), .rst(rst_core), .irq_software(inputs.irq[0]),
            .irq_timer(inputs.irq[1]), .irq_external(inputs.irq[2]),
            .imem_req_valid(outputs.imem_req_valid), .imem_req_addr(outputs.imem_req_addr),
            .imem_req_ready(inputs.imem_req_ready), .imem_rsp_valid(inputs.imem_rsp_valid),
            .imem_rsp_data(inputs.imem_rsp_data), .imem_rsp_error(inputs.imem_rsp_error),
            .imem_rsp_error_1(inputs.imem_rsp_error_1), .imem_rsp_ready(outputs.imem_rsp_ready),
            .mem_req_valid(outputs.mem_req_valid), .mem_req_ready(inputs.mem_req_ready), .mem_request(request),
            .mem_rsp_valid(inputs.mem_rsp_valid), .mem_rsp_ready(outputs.mem_rsp_ready), .mem_response(response),
            .commit_valid(arch.commit_valid), .commit_pc(arch.commit_pc), .commit_inst(arch.commit_inst),
            .commit_rd(arch.commit_rd), .commit_rd_we(arch.commit_rd_we), .commit_rd_data(arch.commit_rd_data),
            .commit_exception(arch.commit_exception), .commit_trace,
            .fence_i_commit(outputs.fence_i_commit), .issue_fire(outputs.issue_fire));
    end else if (MEASURE_LAYER == 1) begin : g_hot
        hot_drive_t inputs;
        hot_observe_t outputs;
        axi_types_pkg::axi_req_t request [2];
        axi_types_pkg::axi_rsp_t response [2];
        assign inputs = core_drive;
        assign core_observe = outputs;
        assign outputs.arch = arch;
        for (genvar p = 0; p < 2; p++) begin : g_port
            assign response[p] = inputs.cpu_response[p];
            assign outputs.cpu_request[p] = request[p];
        end
        pango_measure_hot #(.DDR_BYTES(DDR_BYTES)) u_hot (
            .clk_core, .rst_core, .device_pending(inputs.irq),
            .cache_command_valid(inputs.command_valid), .cache_command(inputs.command),
            .cache_command_ready(outputs.command_ready), .cache_busy(outputs.cache_busy),
            .cache_fatal(outputs.cache_fatal), .cache_error(outputs.cache_error), .cache_fault_addr(outputs.cache_fault_addr),
            .local_axi(request), .local_responses(response), .system_tcm_req(inputs.tcm_request),
            .system_tcm_rsp(outputs.tcm_response), .commit_valid(arch.commit_valid),
            .commit_pc(arch.commit_pc), .commit_inst(arch.commit_inst), .commit_rd(arch.commit_rd),
            .commit_rd_we(arch.commit_rd_we), .commit_rd_data(arch.commit_rd_data),
            .commit_exception(arch.commit_exception), .commit_trace, .dmem_store_fire(arch.store_fire),
            .dmem_store_addr(arch.store_addr), .dmem_store_data(arch.store_data), .dmem_store_strb(arch.store_strb));
    end else begin : g_soc
        sys_drive_t sys_drive;
        sys_observe_t sys_observe;
        ddr_drive_t ddr_drive;
        axi_types_pkg::axi_req_t ddr_observe;
        periph_drive_t periph_drive;
        periph_observe_t periph_observe;
        logic [31:0] gpio_in [3], gpio_out [3], gpio_oe [3];
        assign core_observe = {core_drive[0], arch};
        for (genvar p = 0; p < 3; p++) begin : g_gpio
            assign gpio_in[p] = periph_drive.gpio_in[p];
            assign periph_observe.gpio_out[p] = gpio_out[p];
            assign periph_observe.gpio_oe[p] = gpio_oe[p];
        end
        // 每域仅采样本域边界；DDR ready 由 DDR 域保持寄存器产生，经原 SoC 同步器进入其他域。
        if (1) begin : g_scan_sys
            pango_measure_scan #(.INPUT_BITS(SYS_INPUT_BITS), .OUTPUT_BITS(SYS_OUTPUT_BITS)) u_scan (
                .clk(clk_sys), .rst(rst_sys), .shift(scan_shift[1]), .update(scan_update[1]),
                .capture(scan_capture[1]), .serial_in(scan_din[1]), .serial_out(scan_dout[1]),
                .drive(sys_drive), .observe(sys_observe));
        end
        if (1) begin : g_scan_ddr
            pango_measure_scan #(.INPUT_BITS(DDR_INPUT_BITS), .OUTPUT_BITS(DDR_OUTPUT_BITS)) u_scan (
                .clk(clk_ddr), .rst(rst_ddr), .shift(scan_shift[2]), .update(scan_update[2]),
                .capture(scan_capture[2]), .serial_in(scan_din[2]), .serial_out(scan_dout[2]),
                .drive(ddr_drive), .observe(ddr_observe));
        end
        if (1) begin : g_scan_periph
            pango_measure_scan #(.INPUT_BITS(PERIPH_INPUT_BITS), .OUTPUT_BITS(PERIPH_OUTPUT_BITS)) u_scan (
                .clk(clk_periph), .rst(rst_periph), .shift(scan_shift[3]), .update(scan_update[3]),
                .capture(scan_capture[3]), .serial_in(scan_din[3]), .serial_out(scan_dout[3]),
                .drive(periph_drive), .observe(periph_observe));
        end
        soc_system #(.DDR_BYTES(DDR_BYTES), .FLASH_BYTES(FLASH_BYTES), .NPU_BYTES(NPU_BYTES),
            .SOC_PROFILE(soc_config_pkg::SOC_PROFILE_FULL), .CLOCK_HZ(CORE_CLOCK_HZ), .CLOCK_INFO_ENABLE(1),
            .CORE_CLOCK_HZ(CORE_CLOCK_HZ), .SYS_CLOCK_HZ(SYS_CLOCK_HZ), .DDR_CLOCK_HZ(DDR_CLOCK_HZ),
            .PERIPH_CLOCK_HZ(PERIPH_CLOCK_HZ), .UART_DIVISOR((PERIPH_CLOCK_HZ + 57600) / 115200)) u_soc (
            .clk_core, .clk_sys, .clk_ddr, .clk_periph, .reset_async, .ddr_ready(ddr_drive.ready),
            .uart_rx(periph_drive.uart_rx), .uart_tx(periph_observe.uart_tx), .gpio_in, .gpio_out, .gpio_oe,
            .flash_cs_n(sys_observe.flash_cs_n), .flash_sck(sys_observe.flash_sck),
            .flash_mosi(sys_observe.flash_mosi), .flash_miso(sys_drive.flash_miso),
            .ddr_req(ddr_observe), .ddr_rsp(ddr_drive.response),
            .external_req(sys_drive.external_request), .external_rsp(sys_observe.external_response),
            .npu_req(sys_observe.npu_request), .npu_rsp(sys_drive.npu_response),
            .commit_valid(arch.commit_valid), .commit_pc(arch.commit_pc), .commit_inst(arch.commit_inst),
            .commit_rd(arch.commit_rd), .commit_rd_we(arch.commit_rd_we), .commit_rd_data(arch.commit_rd_data),
            .commit_exception(arch.commit_exception), .commit_trace, .dmem_store_fire(arch.store_fire),
            .dmem_store_addr(arch.store_addr), .dmem_store_data(arch.store_data), .dmem_store_strb(arch.store_strb));
    end
    if (MEASURE_LAYER != 2) begin : g_unused_scan
        assign scan_dout[3:1] = '0;
    end
    initial begin
        assert (MEASURE_LAYER <= 2 && DDR_BYTES != 0 && FLASH_BYTES != 0 && NPU_BYTES != 0)
            else $fatal(1, "invalid measurement layer/capacity");
    end
endmodule
