// Module: soc_system
// Description: Four-domain scoreboard SoC with local CPU memories and a unified buffered AXI4 system bus.
module soc_system #(
    parameter ITCM_INIT_FILE = "",
    parameter DTCM_INIT_FILE = "",
    parameter int DDR_BYTES = 0,
    parameter int FLASH_BYTES = 0,
    parameter int NPU_BYTES = 0,
    parameter int SOC_PROFILE = soc_config_pkg::SOC_PROFILE_FULL,
    parameter bit ICACHE_ENABLE = 1,
    parameter int ICACHE_BYTES = 4096,
    parameter int ICACHE_LINE_BYTES = 32,
    parameter bit DCACHE_ENABLE = 1,
    parameter int DCACHE_BYTES = 4096,
    parameter int DCACHE_LINE_BYTES = 32,
    parameter logic [31:0] CLOCK_HZ = 100000000,
    parameter bit CLOCK_INFO_ENABLE = 1'b0,
    parameter logic [31:0] CORE_CLOCK_HZ = CLOCK_HZ,
    parameter logic [31:0] SYS_CLOCK_HZ = CLOCK_HZ,
    parameter logic [31:0] DDR_CLOCK_HZ = CLOCK_HZ,
    parameter logic [31:0] PERIPH_CLOCK_HZ = CLOCK_HZ,
    parameter logic [31:0] UART_DIVISOR = 217
) (
    input logic clk_core, clk_sys, clk_ddr, clk_periph, reset_async,
    input logic ddr_ready,
    input logic [1:0] uart_rx,
    output logic [1:0] uart_tx,
    input logic [31:0] gpio_in [3],
    output logic [31:0] gpio_out [3], gpio_oe [3],
    output logic flash_cs_n, flash_sck, flash_mosi,
    input logic flash_miso,
    output axi_types_pkg::axi_req_t ddr_req,
    input axi_types_pkg::axi_rsp_t ddr_rsp,
    input axi_types_pkg::axi_req_t external_req,
    output axi_types_pkg::axi_rsp_t external_rsp,
    output axi_types_pkg::axi_req_t npu_req,
    input axi_types_pkg::axi_rsp_t npu_rsp,
    output logic commit_valid,
    output logic [core_config_pkg::XLEN-1:0] commit_pc,
    output logic [31:0] commit_inst,
    output logic [4:0] commit_rd,
    output logic commit_rd_we,
    output logic [core_config_pkg::XLEN-1:0] commit_rd_data,
    output logic commit_exception,
    output pipeline_pkg::retire_trace_t commit_trace [2],
    output logic dmem_store_fire,
    output logic [core_config_pkg::XLEN-1:0] dmem_store_addr, dmem_store_data,
    output logic [core_config_pkg::DBUS_BYTES-1:0] dmem_store_strb
);
    import core_config_pkg::*;
    import core_types_pkg::*;
    import bus_types_pkg::*;
    import block_types_pkg::*;
    import axi_types_pkg::*;
    localparam logic [15:0] DEVICE_PRESENT =
        (SOC_PROFILE == soc_config_pkg::SOC_PROFILE_LITE ? soc_config_pkg::SOC_LITE_PRESENT : soc_config_pkg::SOC_FULL_PRESENT) |
        (DDR_BYTES != 0 ? 16'h4000 : 16'h0000);
    logic rst_core, rst_sys, rst_ddr, rst_periph;
    logic [7:0] rst_sys_local;
    // 按fabric、两个CPU CDC、TCM、DDR、DMA、控制桥、ROM/Flash分开驱动SYS复位负载。
    soc_reset_controller #(.SYS_COPIES(8)) u_reset (.reset_async,.clk_core,.clk_sys,.clk_ddr,.clk_periph,
        .rst_core,.rst_sys,.rst_ddr,.rst_periph,.rst_sys_local);
    logic [2:0] device_pending, core_pending;
    (* ASYNC_REG = "TRUE", PAP_ASYNC_REG = 1, syn_allow_retiming = 0 *) logic [1:0] ddr_system_online_q;
    always_ff @(posedge clk_sys) begin
        if (rst_sys) ddr_system_online_q<=0;
        else ddr_system_online_q<={ddr_system_online_q[0],ddr_ready};
    end
    (* ASYNC_REG = "TRUE", PAP_ASYNC_REG = 1, syn_allow_retiming = 0 *) logic [1:0] ddr_online_q;
    always_ff @(posedge clk_periph) begin
        if (rst_periph) ddr_online_q<=0;
        else ddr_online_q<={ddr_online_q[0],ddr_ready};
    end
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

    logic cache_command_valid, cache_command_ready, cache_busy, cache_fatal, fetch_block;
    cache_pkg::cache_maint_op_e cache_command, maint_op;
    cache_pkg::cache_maint_error_e cache_error, maint_error, cache_fault_code;
    xlen_t cache_fault_addr, maint_fault_addr, backend_fault_addr;
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
    axi_req_t masters [4], targets [7], local_axi [2];
    axi_rsp_t master_responses [4], target_responses [7], local_responses [2];
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
        axi_clock_bridge u_cdc (.s_clk(clk_core),.s_rst(rst_core),.m_clk(clk_sys),.m_rst(rst_sys_local[m+1]),
            .s_req(local_axi[m]),.s_rsp(local_responses[m]),.m_req(masters[m]),.m_rsp(master_responses[m]));
    end
    assign masters[3] = external_req;
    assign external_rsp = master_responses[3];
    assign npu_req = targets[6];
    assign target_responses[6] = npu_rsp;
    axi_system_fabric #(.DDR_BYTES(DDR_BYTES),.FLASH_BYTES(FLASH_BYTES),.NPU_BYTES(NPU_BYTES)) u_fabric (
        .clk(clk_sys),.rst(rst_sys_local[0]),.m_req(masters),.m_rsp(master_responses),.s_req(targets),.s_rsp(target_responses));
    axi_error_target u_error (.clk(clk_sys),.rst(rst_sys_local[0]),.req(targets[0]),.rsp(target_responses[0]));
    logic rom_req_valid, rom_req_ready, rom_rsp_valid, rom_rsp_ready;
    bus_req_t rom_request;
    bus_rsp_t rom_response;
    axi_bus_target #(.READ_ONLY(1)) u_rom_target (.clk(clk_sys),.rst(rst_sys_local[7]),.axi_req(targets[1]),.axi_rsp(target_responses[1]),
        .req_valid(rom_req_valid),.req_ready(rom_req_ready),.request(rom_request),
        .rsp_valid(rom_rsp_valid),.rsp_ready(rom_rsp_ready),.response(rom_response));
    boot_rom u_rom (.clk(clk_sys),.rst(rst_sys_local[7]),.req_valid(rom_req_valid),.req_ready(rom_req_ready),.request(rom_request),
        .rsp_valid(rom_rsp_valid),.rsp_ready(rom_rsp_ready),.response(rom_response));
    axi_req_t system_tcm_req;
    axi_rsp_t system_tcm_rsp;
    axi_clock_bridge u_tcm_cdc (.s_clk(clk_sys),.s_rst(rst_sys_local[3]),.m_clk(clk_core),.m_rst(rst_core),
        .s_req(targets[2]),.s_rsp(target_responses[2]),.m_req(system_tcm_req),.m_rsp(system_tcm_rsp));
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
    // 无 DDR 的片上配置不保留 DDR FIFO 或 DDR 域状态；地址译码仍返回显式错误。
    if (DDR_BYTES != 0) begin : g_ddr
        axi_req_t admitted_ddr_req;
        axi_rsp_t admitted_ddr_rsp;
        axi_availability_gate u_ddr_admission (.clk(clk_sys),.rst(rst_sys_local[4]),.available(ddr_system_online_q[1]),
            .s_req(targets[3]),.s_rsp(target_responses[3]),.m_req(admitted_ddr_req),.m_rsp(admitted_ddr_rsp));
        axi_clock_bridge u_ddr_cdc (.s_clk(clk_sys),.s_rst(rst_sys_local[4]),.m_clk(clk_ddr),.m_rst(rst_ddr),
            .s_req(admitted_ddr_req),.s_rsp(admitted_ddr_rsp),.m_req(ddr_req),.m_rsp(ddr_rsp));
    end else begin : g_no_ddr
        assign ddr_req = '0;
        axi_error_target u_error (.clk(clk_sys),.rst(rst_sys_local[4]),.req(targets[3]),.rsp(target_responses[3]));
    end

    axil_req_t system_mmio_req, periph_mmio_req;
    axil_rsp_t system_mmio_rsp, periph_mmio_rsp;
    axi_to_axil u_control_bridge (.clk(clk_sys),.rst(rst_sys_local[6]),.s_req(targets[4]),.s_rsp(target_responses[4]),
        .m_req(system_mmio_req),.m_rsp(system_mmio_rsp));
    axil_clock_bridge u_periph_cdc (.s_clk(clk_sys),.s_rst(rst_sys_local[6]),.m_clk(clk_periph),.m_rst(rst_periph),
        .s_req(system_mmio_req),.s_rsp(system_mmio_rsp),.m_req(periph_mmio_req),.m_rsp(periph_mmio_rsp));
    logic dma_req_valid, dma_req_ready, dma_rsp_valid, dma_rsp_ready, dma_irq;
    bus_req_t dma_request;
    bus_rsp_t dma_response;
    logic flash_req_valid, flash_req_ready, flash_rsp_valid, flash_rsp_ready;
    bus_req_t flash_request;
    bus_rsp_t flash_response;
    logic p_command_valid, p_command_ready, p_busy, p_fatal;
    cache_pkg::cache_maint_op_e p_command;
    cache_pkg::cache_maint_error_e p_error;
    xlen_t p_fault_addr;
    cache_command_cdc u_maintenance_cdc (.clk_core,.rst_core,.clk_periph,.rst_periph,
        .command_valid(p_command_valid),.command_ready(p_command_ready),.command(p_command),
        .busy(p_busy),.fatal(p_fatal),.error(p_error),.fault_addr(p_fault_addr),
        .core_command_valid(cache_command_valid),.core_command_ready(cache_command_ready),.core_command(cache_command),
        .core_busy(cache_busy),.core_fatal(cache_fatal),.core_error(cache_error),.core_fault_addr(cache_fault_addr));
    mmio_bus #(.DDR_BYTES(DDR_BYTES),.FLASH_BYTES(FLASH_BYTES),.NPU_BYTES(NPU_BYTES),.SOC_PROFILE(SOC_PROFILE),.PRESENT(DEVICE_PRESENT),.DCACHE_ENABLE(DCACHE_ENABLE),
        .DCACHE_BYTES(DCACHE_BYTES),.DCACHE_LINE_BYTES(DCACHE_LINE_BYTES),.CLOCK_HZ(CLOCK_HZ),.UART_DIVISOR(UART_DIVISOR),
        .CLOCK_INFO_ENABLE(CLOCK_INFO_ENABLE),.CORE_CLOCK_HZ(CORE_CLOCK_HZ),.SYS_CLOCK_HZ(SYS_CLOCK_HZ),
        .DDR_CLOCK_HZ(DDR_CLOCK_HZ),.PERIPH_CLOCK_HZ(PERIPH_CLOCK_HZ)) u_peripherals (
        .clk(clk_periph),.rst(rst_periph),.ddr_ready(ddr_online_q[1]),.axi_req(periph_mmio_req),.axi_rsp(periph_mmio_rsp),.uart_rx,.uart_tx,.gpio_in,.gpio_out,.gpio_oe,
        .irq_software(device_pending[0]),.irq_timer(device_pending[1]),.irq_external(device_pending[2]),
        .cache_command_valid(p_command_valid),.cache_command_ready(p_command_ready),.cache_command(p_command),
        .cache_busy(p_busy),.cache_fatal(p_fatal),.cache_error(p_error),.cache_fault_addr(p_fault_addr),
        .dma_req_valid,.dma_req_ready,.dma_request,.dma_rsp_valid,.dma_rsp_ready,.dma_response,.dma_irq,
        .flash_req_valid,.flash_req_ready,.flash_request,.flash_rsp_valid,.flash_rsp_ready,.flash_response);
    dma_command_cdc #(.DDR_BYTES(DDR_BYTES),.FLASH_BYTES(FLASH_BYTES),.NPU_ENABLE(NPU_BYTES != 0)) u_dma (
        .clk_sys,.rst_sys(rst_sys_local[5]),.clk_periph,.rst_periph,.req_valid(dma_req_valid),.req_ready(dma_req_ready),.request(dma_request),
        .rsp_valid(dma_rsp_valid),.rsp_ready(dma_rsp_ready),.response(dma_response),.irq(dma_irq),
        .axi_req(masters[2]),.axi_rsp(master_responses[2]));
    flash_axi_target u_flash (.clk_sys,.rst_sys(rst_sys_local[7]),.clk_periph,.rst_periph,.axi_req(targets[5]),.axi_rsp(target_responses[5]),
        .reg_req_valid(flash_req_valid),.reg_req_ready(flash_req_ready),.reg_request(flash_request),
        .reg_rsp_valid(flash_rsp_valid),.reg_rsp_ready(flash_rsp_ready),.reg_response(flash_response),
        .spi_cs_n(flash_cs_n),.spi_sck(flash_sck),.spi_mosi(flash_mosi),.spi_miso(flash_miso));
endmodule
