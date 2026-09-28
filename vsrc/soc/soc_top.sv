// Module: soc_top
// Description: Portable core, DDR instruction/data caches, ROM, TCM, MMIO, DMA and external-memory port.
module soc_top #(
    parameter string ITCM_INIT_FILE = "",
    parameter string DTCM_INIT_FILE = "",
    parameter int unsigned DDR_BYTES = 0,
    parameter bit ICACHE_ENABLE = 1'b1,
    parameter int unsigned ICACHE_BYTES = 4096,
    parameter int unsigned ICACHE_LINE_BYTES = 32,
    parameter bit DCACHE_ENABLE = 1'b1,
    parameter int unsigned DCACHE_BYTES = 4096,
    parameter int unsigned DCACHE_LINE_BYTES = 32,
    parameter logic [31:0] CLOCK_HZ = 50000000,
    parameter logic [31:0] UART_DIVISOR = 434
) (
    input logic clk, rst,
    input logic [1:0] uart_rx,
    output logic [1:0] uart_tx,
    input logic [31:0] gpio_in [3],
    output logic [31:0] gpio_out [3], gpio_oe [3],
    output logic ddr_req_valid,
    input logic ddr_req_ready,
    output bus_types_pkg::bus_req_t ddr_request,
    input logic ddr_rsp_valid,
    output logic ddr_rsp_ready,
    input bus_types_pkg::bus_rsp_t ddr_response,
    output logic commit_valid,
    output logic [core_config_pkg::XLEN-1:0] commit_pc,
    output logic [31:0] commit_inst,
    output logic [4:0] commit_rd,
    output logic commit_rd_we,
    output logic [core_config_pkg::XLEN-1:0] commit_rd_data,
    output logic commit_exception,
    output logic dmem_store_fire,
    output logic [core_config_pkg::XLEN-1:0] dmem_store_addr, dmem_store_data,
    output logic [core_config_pkg::DBUS_BYTES-1:0] dmem_store_strb
);
    import core_config_pkg::*;
    import core_types_pkg::*;
    import soc_addr_pkg::*;
    import bus_types_pkg::*;
    logic irq_software, irq_timer, irq_external;
    logic imem_req_valid, imem_req_ready, imem_rsp_valid, imem_rsp_ready, imem_rsp_error;
    xlen_t imem_req_addr;
    logic [31:0] imem_rsp_data;
    logic dmem_req_valid, dmem_req_ready, dmem_req_write;
    logic dmem_rsp_valid, dmem_rsp_ready, dmem_rsp_error;
    mem_size_e dmem_req_size;
    xlen_t dmem_req_addr, dmem_req_wdata, dmem_rsp_rdata;
    logic [DBUS_BYTES-1:0] dmem_req_wstrb;
    logic [$clog2(DBUS_BYTES)-1:0] fetch_lane_q;
    logic [2:0] m_req_valid, m_req_ready, m_rsp_valid, m_rsp_ready;
    bus_req_t m_request [3];
    bus_rsp_t m_response [3];
    bus_rsp_t fetch_response;
    bus_req_t fetch_request, data_request;
    bus_rsp_t data_response;
    logic dcache_invalidate;
    logic fence_i_commit;
    logic [14:0] s_req_valid, s_req_ready, s_rsp_valid, s_rsp_ready;
    bus_req_t s_request [15];
    bus_rsp_t s_response [15];
    bus_error_e s_error [15];

    core u_core (
        .clk, .rst, .irq_software, .irq_timer, .irq_external, .imem_req_valid, .imem_req_addr, .imem_req_ready,
        .imem_rsp_valid, .imem_rsp_data, .imem_rsp_error, .imem_rsp_ready,
        .dmem_req_valid, .dmem_req_write, .dmem_req_size, .dmem_req_addr,
        .dmem_req_wdata, .dmem_req_wstrb, .dmem_req_ready,
        .dmem_rsp_valid, .dmem_rsp_rdata, .dmem_rsp_error, .dmem_rsp_ready,
        .commit_valid, .commit_pc, .commit_inst, .commit_rd, .commit_rd_we,
        .commit_rd_data, .commit_exception, .fence_i_commit
    );

    // Core 保留独立 I/D 接口；物理地址由同一个互连解释，D 可修改 I-TCM。
    always_comb begin
        fetch_request = '0;
        fetch_request.addr = imem_req_addr;
        fetch_request.execute = 1'b1;
        fetch_request.size = MEM_WORD;
        data_request = '0;
        data_request.addr = dmem_req_addr;
        data_request.write = dmem_req_write;
        data_request.size = dmem_req_size;
        data_request.wdata = dmem_req_wdata;
        data_request.wstrb = dmem_req_wstrb;
    end
    assign imem_rsp_error = fetch_response.error != BUS_OK;
    assign dmem_rsp_error = data_response.error != BUS_OK;
    assign imem_rsp_data = 32'(fetch_response.rdata >> (8 * fetch_lane_q));
    assign dmem_rsp_rdata = data_response.rdata;

    // 只缓存合法 DDR 取指；ROM/TCM 旁路及原 I 响应缓冲由 cache_port 保留。
    // FENCE.I 失效标签但不取消已接受事务，旧响应仍交给 IF 的 kill 逻辑。
    icache #(.ENABLE(ICACHE_ENABLE), .DDR_BYTES(DDR_BYTES),
             .CACHE_BYTES(ICACHE_BYTES), .LINE_BYTES(ICACHE_LINE_BYTES)) u_icache (
        .clk, .rst, .invalidate(fence_i_commit),
        .req_valid(imem_req_valid), .req_ready(imem_req_ready), .request(fetch_request),
        .rsp_valid(imem_rsp_valid), .rsp_ready(imem_rsp_ready), .response(fetch_response),
        .mem_req_valid(m_req_valid[0]), .mem_req_ready(m_req_ready[0]), .mem_request(m_request[0]),
        .mem_rsp_valid(m_rsp_valid[0]), .mem_rsp_ready(m_rsp_ready[0]), .mem_response(m_response[0])
    );

    // 数据缓存只覆盖 DDR；系统 MMIO 维护脉冲与 FENCE.I 分离，不暗改普通 FENCE 的语义。
    dcache #(.ENABLE(DCACHE_ENABLE), .DDR_BYTES(DDR_BYTES),
             .CACHE_BYTES(DCACHE_BYTES), .LINE_BYTES(DCACHE_LINE_BYTES)) u_dcache (
        .clk, .rst, .invalidate(dcache_invalidate),
        .req_valid(dmem_req_valid), .req_ready(dmem_req_ready), .request(data_request),
        .rsp_valid(dmem_rsp_valid), .rsp_ready(dmem_rsp_ready), .response(data_response),
        .mem_req_valid(m_req_valid[1]), .mem_req_ready(m_req_ready[1]), .mem_request(m_request[1]),
        .mem_rsp_valid(m_rsp_valid[1]), .mem_rsp_ready(m_rsp_ready[1]), .mem_response(m_response[1])
    );

    // RV64 RAM 返回 8 字节，取指必须使用已接受请求的地址选择其中一条指令。
    always_ff @(posedge clk) begin
        if (rst)
            fetch_lane_q <= '0;
        else if (imem_req_valid && imem_req_ready)
            fetch_lane_q <= imem_req_addr[$clog2(DBUS_BYTES)-1:0];
    end

    // 仅暴露被动 Store 观察口；硬件不解释 tohost 或控制仿真退出。
    assign dmem_store_fire = dmem_req_valid && dmem_req_ready && dmem_req_write;
    assign dmem_store_addr = dmem_req_addr;
    assign dmem_store_data = dmem_req_wdata;
    assign dmem_store_strb = dmem_req_wstrb;

    // CPU 的 D-ready 不依赖可被重定向撤回的 I-valid；跨 owner 交接隔一拍。
    bus_interconnect #(.MASTERS(3), .DDR_BYTES(DDR_BYTES),
                       .PRESENT(DDR_BYTES == 0 ? 15'h3fff : 15'h7fff),
                       .DATA_PRIORITY(1'b1)) u_fabric (
        .clk, .rst, .m_req_valid, .m_req_ready, .m_request,
        .m_rsp_valid, .m_rsp_ready, .m_response,
        .s_req_valid, .s_req_ready, .s_request, .s_error,
        .s_rsp_valid, .s_rsp_ready, .s_response
    );
    bus_error_slave u_error (
        .clk, .rst, .req_valid(s_req_valid[0]), .req_ready(s_req_ready[0]),
        .req_error(s_error[0]), .rsp_valid(s_rsp_valid[0]),
        .rsp_ready(s_rsp_ready[0]), .response(s_response[0])
    );
    boot_rom u_rom (
        .clk, .rst, .req_valid(s_req_valid[1]), .req_ready(s_req_ready[1]),
        .request(s_request[1]), .rsp_valid(s_rsp_valid[1]),
        .rsp_ready(s_rsp_ready[1]), .response(s_response[1])
    );
    tcm_controller #(.BASE(ITCM_BASE), .INIT_FILE(ITCM_INIT_FILE)) u_itcm (
        .clk, .rst, .req_valid(s_req_valid[2]), .req_ready(s_req_ready[2]),
        .request(s_request[2]), .rsp_valid(s_rsp_valid[2]),
        .rsp_ready(s_rsp_ready[2]), .response(s_response[2])
    );
    tcm_controller #(.BASE(DTCM_BASE), .INIT_FILE(DTCM_INIT_FILE)) u_dtcm (
        .clk, .rst, .req_valid(s_req_valid[3]), .req_ready(s_req_ready[3]),
        .request(s_request[3]), .rsp_valid(s_rsp_valid[3]),
        .rsp_ready(s_rsp_ready[3]), .response(s_response[3])
    );
    soc_peripherals #(.DDR_BYTES(DDR_BYTES), .CLOCK_HZ(CLOCK_HZ),
                      .DCACHE_ENABLE(DCACHE_ENABLE), .DCACHE_BYTES(DCACHE_BYTES),
                      .DCACHE_LINE_BYTES(DCACHE_LINE_BYTES),
                      .UART_DIVISOR(UART_DIVISOR)) u_peripherals (
        .clk, .rst, .uart_rx, .uart_tx, .gpio_in, .gpio_out, .gpio_oe,
        .irq_software, .irq_timer, .irq_external, .dcache_invalidate,
        .dma_req_valid(m_req_valid[2]), .dma_req_ready(m_req_ready[2]),
        .dma_request(m_request[2]), .dma_rsp_valid(m_rsp_valid[2]),
        .dma_rsp_ready(m_rsp_ready[2]), .dma_response(m_response[2]),
        .s_req_valid(s_req_valid[13:4]), .s_req_ready(s_req_ready[13:4]),
        .s_request(s_request[4:13]), .s_rsp_valid(s_rsp_valid[13:4]),
        .s_rsp_ready(s_rsp_ready[13:4]), .s_response(s_response[4:13])
    );
    // 容量为 0 时 DDR 保持显式错误；实际桥或仿真模型接在这个可综合端口之外。
    assign ddr_req_valid = DDR_BYTES != 0 && s_req_valid[14];
    assign ddr_request = s_request[14];
    assign s_req_ready[14] = DDR_BYTES != 0 && ddr_req_ready;
    assign s_rsp_valid[14] = DDR_BYTES != 0 && ddr_rsp_valid;
    assign s_response[14] = DDR_BYTES != 0 ? ddr_response : '0;
    assign ddr_rsp_ready = s_rsp_ready[14];
endmodule
