// Module: ms7210_i2c_model
// Description: Open-drain MS7210 slave checks the reference TX table, repeated START and single-byte read NACK.
module ms7210_i2c_model #(
    parameter string TABLE_FILE = "tb/yolo/ms7210_registers.hex"
) (
    input logic scl, master_drive_low, rst,
    input logic [7:0] nack_budget,
    input logic force_bad_read,
    output logic sda_in,
    output int writes_checked, reads_checked, repeated_starts,
    output logic model_error
);
    timeunit 1ns;
    timeprecision 1ps;
    typedef enum logic [3:0] {IDLE, RECEIVE, ACK_ARM, ACK_CLOCK, ACK_END,
        TRANSMIT, READ_NACK_ARM, READ_NACK, WAIT_STOP} phase_e;
    phase_e phase_q;
    logic [23:0] table_words[49];
    logic slave_low_q, previous_scl, previous_sda;
    logic active_q, acknowledge_q, read_q, pending_write_q, have_address_q, probe_written_q;
    logic [7:0] shift_q, read_value_q, data_q, nacks_q;
    logic [15:0] address_q;
    int bits_q, byte_q, transmit_bit_q;
    logic [7:0] value;
    assign sda_in = !(master_drive_low || slave_low_q);
    initial $readmemh(TABLE_FILE,table_words);

    // 此模型仅根据两根I2C线解码，不窥视被测master/init内部状态。
    always @(scl or sda_in or rst) begin
        // 同一外设时钟边沿可同时改变SCL/SDA；待组合网络稳定后再区分START/STOP。
        #1ps;
        if (rst) begin
            phase_q = IDLE;
            slave_low_q = 0;
            previous_scl = scl;
            previous_sda = 1;
            active_q = 0;
            acknowledge_q = 0;
            read_q = 0;
            pending_write_q = 0;
            have_address_q = 0;
            probe_written_q = 0;
            shift_q = 0;
            read_value_q = 0;
            data_q = 0;
            nacks_q = nack_budget;
            address_q = 0;
            bits_q = 0;
            byte_q = 0;
            transmit_bit_q = 7;
            writes_checked = 0;
            reads_checked = 0;
            repeated_starts = 0;
            model_error = 0;
        end else begin
            if (scl && previous_scl && previous_sda && !sda_in) begin
                if (active_q) begin
                    repeated_starts = repeated_starts + 1;
                    if (!have_address_q || byte_q != 3) model_error = 1;
                end else have_address_q = 0;
                active_q = 1;
                phase_q = RECEIVE;
                bits_q = 0;
                byte_q = 0;
                shift_q = 0;
                pending_write_q = 0;
            end else if (scl && previous_scl && !previous_sda && sda_in) begin
                if (pending_write_q) begin
                    if (address_q == 16'h0003) begin
                        if (data_q != 8'h5a) model_error = 1;
                        probe_written_q = 1;
                    end else begin
                        if (writes_checked >= 49 || {address_q,data_q} != table_words[writes_checked]) model_error = 1;
                        writes_checked = writes_checked + 1;
                    end
                end
                active_q = 0;
                phase_q = IDLE;
                slave_low_q = 0;
                pending_write_q = 0;
            end else if (!previous_scl && scl) begin
                unique case (phase_q)
                    RECEIVE: begin
                        value = {shift_q[6:0],sda_in};
                        shift_q = value;
                        bits_q = bits_q + 1;
                        if (bits_q == 8) begin
                            bits_q = 0;
                            acknowledge_q = 1;
                            if (byte_q == 0) begin
                                if (value != 8'hb2 && value != 8'hb3) begin
                                    model_error = 1;
                                    acknowledge_q = 0;
                                end else if (nacks_q != 0) begin
                                    nacks_q = nacks_q - 1'b1;
                                    acknowledge_q = 0;
                                end
                                read_q = value[0];
                                if (read_q && (!have_address_q || !probe_written_q || address_q != 16'h0003)) model_error = 1;
                            end else if (byte_q == 1) address_q[15:8] = value;
                            else if (byte_q == 2) begin
                                address_q[7:0] = value;
                                have_address_q = 1;
                            end else if (byte_q == 3) begin
                                data_q = value;
                                pending_write_q = 1;
                            end else model_error = 1;
                            byte_q = byte_q + 1;
                            phase_q = ACK_ARM;
                        end
                    end
                    ACK_CLOCK: phase_q = ACK_END;
                    TRANSMIT: begin
                        if (sda_in != read_value_q[transmit_bit_q]) model_error = 1;
                        if (transmit_bit_q == 0) phase_q = READ_NACK_ARM;
                        else transmit_bit_q = transmit_bit_q - 1;
                    end
                    READ_NACK: begin
                        if (!sda_in) model_error = 1;
                        reads_checked = reads_checked + 1;
                        phase_q = WAIT_STOP;
                    end
                    default: begin end
                endcase
            end else if (previous_scl && !scl) begin
                unique case (phase_q)
                    ACK_ARM: begin
                        slave_low_q = acknowledge_q;
                        phase_q = ACK_CLOCK;
                    end
                    ACK_END: begin
                        slave_low_q = 0;
                        if (!acknowledge_q) phase_q = WAIT_STOP;
                        else if (read_q && byte_q == 1) begin
                            read_value_q = force_bad_read ? 8'ha5 : 8'h5a;
                            transmit_bit_q = 7;
                            slave_low_q = !read_value_q[7];
                            phase_q = TRANSMIT;
                        end else if (pending_write_q) phase_q = WAIT_STOP;
                        else phase_q = RECEIVE;
                    end
                    TRANSMIT: slave_low_q = !read_value_q[transmit_bit_q];
                    READ_NACK_ARM: begin
                        slave_low_q = 0;
                        phase_q = READ_NACK;
                    end
                    default: begin end
                endcase
            end
            previous_scl = scl;
            previous_sda = sda_in;
        end
    end
endmodule
