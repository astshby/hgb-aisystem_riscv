// Module: mmio_bus
// Description: Peripheral-domain register bus; DMA and Flash engines attach through command mailboxes.
module mmio_bus #(
    parameter bit ACCEL_IRQ_ENABLE = 1'b0,
    parameter int unsigned DDR_BYTES = 0,
    parameter int unsigned FLASH_BYTES = 0,
    parameter int unsigned NPU_BYTES = 0,
    parameter int unsigned SOC_PROFILE = soc_config_pkg::SOC_PROFILE_FULL,
    parameter logic [15:0] PRESENT = soc_config_pkg::SOC_FULL_PRESENT | (DDR_BYTES != 0 ? 16'h4000 : 16'h0),
    parameter bit DCACHE_ENABLE = 1,
    parameter int unsigned DCACHE_BYTES = 4096,
    parameter int unsigned DCACHE_LINE_BYTES = 32,
    parameter logic [31:0] CLOCK_HZ = 50000000,
    parameter bit CLOCK_INFO_ENABLE = 1'b0,
    parameter logic [31:0] CORE_CLOCK_HZ = CLOCK_HZ,
    parameter logic [31:0] SYS_CLOCK_HZ = CLOCK_HZ,
    parameter logic [31:0] DDR_CLOCK_HZ = CLOCK_HZ,
    parameter logic [31:0] PERIPH_CLOCK_HZ = CLOCK_HZ,
    parameter logic [31:0] UART_DIVISOR = 434
) (
    input logic clk, rst, ddr_ready,
    input axi_types_pkg::axil_req_t axi_req,
    output axi_types_pkg::axil_rsp_t axi_rsp,
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
    input logic dma_irq,
    input logic [1:0] accelerator_irq = '0,
    output logic flash_req_valid,
    input logic flash_req_ready,
    output bus_types_pkg::bus_req_t flash_request,
    input logic flash_rsp_valid,
    output logic flash_rsp_ready,
    input bus_types_pkg::bus_rsp_t flash_response
);
    import bus_types_pkg::*;
    localparam int unsigned UART_INSTANCES = PRESENT[TARGET_UART1] ? 2 : 1;
    localparam int unsigned GPIO_INSTANCES = PRESENT[TARGET_GPIO2] ? 3 : 1;
    logic [13:4] device_req_valid, device_req_ready, device_rsp_valid, device_rsp_ready;
    bus_req_t device_request [4:13];
    bus_rsp_t device_response [4:13];
    logic timer_irq;
    logic [1:0] uart_irq;
    logic [2:0] gpio_irq;
    logic req_valid, req_ready, rsp_valid, rsp_ready, error_valid, error_ready;
    bus_req_t request;
    bus_rsp_t response, error_response;
    bus_target_e target;
    bus_error_e access_error;
    logic [4:0] selected, owner_q;
    logic status_ready, status_valid, status_error;
    bus_rsp_t status_response;
    logic [31:0] status_data;
    mmio_endpoint u_status (.clk,.rst,.req_valid(req_valid && selected==17),.req_ready(status_ready),
        .request,.rsp_valid(status_valid),.rsp_ready(rsp_ready && owner_q==17),.response(status_response),
        .read_data(status_data),.access_error(status_error),.access_fire(),.write_data(),.write_mask());
    always_comb begin
        status_data=0; status_error=request.write;
        unique case(request.addr[11:0])
            12'h040: status_data=32'h0001000f; // 扩展版本 1，AXI4 / Lite64 / CDC / 单 DMA 主口。
            12'h044: status_data={30'b0,(DDR_BYTES!=0),(DDR_BYTES!=0 && ddr_ready)};
            12'h048: status_data=FLASH_BYTES;
            12'h04c: status_data=NPU_BYTES;
            default: status_error=1;
        endcase
    end
    axil_to_bus u_endpoint (.clk, .rst, .axi_req, .axi_rsp, .req_valid, .req_ready, .request,
                           .rsp_valid, .rsp_ready, .response);
    address_decode #(.DDR_BYTES(DDR_BYTES)) u_decode (.request, .target, .error(access_error));
    bus_error_slave u_error (.clk, .rst, .req_valid(req_valid && selected == 0), .req_ready(error_ready),
        .req_error(BUS_DECERR), .rsp_valid(error_valid), .rsp_ready(rsp_ready && owner_q == 0), .response(error_response));
    always_comb begin
        selected = 0;
        if (request.addr[31:12] == 20'h10050) selected = 16;
        else if (request.addr[31:12] == 20'h10040 && request.addr[11:4] == 8'h04) selected=17;
        else if (access_error == BUS_OK && target >= TARGET_MTIME && target <= TARGET_SOC && PRESENT[target])
            selected = 5'(target);
        req_ready = selected == 17 ? status_ready : selected == 16 ? flash_req_ready : selected == 0 ? error_ready : device_req_ready[selected];
        rsp_valid = owner_q == 17 ? status_valid : owner_q == 16 ? flash_rsp_valid : owner_q == 0 ? error_valid : device_rsp_valid[owner_q];
        response = owner_q == 17 ? status_response : owner_q == 16 ? flash_response : owner_q == 0 ? error_response : device_response[owner_q];
        for (int s = 4; s <= 13; s++) begin
            device_request[s] = request;
            device_req_valid[s] = req_valid && selected == 5'(s);
            device_rsp_ready[s] = rsp_ready && owner_q == 5'(s);
        end
    end
    always_ff @(posedge clk) begin
        if (rst) owner_q <= 0;
        else if (req_valid && req_ready) owner_q <= selected;
    end
    assign dma_req_valid = device_req_valid[12];
    assign device_req_ready[12] = dma_req_ready;
    assign dma_request = device_request[12];
    assign device_rsp_valid[12] = dma_rsp_valid;
    assign dma_rsp_ready = device_rsp_ready[12];
    assign device_response[12] = dma_response;
    assign flash_req_valid = req_valid && selected == 16;
    assign flash_request = request;
    assign flash_rsp_ready = rsp_ready && owner_q == 16;
    for (genvar s = 4; s <= 13; s++) begin : g_absent
        if (!PRESENT[s] && s != 12) begin : g_tie
            assign device_req_ready[s] = 0;
            assign device_rsp_valid[s] = 0;
            assign device_response[s] = '0;
        end
    end
    machine_timer u_mtime (
        .clk, .rst, .req_valid(device_req_valid[4]), .req_ready(device_req_ready[4]),
        .request(device_request[4]), .rsp_valid(device_rsp_valid[4]), .rsp_ready(device_rsp_ready[4]),
        .response(device_response[4]), .irq_software, .irq_timer
    );
    localparam int IRQ_SOURCES = ACCEL_IRQ_ENABLE ? 9 : 7;
    logic [IRQ_SOURCES-1:0] interrupt_sources;
    assign interrupt_sources = ACCEL_IRQ_ENABLE ?
        IRQ_SOURCES'({accelerator_irq, dma_irq, gpio_irq, timer_irq, uart_irq}) :
        IRQ_SOURCES'({dma_irq, gpio_irq, timer_irq, uart_irq});
    irq_controller #(.SOURCES(IRQ_SOURCES)) u_irq (
        .clk, .rst, .sources(interrupt_sources), .irq(irq_external),
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
    soc_info #(.CLOCK_HZ(CLOCK_HZ), .SOC_PROFILE(SOC_PROFILE), .PRESENT(PRESENT),
               .CLOCK_INFO_ENABLE(CLOCK_INFO_ENABLE), .CORE_CLOCK_HZ(CORE_CLOCK_HZ),
               .SYS_CLOCK_HZ(SYS_CLOCK_HZ), .DDR_CLOCK_HZ(DDR_CLOCK_HZ), .PERIPH_CLOCK_HZ(PERIPH_CLOCK_HZ),
               .DCACHE_ENABLE(DCACHE_ENABLE && DDR_BYTES != 0),
               .DCACHE_BYTES(DCACHE_BYTES), .DCACHE_LINE_BYTES(DCACHE_LINE_BYTES)) u_info (
        .clk, .rst, .req_valid(device_req_valid[13]), .req_ready(device_req_ready[13]),
        .request(device_request[13]), .rsp_valid(device_rsp_valid[13]),
        .rsp_ready(device_rsp_ready[13]), .response(device_response[13]), .cache_command_valid, .cache_command,
        .cache_command_ready, .cache_busy, .cache_fatal, .cache_error, .cache_fault_addr
    );

endmodule
