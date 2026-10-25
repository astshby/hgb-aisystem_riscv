// Module: pango_benchmark_tcm_top
// Description: Autonomous TCM benchmark physical top for core-only or on-chip SoC configurations.
module pango_benchmark_tcm_top #(
    parameter bit ONCHIP_SOC = 0,
    parameter ITCM_INIT_FILE = "",
    parameter DTCM_INIT_FILE = "",
    parameter int CORE_CLOCK_HZ = 100000000,
    parameter int SYS_CLOCK_HZ = 80000000,
    parameter int PERIPH_CLOCK_HZ = 25000000
) (
    input logic clk_core, clk_sys, clk_periph, reset_async,
    input logic uart_rxd,
    output logic uart_txd,
    input logic capture, shift,
    output logic serial_out
);
    import core_config_pkg::*;
    import core_types_pkg::*;
    logic rst_core;
    soc_reset_controller u_reset (.reset_async,.clk_core,.clk_sys(1'b0),.clk_ddr(1'b0),.clk_periph(1'b0),
        .rst_core,.rst_sys(),.rst_ddr(),.rst_periph());
    logic commit_valid, commit_rd_we, commit_exception, dmem_store_fire;
    xlen_t commit_pc, commit_rd_data, dmem_store_addr, dmem_store_data;
    logic [31:0] commit_inst;
    logic [4:0] commit_rd;
    logic [DBUS_BYTES-1:0] dmem_store_strb;
    pipeline_pkg::retire_trace_t commit_trace [2];
    if (ONCHIP_SOC) begin : g_soc
        logic [1:0] uart_tx;
        logic [31:0] gpio_in [3];
        for (genvar g=0; g<3; g++) begin : g_gpio
            assign gpio_in[g]='0;
        end
        assign uart_txd=uart_tx[0];
        soc_system #(.ITCM_INIT_FILE(ITCM_INIT_FILE),.DTCM_INIT_FILE(DTCM_INIT_FILE),
            .DDR_BYTES(0),.ICACHE_ENABLE(0),.DCACHE_ENABLE(0),.CLOCK_HZ(125000000),
            .CLOCK_INFO_ENABLE(1),.CORE_CLOCK_HZ(CORE_CLOCK_HZ),.SYS_CLOCK_HZ(SYS_CLOCK_HZ),
            .DDR_CLOCK_HZ(0),.PERIPH_CLOCK_HZ(PERIPH_CLOCK_HZ),.UART_DIVISOR((PERIPH_CLOCK_HZ+57600)/115200)) u_soc (
            .clk_core,.clk_sys,.clk_ddr(1'b0),.clk_periph,.reset_async,.ddr_ready(1'b0),
            .uart_rx({1'b1,uart_rxd}),.uart_tx,.gpio_in,.gpio_out(),.gpio_oe(),
            .flash_cs_n(),.flash_sck(),.flash_mosi(),.flash_miso(1'b0),
            .ddr_req(),.ddr_rsp('0),.external_req('0),.external_rsp(),.npu_req(),.npu_rsp('0),
            .commit_valid,.commit_pc,.commit_inst,.commit_rd,.commit_rd_we,.commit_rd_data,
            .commit_exception,.commit_trace,.dmem_store_fire,.dmem_store_addr,.dmem_store_data,.dmem_store_strb);
    end else begin : g_core
        assign uart_txd=1'b1;
        benchmark_core_tcm #(.ITCM_INIT_FILE(ITCM_INIT_FILE),.DTCM_INIT_FILE(DTCM_INIT_FILE)) u_core (
            .clk_core,.rst_core,.commit_valid,.commit_pc,.commit_inst,.commit_rd,.commit_rd_we,.commit_rd_data,
            .commit_exception,.commit_trace,.dmem_store_fire,.dmem_store_addr,.dmem_store_data,.dmem_store_strb);
    end
    // 只观测已运行的 CPU；不通过扫描提供取指、数据或总线应答。
    localparam int OBSERVE_BITS = 1+XLEN+32+5+1+XLEN+1+1+2*XLEN+DBUS_BYTES;
    logic [OBSERVE_BITS-1:0] observe;
    assign observe={commit_valid,commit_pc,commit_inst,commit_rd,commit_rd_we,commit_rd_data,
                    commit_exception,dmem_store_fire,dmem_store_addr,dmem_store_data,dmem_store_strb};
    pango_measure_scan #(.OUTPUT_BITS(OBSERVE_BITS)) u_observe (.clk(clk_core),.rst(rst_core),
        .shift,.update(1'b0),.capture,.serial_in(1'b0),.serial_out,.drive(),.observe);
endmodule
