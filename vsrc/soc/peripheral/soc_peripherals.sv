// Module: soc_peripherals
// Description: Portable MMIO endpoints and single-hart interrupt aggregation.
module soc_peripherals #(
    parameter int unsigned DDR_BYTES = 0,
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
    input logic [13:4] s_req_valid,
    output logic [13:4] s_req_ready,
    input bus_types_pkg::bus_req_t s_request [4:13],
    output logic [13:4] s_rsp_valid,
    input logic [13:4] s_rsp_ready,
    output bus_types_pkg::bus_rsp_t s_response [4:13]
);
    logic timer_irq;
    logic [1:0] uart_irq;
    logic [2:0] gpio_irq;
    logic dma_irq;
    machine_timer u_mtime (
        .clk, .rst, .req_valid(s_req_valid[4]), .req_ready(s_req_ready[4]),
        .request(s_request[4]), .rsp_valid(s_rsp_valid[4]), .rsp_ready(s_rsp_ready[4]),
        .response(s_response[4]), .irq_software, .irq_timer
    );
    irq_controller u_irq (
        .clk, .rst, .sources({dma_irq, gpio_irq, timer_irq, uart_irq}), .irq(irq_external),
        .req_valid(s_req_valid[5]), .req_ready(s_req_ready[5]), .request(s_request[5]),
        .rsp_valid(s_rsp_valid[5]), .rsp_ready(s_rsp_ready[5]), .response(s_response[5])
    );
    for (genvar u = 0; u < 2; u++) begin : g_uart
        uart #(.RESET_DIVISOR(UART_DIVISOR)) u_uart (
            .clk, .rst, .rx(uart_rx[u]), .tx(uart_tx[u]), .irq(uart_irq[u]),
            .req_valid(s_req_valid[6+u]), .req_ready(s_req_ready[6+u]), .request(s_request[6+u]),
            .rsp_valid(s_rsp_valid[6+u]), .rsp_ready(s_rsp_ready[6+u]), .response(s_response[6+u])
        );
    end
    general_timer u_timer (
        .clk, .rst, .irq(timer_irq),
        .req_valid(s_req_valid[8]), .req_ready(s_req_ready[8]), .request(s_request[8]),
        .rsp_valid(s_rsp_valid[8]), .rsp_ready(s_rsp_ready[8]), .response(s_response[8])
    );
    for (genvar g = 0; g < 3; g++) begin : g_gpio
        gpio u_gpio (
            .clk, .rst, .gpio_in(gpio_in[g]), .gpio_out(gpio_out[g]), .gpio_oe(gpio_oe[g]),
            .irq(gpio_irq[g]), .req_valid(s_req_valid[9+g]), .req_ready(s_req_ready[9+g]),
            .request(s_request[9+g]), .rsp_valid(s_rsp_valid[9+g]),
            .rsp_ready(s_rsp_ready[9+g]), .response(s_response[9+g])
        );
    end
    dma_controller #(.DDR_BYTES(DDR_BYTES)) u_dma (
        .clk, .rst, .req_valid(s_req_valid[12]), .req_ready(s_req_ready[12]),
        .request(s_request[12]), .rsp_valid(s_rsp_valid[12]),
        .rsp_ready(s_rsp_ready[12]), .response(s_response[12]), .irq(dma_irq),
        .master_req_valid(dma_req_valid), .master_req_ready(dma_req_ready),
        .master_request(dma_request), .master_rsp_valid(dma_rsp_valid),
        .master_rsp_ready(dma_rsp_ready), .master_response(dma_response)
    );
    soc_info #(.CLOCK_HZ(CLOCK_HZ), .DCACHE_ENABLE(DCACHE_ENABLE && DDR_BYTES != 0),
               .DCACHE_BYTES(DCACHE_BYTES), .DCACHE_LINE_BYTES(DCACHE_LINE_BYTES)) u_info (
        .clk, .rst, .req_valid(s_req_valid[13]), .req_ready(s_req_ready[13]),
        .request(s_request[13]), .rsp_valid(s_rsp_valid[13]),
        .rsp_ready(s_rsp_ready[13]), .response(s_response[13]), .cache_command_valid, .cache_command,
        .cache_command_ready, .cache_busy, .cache_fatal, .cache_error, .cache_fault_addr
    );

endmodule
