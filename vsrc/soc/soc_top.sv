// Module: soc_top
// Description: Portable no-cache core, ROM, TCM, MMIO, DMA and optional external-memory port.
module soc_top #(
    parameter string ITCM_INIT_FILE = "",
    parameter string DTCM_INIT_FILE = "",
    parameter int unsigned DDR_BYTES = 0,
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
    bus_rsp_t fetch_response, fetch_buffer_q;
    logic fetch_buffer_valid_q;
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
        .commit_rd_data, .commit_exception
    );

    // Core 保留独立 I/D 接口；物理地址由同一个互连解释，D 可修改 I-TCM。
    always_comb begin
        m_request[0] = '0;
        m_request[0].addr = imem_req_addr;
        m_request[0].execute = 1'b1;
        m_request[0].size = MEM_WORD;
        m_request[1] = '0;
        m_request[1].addr = dmem_req_addr;
        m_request[1].write = dmem_req_write;
        m_request[1].size = dmem_req_size;
        m_request[1].wdata = dmem_req_wdata;
        m_request[1].wstrb = dmem_req_wstrb;
    end
    assign m_req_valid[1:0] = {dmem_req_valid, imem_req_valid};
    assign m_rsp_ready[1:0] = {dmem_rsp_ready, 1'b1};
    assign {dmem_req_ready, imem_req_ready} = m_req_ready[1:0];
    assign dmem_rsp_valid = m_rsp_valid[1];
    assign imem_rsp_valid = fetch_buffer_valid_q || m_rsp_valid[0];
    assign fetch_response = fetch_buffer_valid_q ? fetch_buffer_q : m_response[0];
    assign imem_rsp_error = fetch_response.error != BUS_OK;
    assign dmem_rsp_error = m_response[1].error != BUS_OK;
    assign imem_rsp_data = 32'(fetch_response.rdata >> (8 * fetch_lane_q));
    assign dmem_rsp_rdata = m_response[1].rdata;

    // I 响应旁路优先，反压时保存一份；Core 每端口一笔在途，缓冲未消费前不会再发请求。
    // 互连 I-rsp-ready 恒为 1，切断 IF 输出反压经共享 bank 返回 MEM-ready 的组合环。
    always_ff @(posedge clk) begin
        if (rst) begin
            fetch_buffer_valid_q <= 1'b0;
            fetch_buffer_q <= '0;
        end else begin
            if (fetch_buffer_valid_q && imem_rsp_ready)
                fetch_buffer_valid_q <= 1'b0;
            if (m_rsp_valid[0] && !imem_rsp_ready) begin
                fetch_buffer_valid_q <= 1'b1;
                fetch_buffer_q <= m_response[0];
            end
        end
    end

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
                      .UART_DIVISOR(UART_DIVISOR)) u_peripherals (
        .clk, .rst, .uart_rx, .uart_tx, .gpio_in, .gpio_out, .gpio_oe,
        .irq_software, .irq_timer, .irq_external,
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
