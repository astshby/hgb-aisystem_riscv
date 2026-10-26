// Module: soc_top
// Description: Portable core, DDR instruction/data caches, ROM, TCM, MMIO, DMA and external-memory port.
module soc_top #(
    parameter ITCM_INIT_FILE = "",
    parameter DTCM_INIT_FILE = "",
    parameter bit LOCAL_TCM_ENABLE = 1'b0,
    parameter int unsigned SOC_PROFILE = soc_config_pkg::SOC_PROFILE_FULL,
    parameter int unsigned DDR_BYTES = 0,
    parameter bit MM3_ACCEL_ENABLE = 1'b0,
    parameter int unsigned MM3_MAC_LANES = 16,
    parameter bit DMA_WIDE_ENABLE = 1'b0,
    parameter bit DMA_BLOCK_ENABLE = 1'b0,
    parameter bit CACHE_BLOCK_ENABLE = 1'b0,
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
    output logic dma_wide_req_valid,
    input logic dma_wide_req_ready,
    output bus_types_pkg::ddr_req_t dma_wide_request,
    input logic dma_wide_rsp_valid,
    output logic dma_wide_rsp_ready,
    input bus_types_pkg::ddr_rsp_t dma_wide_response,
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
    output logic [core_config_pkg::DBUS_BYTES-1:0] dmem_store_strb,
    output logic [1:0] cache_rd_cmd_valid,
    input logic [1:0] cache_rd_cmd_ready,
    output block_types_pkg::block_cmd_t cache_rd_cmd [2],
    input logic [1:0] cache_rd_valid,
    output logic [1:0] cache_rd_ready,
    input block_types_pkg::block_r_t cache_rd_data [2],
    output logic [1:0] cache_wr_cmd_valid,
    input logic [1:0] cache_wr_cmd_ready,
    output block_types_pkg::block_cmd_t cache_wr_cmd [2],
    output logic [1:0] cache_wr_valid,
    input logic [1:0] cache_wr_ready,
    output block_types_pkg::block_w_t cache_wr_data [2],
    input logic [1:0] cache_wr_rsp_valid,
    output logic [1:0] cache_wr_rsp_ready,
    input block_types_pkg::block_b_t cache_wr_rsp [2],
    output logic dma_block_rd_cmd_valid,
    input logic dma_block_rd_cmd_ready,
    output block_types_pkg::block_cmd_t dma_block_rd_cmd,
    input logic dma_block_rd_valid,
    output logic dma_block_rd_ready,
    input block_types_pkg::block_r_t dma_block_rd_data,
    output logic dma_block_wr_cmd_valid,
    input logic dma_block_wr_cmd_ready,
    output block_types_pkg::block_cmd_t dma_block_wr_cmd,
    output logic dma_block_wr_valid,
    input logic dma_block_wr_ready,
    output block_types_pkg::block_w_t dma_block_wr_data,
    input logic dma_block_wr_rsp_valid,
    output logic dma_block_wr_rsp_ready,
    input block_types_pkg::block_b_t dma_block_wr_rsp
);
    import core_config_pkg::*;
    import core_types_pkg::*;
    import soc_addr_pkg::*;
    import bus_types_pkg::*;
    // 全局能力表只在此派生；后续热路屏蔽 fabric 目标不能改变软件看到的物理设备。
    localparam logic [15:0] DEVICE_PRESENT =
        (SOC_PROFILE == soc_config_pkg::SOC_PROFILE_LITE ?
         soc_config_pkg::SOC_LITE_PRESENT : soc_config_pkg::SOC_FULL_PRESENT) |
        (DDR_BYTES != 0 ? 16'h4000 : 16'h0000) | (MM3_ACCEL_ENABLE ? 16'h8000 : 16'h0000);
`ifdef CORE_SCOREBOARD
    localparam bit NATIVE_MEMORY = 1;
`else
    localparam bit NATIVE_MEMORY = 0;
