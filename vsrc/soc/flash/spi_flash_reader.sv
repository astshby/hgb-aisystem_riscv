// Module: spi_flash_reader
// Description: Mode-0 SPI read transaction with captured command/address/dummy/divider configuration.
module spi_flash_reader (
    input logic clk, rst,
    input logic req_valid,
    output logic req_ready,
    input bus_types_pkg::bus_req_t request,
    output logic rsp_valid,
    input logic rsp_ready,
    output bus_types_pkg::bus_rsp_t response,
    input logic [7:0] command,
    input logic address_four_bytes,
    input logic [7:0] dummy_bits,
    input logic [15:0] divider,
    output logic busy,
    output logic spi_cs_n, spi_sck, spi_mosi,
    input logic spi_miso
);
    import core_config_pkg::*;
    import bus_types_pkg::*;
    typedef enum logic [1:0] {IDLE, HEADER, DATA, FINISH} state_e;
    state_e state_q;
    logic [63:0] header_q, data_q;
    logic [8:0] header_left_q;
    logic [6:0] data_left_q;
    logic [15:0] divider_q, count_q;
    logic [2:0] lane_q;
    logic [2:0] request_size_q;
    logic tick;
    assign busy = state_q != IDLE;
    assign req_ready = !rst && state_q == IDLE && !rsp_valid;
    assign tick = count_q == divider_q-1'b1;
    // SCK 是时钟使能控制的输出寄存器，所有内部状态仍用 clk，不生成内部派生时钟。
    always_ff @(posedge clk) begin
        if (rst) begin
            state_q <= IDLE; spi_cs_n <= 1; spi_sck <= 0; spi_mosi <= 0;
            rsp_valid <= 0; count_q <= 0; divider_q <= 2; lane_q <= 0;
            header_left_q <= 0; data_left_q <= 0;
        end else begin
            if (rsp_valid && rsp_ready) rsp_valid <= 0;
            if (req_valid && req_ready) begin
                if (request.write || request.execute || (!address_four_bytes && request.addr[27:24] != 0) || int'(request.size) > $clog2(DBUS_BYTES)) begin
                    rsp_valid <= 1; response <= '{rdata:'0,error:BUS_SLVERR};
                end else begin
                    state_q <= HEADER; spi_cs_n <= 0; spi_sck <= 0;
                    header_q <= address_four_bytes ? {command,32'(request.addr-32'h30000000),24'b0} :
                                                     {command,24'(request.addr-32'h30000000),32'b0};
                    spi_mosi <= command[7];
                    header_left_q <= 9'd8 + (address_four_bytes ? 9'd32 : 9'd24) + 9'(dummy_bits);
                    data_left_q <= 7'd8 << request.size;
                    divider_q <= divider == 0 ? 16'd1 : divider;
                    count_q <= 0; data_q <= 0; lane_q <= 3'(request.addr & (DBUS_BYTES-1));
                end
            end else if (state_q == HEADER || state_q == DATA) begin
                if (!tick) count_q <= count_q+1'b1;
                else begin
                    count_q <= 0; spi_sck <= !spi_sck;
                    if (!spi_sck) begin
                        if (state_q == DATA) begin
                            // 每字节高位先到；字节按内存地址递增放入低到高 lane。
                            // 商乘回除数再加余数就是原位号，直接索引避免无意义的有符号除余硬件。
                            data_q[int'(data_left_q)-1] <= spi_miso;
                        end
                    end else begin
                        if (state_q == HEADER) begin
                            header_q <= {header_q[62:0],1'b0};
                            spi_mosi <= header_q[62];
                            header_left_q <= header_left_q-1'b1;
                            if (header_left_q == 1) state_q <= DATA;
                        end else begin
                            data_left_q <= data_left_q-1'b1;
                            if (data_left_q == 1) state_q <= FINISH;
                        end
                    end
                end
            end else if (state_q == FINISH) begin
                state_q <= IDLE; spi_cs_n <= 1; spi_sck <= 0; spi_mosi <= 0;
                rsp_valid <= 1;
                response.error <= BUS_OK;
                response.rdata <= '0;
                // 串行第一字节是最低地址；采样计数倒数，交付时恢复字节次序。
                for (int byte_n = 0; byte_n < DBUS_BYTES; byte_n++) begin
                    if (byte_n < (1 << request_size_q))
                        response.rdata[(int'(lane_q)+byte_n)*8 +: 8] <=
                            data_q[((1 << request_size_q)-1-byte_n)*8 +: 8];
                end
            end
        end
    end
    always_ff @(posedge clk) if (req_valid && req_ready) request_size_q <= 3'(request.size);
endmodule
