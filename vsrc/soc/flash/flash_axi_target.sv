// Module: flash_axi_target
// Description: Read-only AXI window backed by actual SPI pin transactions and configuration mailboxes.
module flash_axi_target (
    input logic clk_sys, rst_sys, clk_periph, rst_periph,
    input axi_types_pkg::axi_req_t axi_req,
    output axi_types_pkg::axi_rsp_t axi_rsp,
    input logic reg_req_valid,
    output logic reg_req_ready,
    input bus_types_pkg::bus_req_t reg_request,
    output logic reg_rsp_valid,
    input logic reg_rsp_ready,
    output bus_types_pkg::bus_rsp_t reg_response,
    output logic spi_cs_n, spi_sck, spi_mosi,
    input logic spi_miso
);
    typedef struct packed {logic [7:0] command; logic four; logic [7:0] dummy; logic [15:0] divider;} config_t;
    config_t config_q, config_next, system_config_q, received_config;
    logic access_fire, access_error, config_valid, config_ready, config_available;
    logic ack_valid, ack_ready, config_busy_q, busy;
    logic [31:0] read_data, write_data, write_mask;
    logic req_valid, req_ready, rsp_valid, rsp_ready;
    bus_types_pkg::bus_req_t request;
    bus_types_pkg::bus_rsp_t response;
    logic [4:0] active_reads_q;
    logic ar_fire, rlast_fire;
    assign ar_fire = axi_req.ar_valid && axi_rsp.ar_ready;
    assign rlast_fire = axi_rsp.r_valid && axi_req.r_ready && axi_rsp.r.last;
    always_ff @(posedge clk_sys) begin
        if (rst_sys) active_reads_q <= 0;
        else case ({ar_fire,rlast_fire})
            2'b10: active_reads_q <= active_reads_q+1'b1;
            2'b01: active_reads_q <= active_reads_q-1'b1;
            default: ;
        endcase
    end
    mmio_endpoint u_regs (.clk(clk_periph), .rst(rst_periph), .req_valid(reg_req_valid),
        .req_ready(reg_req_ready), .request(reg_request), .rsp_valid(reg_rsp_valid),
        .rsp_ready(reg_rsp_ready), .response(reg_response), .read_data, .access_error,
        .access_fire, .write_data, .write_mask);
    always_comb begin
        config_next = config_q; read_data = 0;
        access_error = 0;
        unique case (reg_request.addr[11:0])
            12'h000: begin
                read_data = {24'b0,config_q.command};
                if (reg_request.write) config_next.command = (config_q.command & ~write_mask[7:0]) | (write_data[7:0] & write_mask[7:0]);
            end
            12'h004: begin
                read_data = config_q.four ? 4 : 3;
                if (reg_request.write && write_mask[0]) begin
                    config_next.four = write_data[7:0] == 4;
                    access_error = write_data[7:0] != 3 && write_data[7:0] != 4;
                end
            end
            12'h008: begin
                read_data = {24'b0,config_q.dummy};
                if (reg_request.write) config_next.dummy = (config_q.dummy & ~write_mask[7:0]) | (write_data[7:0] & write_mask[7:0]);
            end
            12'h00c: begin
                read_data = {16'b0,config_q.divider};
                if (reg_request.write) config_next.divider = (config_q.divider & ~write_mask[15:0]) | (write_data[15:0] & write_mask[15:0]);
            end
            12'h010: begin read_data = {31'b0,config_busy_q}; access_error = reg_request.write; end
            default: access_error = 1;
        endcase
        if (reg_request.write && (config_busy_q || !config_ready)) access_error = 1;
    end
    assign config_valid = access_fire && reg_request.write;
    always_ff @(posedge clk_periph) begin
        if (rst_periph) begin config_q <= '{8'h03,1'b0,8'd0,16'd2}; config_busy_q <= 0; end
        else begin
            if (config_valid) begin config_q <= config_next; config_busy_q <= 1; end
            if (ack_valid) config_busy_q <= 0;
        end
    end
    logic config_accept;
    assign config_accept = config_available && !busy && active_reads_q == 0 && !ar_fire && ack_ready;
    async_fifo #(.WIDTH($bits(config_t)),.DEPTH(2)) u_config (
        .s_clk(clk_periph),.s_rst(rst_periph),.m_clk(clk_sys),.m_rst(rst_sys),
        .in_valid(config_valid),.in_ready(config_ready),.in_data(config_next),
        .out_valid(config_available),.out_ready(config_accept),.out_data(received_config));
    async_fifo #(.WIDTH(1),.DEPTH(2)) u_ack (
        .s_clk(clk_sys),.s_rst(rst_sys),.m_clk(clk_periph),.m_rst(rst_periph),
        .in_valid(config_accept),.in_ready(ack_ready),.in_data(1'b1),
        .out_valid(ack_valid),.out_ready(1'b1),.out_data());
    always_ff @(posedge clk_sys) begin
        if (rst_sys) system_config_q <= '{8'h03,1'b0,8'd0,16'd2};
        else if (config_accept) system_config_q <= received_config;
    end
    axi_bus_target #(.READ_ONLY(1)) u_target (.clk(clk_sys),.rst(rst_sys),.axi_req,.axi_rsp,
        .req_valid,.req_ready,.request,.rsp_valid,.rsp_ready,.response);
    spi_flash_reader u_reader (.clk(clk_sys),.rst(rst_sys),.req_valid,.req_ready,.request,
        .rsp_valid,.rsp_ready,.response,.busy,.command(system_config_q.command),
        .address_four_bytes(system_config_q.four),.dummy_bits(system_config_q.dummy),
        .divider(system_config_q.divider),.spi_cs_n,.spi_sck,.spi_mosi,.spi_miso);
endmodule