`endif
    // 新后端由原生 bank 路由拥有 TCM；物理能力发现仍保留两个窗口。
    // 物理能力发现保留两个 TCM；仅局部路由开启时从慢 fabric 的译码中移除。
    localparam logic [15:0] SLOW_PRESENT =
        DEVICE_PRESENT & ((LOCAL_TCM_ENABLE || NATIVE_MEMORY) ? 16'hfff3 : 16'hffff);
    logic irq_software, irq_timer, irq_external;
    logic device_irq_software, device_irq_timer, device_irq_external;
    logic imem_req_valid, imem_req_ready, imem_rsp_valid, imem_rsp_ready, imem_rsp_error, imem_rsp_error_1;
    xlen_t imem_req_addr;
    logic [FETCH_DATA_W-1:0] imem_rsp_data;
    logic word_imem_req_valid, word_imem_req_ready, word_imem_rsp_valid, word_imem_rsp_ready;
    logic word_imem_rsp_error, fetch_adapter_ready;
    xlen_t word_imem_req_addr;
    logic [31:0] word_imem_rsp_data;
    logic dmem_req_valid, dmem_req_ready, dmem_req_write;
    logic dmem_rsp_valid, dmem_rsp_ready, dmem_rsp_error;
    mem_size_e dmem_req_size;
    xlen_t dmem_req_addr, dmem_req_wdata, dmem_rsp_rdata;
    logic [DBUS_BYTES-1:0] dmem_req_wstrb;
    logic [$clog2(DBUS_BYTES)-1:0] fetch_lane_q;
    logic [2:0] m_req_valid, m_req_ready, m_rsp_valid, m_rsp_ready;
    bus_req_t m_request [3];
    bus_rsp_t m_response [3];
    // Cache/DMA 与 fabric 各拥有独立接口，寄存边界阻断请求和响应的同拍穿透。
    logic [2:0] fabric_req_valid, fabric_req_ready, fabric_rsp_valid, fabric_rsp_ready;
    bus_req_t fabric_request [3];
    bus_rsp_t fabric_response [3];
    // 热路与慢路共用源端的一笔在途；慢路仍由原事务寄存槽隔离。
    logic [2:0] slow_req_valid, slow_req_ready, slow_rsp_valid, slow_rsp_ready;
    bus_req_t slow_request [3];
    bus_rsp_t slow_response [3];
    logic [2:0] hot_req_valid, hot_req_ready, hot_rsp_valid, hot_rsp_ready, hot_bank;
    bus_req_t hot_request [3];
    bus_rsp_t hot_response [3];
    // 统一物理 bank 观察口；两种接线始终只拥有同一份 ITCM/DTCM RAM。
    logic [1:0] tcm_req_valid, tcm_req_ready, tcm_rsp_valid, tcm_rsp_ready;
    bus_req_t tcm_request [2];
    bus_rsp_t tcm_response [2];
    bus_rsp_t fetch_response;
    bus_req_t fetch_request, data_request;
    bus_rsp_t data_response;
    logic cache_command_valid, cache_command_ready, cache_busy, cache_fatal, fetch_block, cache_imem_ready;
    cache_pkg::cache_maint_op_e cache_command, maint_op;
    cache_pkg::cache_maint_error_e cache_error, maint_error, cache_fault_code;
    xlen_t cache_fault_addr, maint_fault_addr, backend_fault_addr;
    logic maint_req_valid, maint_req_ready, maint_rsp_valid, maint_rsp_ready, cache_fault_valid;
    logic fence_i_commit;
    logic [15:0] s_req_valid, s_req_ready, s_rsp_valid, s_rsp_ready;
    logic ddr_slot_ready;
    bus_req_t s_request [16];
    bus_rsp_t s_response [16];
    bus_error_e s_error [16];

    logic dma_cpu_req_valid, dma_cpu_req_ready, dma_cpu_rsp_valid, dma_cpu_rsp_ready;
    bus_req_t dma_cpu_request;
    bus_rsp_t dma_cpu_response;
    cache_maintenance_controller #(.ACTIVE(DCACHE_ENABLE && DDR_BYTES != 0)) u_cache_maintenance (
        .clk, .rst, .fence_i_commit, .command_valid(cache_command_valid), .command_ready(cache_command_ready),
        .command(cache_command), .busy(cache_busy), .fetch_block, .fatal(cache_fatal),
        .error(cache_error), .fault_addr(cache_fault_addr),
        .maint_req_valid, .maint_req_ready, .maint_op, .maint_rsp_valid, .maint_rsp_ready,
        .maint_error, .maint_fault_addr, .cache_fault_valid, .cache_fault_code,
        .cache_fault_addr(backend_fault_addr)
    );

`ifdef CORE_SCOREBOARD
    logic [1:0] data_req_valid, data_req_ready, data_rsp_valid, data_rsp_ready;
    scoreboard_pkg::memory_request_t tagged_request [2];
    scoreboard_pkg::memory_response_t tagged_response [2];
    scoreboard_core u_core (
        .clk, .rst, .irq_software, .irq_timer, .irq_external,
        .imem_req_valid, .imem_req_ready, .imem_req_addr,
        .imem_rsp_valid, .imem_rsp_ready, .imem_rsp_data, .imem_rsp_error, .imem_rsp_error_1,
        .mem_req_valid(data_req_valid), .mem_req_ready(data_req_ready), .mem_request(tagged_request),
        .mem_rsp_valid(data_rsp_valid), .mem_rsp_ready(data_rsp_ready), .mem_response(tagged_response),
        .commit_valid, .commit_pc, .commit_inst, .commit_rd, .commit_rd_we, .commit_rd_data,
        .commit_exception, .commit_trace, .fence_i_commit, .issue_fire()
    );
    scoreboard_soc_memory #(.ITCM_INIT_FILE(ITCM_INIT_FILE), .DTCM_INIT_FILE(DTCM_INIT_FILE),
        .DDR_BYTES(DDR_BYTES), .ICACHE_ENABLE(ICACHE_ENABLE), .ICACHE_BYTES(ICACHE_BYTES),
        .ICACHE_LINE_BYTES(ICACHE_LINE_BYTES), .DCACHE_ENABLE(DCACHE_ENABLE), .DCACHE_BYTES(DCACHE_BYTES),
        .DCACHE_LINE_BYTES(DCACHE_LINE_BYTES), .CACHE_BLOCK_ENABLE(CACHE_BLOCK_ENABLE)) u_memory (
        .clk, .rst, .fence_i_commit, .fetch_block, .imem_req_valid, .imem_req_ready, .imem_req_addr,
        .imem_rsp_valid, .imem_rsp_ready, .imem_rsp_data, .imem_rsp_error, .imem_rsp_error_1,
        .data_req_valid, .data_req_ready, .data_request(tagged_request),
        .data_rsp_valid, .data_rsp_ready, .data_response(tagged_response),
        .dma_req_valid(dma_cpu_req_valid), .dma_req_ready(dma_cpu_req_ready), .dma_request(dma_cpu_request),
        .dma_rsp_valid(dma_cpu_rsp_valid), .dma_rsp_ready(dma_cpu_rsp_ready), .dma_response(dma_cpu_response),
        .m_req_valid, .m_req_ready, .m_request, .m_rsp_valid, .m_rsp_ready, .m_response,
        .maint_req_valid, .maint_req_ready, .maint_op, .maint_rsp_valid, .maint_rsp_ready, .maint_error, .maint_fault_addr,
        .cache_fault_valid, .cache_fault_code, .cache_fault_addr(backend_fault_addr),
        .cache_rd_cmd_valid, .cache_rd_cmd_ready, .cache_rd_cmd, .cache_rd_valid, .cache_rd_ready, .cache_rd_data,
        .cache_wr_cmd_valid, .cache_wr_cmd_ready, .cache_wr_cmd, .cache_wr_valid, .cache_wr_ready, .cache_wr_data,
        .cache_wr_rsp_valid, .cache_wr_rsp_ready, .cache_wr_rsp
    );
    assign dmem_store_fire = data_req_valid[0] && data_req_ready[0] && tagged_request[0].write;
    assign dmem_store_addr = tagged_request[0].address;
    assign dmem_store_data = tagged_request[0].wdata;
    assign dmem_store_strb = tagged_request[0].wstrb;
