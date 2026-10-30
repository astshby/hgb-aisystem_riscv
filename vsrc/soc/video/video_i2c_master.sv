// Module: video_i2c_master
// Description: Open-drain SDA master for MS7210 16-bit register writes and repeated-START byte reads.
module video_i2c_master #(
    parameter int unsigned PERIPH_HZ = 60000000,
    parameter int unsigned I2C_HZ = 400000,
    parameter logic [6:0] DEVICE_ADDRESS = 7'h59
) (
    input logic clk, rst,
    input logic cmd_valid,
    output logic cmd_ready,
    input logic cmd_read,
    input logic [15:0] cmd_address,
    input logic [7:0] cmd_data,
    output logic rsp_valid,
    input logic rsp_ready,
    output logic [7:0] rsp_data,
    output logic rsp_error,
    input logic sda_in,
    output logic scl, sda_drive_low
);
    localparam int unsigned HALF_CYCLES = (PERIPH_HZ + 2*I2C_HZ - 1)/(2*I2C_HZ);
    localparam int unsigned COUNT_W = HALF_CYCLES > 1 ? $clog2(HALF_CYCLES) : 1;
    typedef enum logic [4:0] {
        IDLE, START, TX_LOW, TX_HIGH, ACK_LOW, ACK_HIGH,
        RESTART_LOW, RESTART_HIGH, RESTART_START,
        RX_LOW, RX_HIGH, NACK_LOW, NACK_HIGH,
        STOP_LOW, STOP_HIGH, STOP_RELEASE, RESPONSE
    } state_e;
    state_e state_q;
    logic [COUNT_W-1:0] count_q;
    logic read_q, error_q;
    logic [15:0] address_q;
    logic [7:0] data_q, transmit_q, receive_q;
    logic [2:0] bit_q, byte_q;
    logic sda_meta_q, sda_sync_q;
    logic cmd_fire, rsp_fire, tick;

    assign cmd_ready = state_q == IDLE && !rst;
    assign rsp_valid = state_q == RESPONSE && !rst;
    assign rsp_data = receive_q;
    assign rsp_error = error_q;
    assign cmd_fire = cmd_valid && cmd_ready;
    assign rsp_fire = rsp_valid && rsp_ready;
    assign tick = count_q == COUNT_W'(HALF_CYCLES-1);

    // SCL由本机驱动；SDA只能拉低，外部上拉和从设备共同决定采样值。
    always_comb begin
        scl = 1'b0;
        sda_drive_low = 1'b0;
        unique case (state_q)
            IDLE, RESPONSE, STOP_RELEASE: scl = 1'b1;
            START, RESTART_START, STOP_HIGH: begin
                scl = 1'b1;
                sda_drive_low = 1'b1;
            end
            TX_LOW: sda_drive_low = !transmit_q[bit_q];
            TX_HIGH: begin
                scl = 1'b1;
                sda_drive_low = !transmit_q[bit_q];
            end
            ACK_HIGH, RESTART_HIGH, RX_HIGH, NACK_HIGH: scl = 1'b1;
            STOP_LOW: sda_drive_low = 1'b1;
            default: begin end
        endcase
    end
    always_ff @(posedge clk) begin
        if (rst) begin
            sda_meta_q <= 1'b1;
            sda_sync_q <= 1'b1;
        end else begin
            sda_meta_q <= sda_in;
            sda_sync_q <= sda_meta_q;
        end
    end
    // 每个发送/应答/接收bit有完整低、高半周期，SDA只在SCL低时换位。
    always_ff @(posedge clk) begin
        if (rst) begin
            state_q <= IDLE;
            count_q <= '0;
            read_q <= 1'b0;
            error_q <= 1'b0;
            address_q <= '0;
            data_q <= '0;
            transmit_q <= '0;
            receive_q <= '0;
            bit_q <= 3'd7;
            byte_q <= '0;
        end else begin
            if (state_q == IDLE || state_q == RESPONSE || tick) count_q <= '0;
            else count_q <= count_q + 1'b1;
            if (cmd_fire) begin
                read_q <= cmd_read;
                address_q <= cmd_address;
                data_q <= cmd_data;
                transmit_q <= {DEVICE_ADDRESS,1'b0};
                receive_q <= '0;
                error_q <= 1'b0;
                bit_q <= 3'd7;
                byte_q <= '0;
                state_q <= START;
            end else if (rsp_fire) state_q <= IDLE;
            else if (tick) begin
                unique case (state_q)
                    START, RESTART_START: state_q <= TX_LOW;
                    TX_LOW: state_q <= TX_HIGH;
                    TX_HIGH: begin
                        if (bit_q == 0) state_q <= ACK_LOW;
                        else begin
                            bit_q <= bit_q - 1'b1;
                            state_q <= TX_LOW;
                        end
                    end
                    ACK_LOW: state_q <= ACK_HIGH;
                    ACK_HIGH: begin
                        if (sda_sync_q) begin
                            error_q <= 1'b1;
                            state_q <= STOP_LOW;
                        end else begin
                            bit_q <= 3'd7;
                            unique case (byte_q)
                                0: begin
                                    transmit_q <= address_q[15:8];
                                    byte_q <= 1;
                                    state_q <= TX_LOW;
                                end
                                1: begin
                                    transmit_q <= address_q[7:0];
                                    byte_q <= 2;
                                    state_q <= TX_LOW;
                                end
                                2: begin
                                    byte_q <= 3;
                                    if (read_q) begin
                                        transmit_q <= {DEVICE_ADDRESS,1'b1};
                                        state_q <= RESTART_LOW;
                                    end else begin
                                        transmit_q <= data_q;
                                        state_q <= TX_LOW;
                                    end
                                end
                                default: state_q <= read_q ? RX_LOW : STOP_LOW;
                            endcase
                        end
                    end
                    RESTART_LOW: state_q <= RESTART_HIGH;
                    RESTART_HIGH: state_q <= RESTART_START;
                    RX_LOW: state_q <= RX_HIGH;
                    RX_HIGH: begin
                        receive_q[bit_q] <= sda_sync_q;
                        if (bit_q == 0) state_q <= NACK_LOW;
                        else begin
                            bit_q <= bit_q - 1'b1;
                            state_q <= RX_LOW;
                        end
                    end
                    NACK_LOW: state_q <= NACK_HIGH;
                    NACK_HIGH: state_q <= STOP_LOW;
                    STOP_LOW: state_q <= STOP_HIGH;
                    STOP_HIGH: state_q <= STOP_RELEASE;
                    STOP_RELEASE: state_q <= RESPONSE;
                    default: begin end
                endcase
            end
        end
    end
`ifndef SYNTHESIS
    initial assert (I2C_HZ > 0 && HALF_CYCLES >= 2)
        else $fatal(1,"video I2C clock divisor is too small");
    assert property (@(posedge clk) disable iff (rst)
        rsp_valid && !rsp_ready |=> rsp_valid && $stable({rsp_data,rsp_error}));
`endif
endmodule
