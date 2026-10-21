// Module: soc_peripherals
// Description: Portable MMIO endpoints and single-hart interrupt aggregation.
module soc_peripherals #(
    parameter int unsigned DDR_BYTES = 0,
    parameter bit DMA_WIDE_ENABLE = 1'b0,
    parameter bit DMA_BLOCK_ENABLE = 1'b0,
    parameter int unsigned SOC_PROFILE = soc_config_pkg::SOC_PROFILE_FULL,
    parameter logic [14:0] PRESENT = soc_config_pkg::SOC_FULL_PRESENT |
                                    (DDR_BYTES != 0 ? 15'h4000 : 15'h0000),
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
    output logic irq_software, irq_timer, irq_external,
    output logic cache_command_valid,
    output cache_pkg::cache_maint_op_e cache_command,
    input logic cache_command_ready, cache_busy, cache_fatal,
    input cache_pkg::cache_maint_error_e cache_error,
    input core_types_pkg::xlen_t cache_fault_addr,
    output logic dma_req_valid,
    input logic dma_req_ready,
    output bus_types_pkg::bus_req_t dma_request,
    input logic dma_rsp_valid,
    output logic dma_rsp_ready,
    input bus_types_pkg::bus_rsp_t dma_response,
    output logic dma_wide_req_valid,
    input logic dma_wide_req_ready,
    output bus_types_pkg::ddr_req_t dma_wide_request,
    input logic dma_wide_rsp_valid,
    output logic dma_wide_rsp_ready,
    input bus_types_pkg::ddr_rsp_t dma_wide_response,
    input logic [13:4] s_req_valid,
    output logic [13:4] s_req_ready,
    input bus_types_pkg::bus_req_t s_request [4:13],
    output logic [13:4] s_rsp_valid,
    input logic [13:4] s_rsp_ready,
    output bus_types_pkg::bus_rsp_t s_response [4:13],
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
    import bus_types_pkg::*;
    localparam int unsigned UART_INSTANCES = PRESENT[TARGET_UART1] ? 2 : 1;
    localparam int unsigned GPIO_INSTANCES = PRESENT[TARGET_GPIO2] ? 3 : 1;

    // fabric 只连接各端点的请求寄存槽；设备内部已有同步响应寄存器，保留其反压语义。
    logic [13:4] device_req_valid, device_req_ready, device_rsp_valid, device_rsp_ready;
    bus_req_t device_request [4:13];
    bus_rsp_t device_response [4:13];

    logic timer_irq;
    logic [1:0] uart_irq;
    logic [2:0] gpio_irq;
    logic dma_irq;

    // 每个端点独立保留一笔 owner；先保存请求，下一拍才允许设备执行副作用。
    // 响应消费前不重开请求槽，不能因设备已接受请求而暗中增加第二笔在途。
    for (genvar s = 4; s <= 13; s++) begin : g_mmio_boundary
        if (PRESENT[s]) begin
            typedef enum logic [1:0] {IDLE, SEND, WAIT_RESPONSE} state_e;
            state_e state_q;
            bus_req_t request_q;
            logic s_req_fire, device_req_fire, s_rsp_fire;

            assign s_req_ready[s] = !rst && state_q == IDLE;
            assign device_req_valid[s] = !rst && state_q == SEND;
            assign device_request[s] = request_q;
            assign s_rsp_valid[s] = !rst && state_q == WAIT_RESPONSE && device_rsp_valid[s];
            assign s_response[s] = device_response[s];
            assign device_rsp_ready[s] = !rst && state_q == WAIT_RESPONSE && s_rsp_ready[s];
            assign s_req_fire = s_req_valid[s] && s_req_ready[s];
            assign device_req_fire = device_req_valid[s] && device_req_ready[s];
            assign s_rsp_fire = s_rsp_valid[s] && s_rsp_ready[s];

            // 设备响应寄存器就是返回边界，不在这里再复制一份数据或增加一拍响应等待。
            always_ff @(posedge clk) begin
                if (rst) begin
                    state_q <= IDLE;
                end else begin
                    unique case (state_q)
                        IDLE:          if (s_req_fire) state_q <= SEND;
                        SEND:          if (device_req_fire) state_q <= WAIT_RESPONSE;
                        WAIT_RESPONSE: if (s_rsp_fire) state_q <= IDLE;
                        default:       state_q <= IDLE;
                    endcase
                end
            end

            // 请求接受后上游可以改地址；设备的 offset、byte lane 和写使能只读本槽快照。
            always_ff @(posedge clk) begin
                if (rst)
                    request_q <= '0;
                else if (s_req_fire)
                    request_q <= s_request[s];
            end
        end else begin
            // 缺失窗口由 fabric 返回 DECERR；本处连同请求槽一起消除，不能伪造成功。
            assign s_req_ready[s] = 1'b0;
            assign s_rsp_valid[s] = 1'b0;
            assign s_response[s] = '0;
            assign device_req_valid[s] = 1'b0;
            assign device_request[s] = '0;
            assign device_rsp_ready[s] = 1'b0;
            assign device_req_ready[s] = 1'b0;
            assign device_rsp_valid[s] = 1'b0;
            assign device_response[s] = '0;
        end
    end

    machine_timer u_mtime (
        .clk, .rst, .req_valid(device_req_valid[4]), .req_ready(device_req_ready[4]),
        .request(device_request[4]), .rsp_valid(device_rsp_valid[4]), .rsp_ready(device_rsp_ready[4]),
        .response(device_response[4]), .irq_software, .irq_timer
    );
    irq_controller u_irq (
        .clk, .rst, .sources({dma_irq, gpio_irq, timer_irq, uart_irq}), .irq(irq_external),
        .req_valid(device_req_valid[5]), .req_ready(device_req_ready[5]), .request(device_request[5]),
        .rsp_valid(device_rsp_valid[5]), .rsp_ready(device_rsp_ready[5]), .response(device_response[5])
    );
    for (genvar u = 0; u < UART_INSTANCES; u++) begin : g_uart
        uart #(.RESET_DIVISOR(UART_DIVISOR)) u_uart (
            .clk, .rst, .rx(uart_rx[u]), .tx(uart_tx[u]), .irq(uart_irq[u]),
            .req_valid(device_req_valid[6+u]), .req_ready(device_req_ready[6+u]), .request(device_request[6+u]),
            .rsp_valid(device_rsp_valid[6+u]), .rsp_ready(device_rsp_ready[6+u]), .response(device_response[6+u])
        );
    end
    for (genvar u = UART_INSTANCES; u < 2; u++) begin : g_absent_uart
        assign uart_tx[u] = 1'b1;
        assign uart_irq[u] = 1'b0;
    end
    if (PRESENT[TARGET_TIMER]) begin
        general_timer u_timer (
            .clk, .rst, .irq(timer_irq),
            .req_valid(device_req_valid[8]), .req_ready(device_req_ready[8]), .request(device_request[8]),
            .rsp_valid(device_rsp_valid[8]), .rsp_ready(device_rsp_ready[8]), .response(device_response[8])
        );
    end else begin
        assign timer_irq = 1'b0;
    end
    for (genvar g = 0; g < GPIO_INSTANCES; g++) begin : g_gpio
        gpio u_gpio (
            .clk, .rst, .gpio_in(gpio_in[g]), .gpio_out(gpio_out[g]), .gpio_oe(gpio_oe[g]),
            .irq(gpio_irq[g]), .req_valid(device_req_valid[9+g]), .req_ready(device_req_ready[9+g]),
            .request(device_request[9+g]), .rsp_valid(device_rsp_valid[9+g]),
            .rsp_ready(device_rsp_ready[9+g]), .response(device_response[9+g])
        );
    end
    for (genvar g = GPIO_INSTANCES; g < 3; g++) begin : g_absent_gpio
        assign gpio_out[g] = '0;
        assign gpio_oe[g] = '0;
        assign gpio_irq[g] = 1'b0;
    end
    dma_controller #(.DDR_BYTES(DDR_BYTES), .WIDE_ENABLE(DMA_WIDE_ENABLE), .BLOCK_ENABLE(DMA_BLOCK_ENABLE)) u_dma (
        .clk, .rst, .req_valid(device_req_valid[12]), .req_ready(device_req_ready[12]),
        .request(device_request[12]), .rsp_valid(device_rsp_valid[12]),
        .rsp_ready(device_rsp_ready[12]), .response(device_response[12]), .irq(dma_irq),
        .master_req_valid(dma_req_valid), .master_req_ready(dma_req_ready),
        .master_request(dma_request), .master_rsp_valid(dma_rsp_valid),
        .master_rsp_ready(dma_rsp_ready), .master_response(dma_response),
        .wide_req_valid(dma_wide_req_valid), .wide_req_ready(dma_wide_req_ready),
        .wide_request(dma_wide_request), .wide_rsp_valid(dma_wide_rsp_valid),
        .wide_rsp_ready(dma_wide_rsp_ready), .wide_response(dma_wide_response),
        .blk_rd_cmd_valid(dma_block_rd_cmd_valid), .blk_rd_cmd_ready(dma_block_rd_cmd_ready),
        .blk_rd_cmd(dma_block_rd_cmd), .blk_rd_valid(dma_block_rd_valid),
        .blk_rd_ready(dma_block_rd_ready), .blk_rd_data(dma_block_rd_data),
        .blk_wr_cmd_valid(dma_block_wr_cmd_valid), .blk_wr_cmd_ready(dma_block_wr_cmd_ready),
        .blk_wr_cmd(dma_block_wr_cmd), .blk_wr_valid(dma_block_wr_valid),
        .blk_wr_ready(dma_block_wr_ready), .blk_wr_data(dma_block_wr_data),
        .blk_wr_rsp_valid(dma_block_wr_rsp_valid), .blk_wr_rsp_ready(dma_block_wr_rsp_ready),
        .blk_wr_rsp(dma_block_wr_rsp)
    );
    soc_info #(.CLOCK_HZ(CLOCK_HZ), .SOC_PROFILE(SOC_PROFILE), .PRESENT(PRESENT),
               .DCACHE_ENABLE(DCACHE_ENABLE && DDR_BYTES != 0),
               .DCACHE_BYTES(DCACHE_BYTES), .DCACHE_LINE_BYTES(DCACHE_LINE_BYTES)) u_info (
        .clk, .rst, .req_valid(device_req_valid[13]), .req_ready(device_req_ready[13]),
        .request(device_request[13]), .rsp_valid(device_rsp_valid[13]),
        .rsp_ready(device_rsp_ready[13]), .response(device_response[13]), .cache_command_valid, .cache_command,
        .cache_command_ready, .cache_busy, .cache_fatal, .cache_error, .cache_fault_addr
    );

`ifndef SYNTHESIS
    initial begin
        assert (SOC_PROFILE == soc_config_pkg::SOC_PROFILE_FULL ||
                SOC_PROFILE == soc_config_pkg::SOC_PROFILE_LITE)
            else $fatal(1, "SOC_PROFILE must be full(0) or lite(1)");
        assert (PRESENT == ((SOC_PROFILE == soc_config_pkg::SOC_PROFILE_LITE ?
                            soc_config_pkg::SOC_LITE_PRESENT : soc_config_pkg::SOC_FULL_PRESENT) |
                           (DDR_BYTES != 0 ? 15'h4000 : 15'h0000)))
            else $fatal(1, "profile and physical device mask disagree");
    end
`endif
endmodule