`else
    assign m_req_valid[2] = dma_cpu_req_valid;
    assign m_request[2] = dma_cpu_request;
    assign dma_cpu_req_ready = m_req_ready[2];
    assign dma_cpu_rsp_valid = m_rsp_valid[2];
    assign dma_cpu_response = m_response[2];
    assign m_rsp_ready[2] = dma_cpu_rsp_ready;
    core u_core (
        .clk, .rst, .irq_software, .irq_timer, .irq_external, .imem_req_valid, .imem_req_addr, .imem_req_ready,
        .imem_rsp_valid, .imem_rsp_data, .imem_rsp_error, .imem_rsp_error_1, .imem_rsp_ready,
        .dmem_req_valid, .dmem_req_write, .dmem_req_size, .dmem_req_addr,
        .dmem_req_wdata, .dmem_req_wstrb, .dmem_req_ready,
        .dmem_rsp_valid, .dmem_rsp_rdata, .dmem_rsp_error, .dmem_rsp_ready,
        .commit_valid, .commit_pc, .commit_inst, .commit_rd, .commit_rd_we,
        .commit_rd_data, .commit_exception, .commit_trace, .fence_i_commit
    );

    // SoC 保留32-bit I$/总线；双字取指兼容器逐字读取，不代表持续两条指令的供给能力。
    // FENCE.I 同时阻止新批次与后续子请求；已接受的旧响应仍可排空给 Core 的 kill 逻辑。
    fetch_width_adapter u_fetch_width (
        .clk, .rst,
        .s_req_valid(imem_req_valid && !fetch_block), .s_req_ready(fetch_adapter_ready),
        .s_req_addr(imem_req_addr), .s_rsp_valid(imem_rsp_valid), .s_rsp_ready(imem_rsp_ready),
        .s_rsp_data(imem_rsp_data), .s_rsp_error(imem_rsp_error), .s_rsp_error_1(imem_rsp_error_1),
        .m_req_valid(word_imem_req_valid), .m_req_ready(word_imem_req_ready),
        .m_req_addr(word_imem_req_addr), .m_rsp_valid(word_imem_rsp_valid),
        .m_rsp_ready(word_imem_rsp_ready), .m_rsp_data(word_imem_rsp_data), .m_rsp_error(word_imem_rsp_error)
    );

    // Core 保留独立 I/D 接口；物理地址由同一个互连解释，D 可修改 I-TCM。
    always_comb begin
        fetch_request = '0;
        fetch_request.addr = word_imem_req_addr;
        fetch_request.execute = 1'b1;
        fetch_request.size = MEM_WORD;
        data_request = '0;
        data_request.addr = dmem_req_addr;
        data_request.write = dmem_req_write;
        data_request.size = dmem_req_size;
        data_request.wdata = dmem_req_wdata;
        data_request.wstrb = dmem_req_wstrb;
    end
    assign word_imem_rsp_error = fetch_response.error != BUS_OK;
    assign dmem_rsp_error = data_response.error != BUS_OK;
    assign word_imem_rsp_data = 32'(fetch_response.rdata >> (8 * fetch_lane_q));
    assign dmem_rsp_rdata = data_response.rdata;

    // 只缓存合法 DDR 取指；ROM/TCM 旁路及原 I 响应缓冲由 cache_port 保留。
    // FENCE.I 失效标签但不取消已接受事务，旧响应仍交给 IF 的 kill 逻辑。
    icache #(.ENABLE(ICACHE_ENABLE), .DDR_BYTES(DDR_BYTES), .BLOCK_ENABLE(CACHE_BLOCK_ENABLE),
             .CACHE_BYTES(ICACHE_BYTES), .LINE_BYTES(ICACHE_LINE_BYTES)) u_icache (
        .clk, .rst, .invalidate(fence_i_commit),
        .req_valid(word_imem_req_valid && !fetch_block), .req_ready(cache_imem_ready), .request(fetch_request),
        .rsp_valid(word_imem_rsp_valid), .rsp_ready(word_imem_rsp_ready), .response(fetch_response),
        .mem_req_valid(m_req_valid[0]), .mem_req_ready(m_req_ready[0]), .mem_request(m_request[0]),
        .mem_rsp_valid(m_rsp_valid[0]), .mem_rsp_ready(m_rsp_ready[0]), .mem_response(m_response[0]),
        .rd_cmd_valid(cache_rd_cmd_valid[0]), .rd_cmd_ready(cache_rd_cmd_ready[0]), .rd_cmd(cache_rd_cmd[0]),
        .rd_valid(cache_rd_valid[0]), .rd_ready(cache_rd_ready[0]), .rd_data(cache_rd_data[0])
    );
    // I$从不写回；写方向槽保持明确的空值，不能悬空成隐式的第二主端。
    assign cache_wr_cmd_valid[0] = 1'b0;
    assign cache_wr_cmd[0] = '0;
    assign cache_wr_valid[0] = 1'b0;
    assign cache_wr_data[0] = '0;
    assign cache_wr_rsp_ready[0] = 1'b0;

    // FENCE.I 先作废旧 I$，清脏数据期间不接受新取指；旧 IF 响应仍可排空。
    assign imem_req_ready = fetch_adapter_ready && !fetch_block;
    assign word_imem_req_ready = cache_imem_ready && !fetch_block;

    // 数据缓存只覆盖 DDR；系统 MMIO 与 FENCE.I 共用维护引擎，普通 FENCE 仍不执行 Cache flush。
    dcache #(.ENABLE(DCACHE_ENABLE), .DDR_BYTES(DDR_BYTES), .BLOCK_ENABLE(CACHE_BLOCK_ENABLE),
             .CACHE_BYTES(DCACHE_BYTES), .LINE_BYTES(DCACHE_LINE_BYTES)) u_dcache (
        .clk, .rst, .maint_req_valid, .maint_req_ready, .maint_op, .maint_rsp_valid, .maint_rsp_ready,
        .maint_error, .maint_fault_addr, .fault_valid(cache_fault_valid),
        .fault_code(cache_fault_code), .fault_addr(backend_fault_addr),
        .req_valid(dmem_req_valid), .req_ready(dmem_req_ready), .request(data_request),
        .rsp_valid(dmem_rsp_valid), .rsp_ready(dmem_rsp_ready), .response(data_response),
        .mem_req_valid(m_req_valid[1]), .mem_req_ready(m_req_ready[1]), .mem_request(m_request[1]),
        .mem_rsp_valid(m_rsp_valid[1]), .mem_rsp_ready(m_rsp_ready[1]), .mem_response(m_response[1]),
        .rd_cmd_valid(cache_rd_cmd_valid[1]), .rd_cmd_ready(cache_rd_cmd_ready[1]), .rd_cmd(cache_rd_cmd[1]),
        .rd_valid(cache_rd_valid[1]), .rd_ready(cache_rd_ready[1]), .rd_data(cache_rd_data[1]),
        .wr_cmd_valid(cache_wr_cmd_valid[1]), .wr_cmd_ready(cache_wr_cmd_ready[1]), .wr_cmd(cache_wr_cmd[1]),
        .wr_valid(cache_wr_valid[1]), .wr_ready(cache_wr_ready[1]), .wr_data(cache_wr_data[1]),
        .wr_rsp_valid(cache_wr_rsp_valid[1]), .wr_rsp_ready(cache_wr_rsp_ready[1]), .wr_rsp(cache_wr_rsp[1])
    );

    // RV64 RAM 返回 8 字节，取指必须使用已接受请求的地址选择其中一条指令。
    always_ff @(posedge clk) begin
        if (rst)
            fetch_lane_q <= '0;
        else if (word_imem_req_valid && word_imem_req_ready)
            fetch_lane_q <= word_imem_req_addr[$clog2(DBUS_BYTES)-1:0];
    end

    // 仅暴露被动 Store 观察口；硬件不解释 tohost 或控制仿真退出。
    assign dmem_store_fire = dmem_req_valid && dmem_req_ready && dmem_req_write;
    assign dmem_store_addr = dmem_req_addr;
    assign dmem_store_data = dmem_req_wdata;
    assign dmem_store_strb = dmem_req_wstrb;

`endif

    // 每主端一次只保留一笔事务；I 请求一旦被接受，重定向只能排空旧响应。
    // 默认接线仍为 S2a。启用热路时，合法 TCM 不经慢端请求槽，但保留热响应 FF。
    // ROM/MMIO 与填行/写回仍增加请求、响应各一拍；Cache 命中不经过这些槽位。
    for (genvar m = 0; m < 3; m++) begin : g_fabric_register
        soc_memory_router #(.ENABLE(LOCAL_TCM_ENABLE && !NATIVE_MEMORY), .DDR_BYTES(DDR_BYTES)) u_router (
            .clk, .rst,
            .s_req_valid(m_req_valid[m]), .s_req_ready(m_req_ready[m]), .s_request(m_request[m]),
            .s_rsp_valid(m_rsp_valid[m]), .s_rsp_ready(m_rsp_ready[m]), .s_response(m_response[m]),
            .hot_req_valid(hot_req_valid[m]), .hot_req_ready(hot_req_ready[m]), .hot_request(hot_request[m]),
            .hot_bank(hot_bank[m]), .hot_rsp_valid(hot_rsp_valid[m]),
            .hot_rsp_ready(hot_rsp_ready[m]), .hot_response(hot_response[m]),
            .slow_req_valid(slow_req_valid[m]), .slow_req_ready(slow_req_ready[m]), .slow_request(slow_request[m]),
            .slow_rsp_valid(slow_rsp_valid[m]), .slow_rsp_ready(slow_rsp_ready[m]), .slow_response(slow_response[m])
        );
        bus_transaction_register u_register (
            .clk, .rst,
            .s_req_valid(slow_req_valid[m]), .s_req_ready(slow_req_ready[m]), .s_request(slow_request[m]),
            .s_rsp_valid(slow_rsp_valid[m]), .s_rsp_ready(slow_rsp_ready[m]), .s_response(slow_response[m]),
            .m_req_valid(fabric_req_valid[m]), .m_req_ready(fabric_req_ready[m]), .m_request(fabric_request[m]),
            .m_rsp_valid(fabric_rsp_valid[m]), .m_rsp_ready(fabric_rsp_ready[m]), .m_response(fabric_response[m])
        );
    end

    // 原 D 优先/DMA 轮询策略保留；慢端 ready 在寄存槽终止，不组合返回 Core。
    bus_interconnect #(.MASTERS(3), .DDR_BYTES(DDR_BYTES),
        .PRESENT(SLOW_PRESENT),
                       .DATA_PRIORITY(1'b1)) u_fabric (
        .clk, .rst, .m_req_valid(fabric_req_valid), .m_req_ready(fabric_req_ready), .m_request(fabric_request),
        .m_rsp_valid(fabric_rsp_valid), .m_rsp_ready(fabric_rsp_ready), .m_response(fabric_response),
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
`ifdef CORE_SCOREBOARD
    assign hot_req_ready = 0; assign hot_rsp_valid = 0;
    for (genvar m = 0; m < 3; m++) begin : g_native_no_hot
        assign hot_response[m] = '0;
    end
    for (genvar b = 0; b < 2; b++) begin : g_native_no_slow_tcm
        assign s_req_ready[b+2] = 0; assign s_rsp_valid[b+2] = 0; assign s_response[b+2] = '0;
    end
`else
    if (LOCAL_TCM_ENABLE) begin
        tcm_local_fabric u_local_tcm (
            .clk, .rst, .m_req_valid(hot_req_valid), .m_req_ready(hot_req_ready),
            .m_request(hot_request), .m_bank(hot_bank), .m_rsp_valid(hot_rsp_valid),
            .m_rsp_ready(hot_rsp_ready), .m_response(hot_response),
            .s_req_valid(tcm_req_valid), .s_req_ready(tcm_req_ready), .s_request(tcm_request),
            .s_rsp_valid(tcm_rsp_valid), .s_rsp_ready(tcm_rsp_ready), .s_response(tcm_response)
        );
        // 慢端不能再访问同一物理 bank；非法 TCM 请求在原 error 从机返回。
        for (genvar b = 0; b < 2; b++) begin : g_no_slow_tcm
            assign s_req_ready[b+2] = 1'b0;
            assign s_rsp_valid[b+2] = 1'b0;
            assign s_response[b+2] = '0;
        end
    end else begin
        assign hot_req_ready = '0;
        assign hot_rsp_valid = '0;
        for (genvar m = 0; m < 3; m++) begin : g_no_hot_response
            assign hot_response[m] = '0;
        end
        for (genvar b = 0; b < 2; b++) begin : g_slow_tcm
            assign tcm_req_valid[b] = s_req_valid[b+2];
            assign s_req_ready[b+2] = tcm_req_ready[b];
            assign tcm_request[b] = s_request[b+2];
            assign s_rsp_valid[b+2] = tcm_rsp_valid[b];
            assign tcm_rsp_ready[b] = s_rsp_ready[b+2];
            assign s_response[b+2] = tcm_response[b];
        end
    end
    tcm_controller #(.BASE(ITCM_BASE), .INIT_FILE(ITCM_INIT_FILE)) u_itcm (
        .clk, .rst, .req_valid(tcm_req_valid[0]), .req_ready(tcm_req_ready[0]),
        .request(tcm_request[0]), .rsp_valid(tcm_rsp_valid[0]),
        .rsp_ready(tcm_rsp_ready[0]), .response(tcm_response[0])
    );
    tcm_controller #(.BASE(DTCM_BASE), .INIT_FILE(DTCM_INIT_FILE)) u_dtcm (
        .clk, .rst, .req_valid(tcm_req_valid[1]), .req_ready(tcm_req_ready[1]),
        .request(tcm_request[1]), .rsp_valid(tcm_rsp_valid[1]),
        .rsp_ready(tcm_rsp_ready[1]), .response(tcm_response[1])
    );
`endif
    // 原 DMA 与加速器共享块出口；关闭功能时保留原 DMA 的直接接线。
    logic [1:0] mm3_c_rd_cmd_valid;
    logic [1:0] mm3_c_rd_cmd_ready;
    block_types_pkg::block_cmd_t mm3_c_rd_cmd [2];
    logic [1:0] mm3_c_rd_valid;
    logic [1:0] mm3_c_rd_ready;
    block_types_pkg::block_r_t mm3_c_rd_data [2];
    logic [1:0] mm3_c_wr_cmd_valid;
    logic [1:0] mm3_c_wr_cmd_ready;
    block_types_pkg::block_cmd_t mm3_c_wr_cmd [2];
    logic [1:0] mm3_c_wr_valid;
    logic [1:0] mm3_c_wr_ready;
    block_types_pkg::block_w_t mm3_c_wr_data [2];
    logic [1:0] mm3_c_wr_rsp_valid;
    logic [1:0] mm3_c_wr_rsp_ready;
    block_types_pkg::block_b_t mm3_c_wr_rsp [2];
    soc_peripherals #(.DDR_BYTES(DDR_BYTES), .DMA_WIDE_ENABLE(DMA_WIDE_ENABLE),
                      .DMA_BLOCK_ENABLE(DMA_BLOCK_ENABLE), .CLOCK_HZ(CLOCK_HZ),
                      .SOC_PROFILE(SOC_PROFILE), .PRESENT(DEVICE_PRESENT),
                      .DCACHE_ENABLE(DCACHE_ENABLE), .DCACHE_BYTES(DCACHE_BYTES),
                      .DCACHE_LINE_BYTES(DCACHE_LINE_BYTES),
                      .UART_DIVISOR(UART_DIVISOR)) u_peripherals (
        .clk, .rst, .uart_rx, .uart_tx, .gpio_in, .gpio_out, .gpio_oe,
        .dma_block_rd_cmd_valid(mm3_c_rd_cmd_valid[0]), .dma_block_rd_cmd_ready(mm3_c_rd_cmd_ready[0]), .dma_block_rd_cmd(mm3_c_rd_cmd[0]),
        .dma_block_rd_valid(mm3_c_rd_valid[0]), .dma_block_rd_ready(mm3_c_rd_ready[0]), .dma_block_rd_data(mm3_c_rd_data[0]),
        .dma_block_wr_cmd_valid(mm3_c_wr_cmd_valid[0]), .dma_block_wr_cmd_ready(mm3_c_wr_cmd_ready[0]), .dma_block_wr_cmd(mm3_c_wr_cmd[0]),
        .dma_block_wr_valid(mm3_c_wr_valid[0]), .dma_block_wr_ready(mm3_c_wr_ready[0]), .dma_block_wr_data(mm3_c_wr_data[0]),
        .dma_block_wr_rsp_valid(mm3_c_wr_rsp_valid[0]), .dma_block_wr_rsp_ready(mm3_c_wr_rsp_ready[0]), .dma_block_wr_rsp(mm3_c_wr_rsp[0]),
        .irq_software(device_irq_software), .irq_timer(device_irq_timer), .irq_external(device_irq_external),
        .cache_command_valid, .cache_command,
        .cache_command_ready, .cache_busy, .cache_fatal, .cache_error, .cache_fault_addr,
        .dma_req_valid(dma_cpu_req_valid), .dma_req_ready(dma_cpu_req_ready),
        .dma_request(dma_cpu_request), .dma_rsp_valid(dma_cpu_rsp_valid),
        .dma_rsp_ready(dma_cpu_rsp_ready), .dma_response(dma_cpu_response),
        .dma_wide_req_valid, .dma_wide_req_ready, .dma_wide_request,
        .dma_wide_rsp_valid, .dma_wide_rsp_ready, .dma_wide_response,
        .s_req_valid(s_req_valid[13:4]), .s_req_ready(s_req_ready[13:4]),
        .s_request(s_request[4:13]), .s_rsp_valid(s_rsp_valid[13:4]),
        .s_rsp_ready(s_rsp_ready[13:4]), .s_response(s_response[4:13])
    );
    if (MM3_ACCEL_ENABLE) begin : g_mm3_accel
        logic mmio_req_valid, mmio_req_ready, mmio_rsp_valid, mmio_rsp_ready;
        bus_req_t mmio_request;
        bus_rsp_t mmio_response;
        bus_transaction_register u_boundary (
            .clk, .rst, .s_req_valid(s_req_valid[15]), .s_req_ready(s_req_ready[15]), .s_request(s_request[15]),
            .s_rsp_valid(s_rsp_valid[15]), .s_rsp_ready(s_rsp_ready[15]), .s_response(s_response[15]),
            .m_req_valid(mmio_req_valid), .m_req_ready(mmio_req_ready), .m_request(mmio_request),
            .m_rsp_valid(mmio_rsp_valid), .m_rsp_ready(mmio_rsp_ready), .m_response(mmio_response)
        );
        mm3_accel #(.DDR_BYTES(DDR_BYTES), .MAC_LANES(MM3_MAC_LANES)) u_accel (
            .clk, .rst, .req_valid(mmio_req_valid), .req_ready(mmio_req_ready), .request(mmio_request),
            .rsp_valid(mmio_rsp_valid), .rsp_ready(mmio_rsp_ready), .response(mmio_response),
            .rd_cmd_valid(mm3_c_rd_cmd_valid[1]), .rd_cmd_ready(mm3_c_rd_cmd_ready[1]), .rd_cmd(mm3_c_rd_cmd[1]),
            .rd_valid(mm3_c_rd_valid[1]), .rd_ready(mm3_c_rd_ready[1]), .rd_data(mm3_c_rd_data[1]),
            .wr_cmd_valid(mm3_c_wr_cmd_valid[1]), .wr_cmd_ready(mm3_c_wr_cmd_ready[1]), .wr_cmd(mm3_c_wr_cmd[1]),
            .wr_valid(mm3_c_wr_valid[1]), .wr_ready(mm3_c_wr_ready[1]), .wr_data(mm3_c_wr_data[1]),
            .wr_rsp_valid(mm3_c_wr_rsp_valid[1]), .wr_rsp_ready(mm3_c_wr_rsp_ready[1]), .wr_rsp(mm3_c_wr_rsp[1])
        );
        block_arbiter #(.CLIENTS(2)) u_dma_share (
            .clk, .rst,
            .c_rd_cmd_valid(mm3_c_rd_cmd_valid), .c_rd_cmd_ready(mm3_c_rd_cmd_ready), .c_rd_cmd(mm3_c_rd_cmd),
            .c_rd_valid(mm3_c_rd_valid), .c_rd_ready(mm3_c_rd_ready), .c_rd_data(mm3_c_rd_data),
            .c_wr_cmd_valid(mm3_c_wr_cmd_valid), .c_wr_cmd_ready(mm3_c_wr_cmd_ready), .c_wr_cmd(mm3_c_wr_cmd),
            .c_wr_valid(mm3_c_wr_valid), .c_wr_ready(mm3_c_wr_ready), .c_wr_data(mm3_c_wr_data),
            .c_wr_rsp_valid(mm3_c_wr_rsp_valid), .c_wr_rsp_ready(mm3_c_wr_rsp_ready), .c_wr_rsp(mm3_c_wr_rsp),
            .rd_cmd_valid(dma_block_rd_cmd_valid), .rd_cmd_ready(dma_block_rd_cmd_ready), .rd_cmd(dma_block_rd_cmd),
            .rd_valid(dma_block_rd_valid), .rd_ready(dma_block_rd_ready), .rd_data(dma_block_rd_data),
            .wr_cmd_valid(dma_block_wr_cmd_valid), .wr_cmd_ready(dma_block_wr_cmd_ready), .wr_cmd(dma_block_wr_cmd),
            .wr_valid(dma_block_wr_valid), .wr_ready(dma_block_wr_ready), .wr_data(dma_block_wr_data),
            .wr_rsp_valid(dma_block_wr_rsp_valid), .wr_rsp_ready(dma_block_wr_rsp_ready), .wr_rsp(dma_block_wr_rsp)
        );
    end else begin : g_no_mm3_accel
        assign s_req_ready[15] = 0; assign s_rsp_valid[15] = 0; assign s_response[15] = '0;
        assign mm3_c_rd_cmd_valid[1] = '0;
        assign dma_block_rd_cmd_valid = mm3_c_rd_cmd_valid[0];
        assign mm3_c_rd_cmd_ready[0] = dma_block_rd_cmd_ready;
        assign mm3_c_rd_cmd_ready[1] = '0;
        assign mm3_c_rd_cmd[1] = '0;
        assign dma_block_rd_cmd = mm3_c_rd_cmd[0];
        assign mm3_c_rd_valid[0] = dma_block_rd_valid;
        assign mm3_c_rd_valid[1] = '0;
        assign mm3_c_rd_ready[1] = '0;
        assign dma_block_rd_ready = mm3_c_rd_ready[0];
        assign mm3_c_rd_data[0] = dma_block_rd_data;
        assign mm3_c_rd_data[1] = '0;
        assign mm3_c_wr_cmd_valid[1] = '0;
        assign dma_block_wr_cmd_valid = mm3_c_wr_cmd_valid[0];
        assign mm3_c_wr_cmd_ready[0] = dma_block_wr_cmd_ready;
        assign mm3_c_wr_cmd_ready[1] = '0;
        assign mm3_c_wr_cmd[1] = '0;
        assign dma_block_wr_cmd = mm3_c_wr_cmd[0];
        assign mm3_c_wr_valid[1] = '0;
        assign dma_block_wr_valid = mm3_c_wr_valid[0];
        assign mm3_c_wr_ready[0] = dma_block_wr_ready;
        assign mm3_c_wr_ready[1] = '0;
        assign mm3_c_wr_data[1] = '0;
        assign dma_block_wr_data = mm3_c_wr_data[0];
        assign mm3_c_wr_rsp_valid[0] = dma_block_wr_rsp_valid;
        assign mm3_c_wr_rsp_valid[1] = '0;
        assign mm3_c_wr_rsp_ready[1] = '0;
        assign dma_block_wr_rsp_ready = mm3_c_wr_rsp_ready[0];
        assign mm3_c_wr_rsp[0] = dma_block_wr_rsp;
        assign mm3_c_wr_rsp[1] = '0;
    end
    // mtime 比较和 IRQ 汇聚先寄存，再参与 Core 的排空/重定向控制。
    irq_register u_irq_register (
        .clk, .rst,
        .device_pending({device_irq_external, device_irq_timer, device_irq_software}),
        .core_pending({irq_external, irq_timer, irq_software})
    );

    // DDR 桥仍保留独立请求寄存边界，隔离桥校验与地址/写数据寄存使能。
    // fabric 在输入握手时锁定 owner，寄存请求发出后仍由原 owner 接收响应。
    bus_request_register u_ddr_request_register (
        .clk, .rst,
        .in_req_valid(DDR_BYTES != 0 && s_req_valid[14]), .in_req_ready(ddr_slot_ready),
        .in_request(s_request[14]),
        .out_req_valid(ddr_req_valid), .out_req_ready(ddr_req_ready), .out_request(ddr_request)
    );
    // 容量为 0 时 DDR 保持显式错误；实际桥或仿真模型接在这个可综合端口之外。
    assign s_req_ready[14] = DDR_BYTES != 0 && ddr_slot_ready;
    assign s_rsp_valid[14] = DDR_BYTES != 0 && ddr_rsp_valid;
    assign s_response[14] = DDR_BYTES != 0 ? ddr_response : '0;
    assign ddr_rsp_ready = s_rsp_ready[14];
endmodule
