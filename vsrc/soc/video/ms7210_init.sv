// Module: ms7210_init
// Description: Bounded-retry MS7210 write/read probe and the board reference's 49-register TX configuration.
// Register table source: $PDS_WORK_ROOT/reference/2_Demo/4_6_hdmi_dyn_ppll/
// 4_6_hdmi_dyn_ppll/source/ms7200xx_ctrl/ms7210_ctl.v (Meyesemi, 2024-11-22).
module ms7210_init #(
    parameter int unsigned PERIPH_HZ = 60000000,
    parameter int unsigned I2C_HZ = 400000,
    parameter int unsigned RESET_CYCLES = PERIPH_HZ/1000,
    parameter int unsigned SETTLE_CYCLES = (PERIPH_HZ/100)*32,
    parameter int unsigned MAX_RETRIES = 3
) (
    input logic clk, rst,
    input logic sda_in,
    output logic scl, sda_drive_low, reset_n,
    output logic done, error,
    output logic [7:0] retries, writes_done
);
    localparam int unsigned WAIT_MAX = RESET_CYCLES > SETTLE_CYCLES ? RESET_CYCLES : SETTLE_CYCLES;
    localparam int unsigned WAIT_W = WAIT_MAX > 0 ? $clog2(WAIT_MAX+1) : 1;
    typedef enum logic [3:0] {
        RESET_HOLD, PROBE_WRITE, PROBE_WRITE_WAIT, PROBE_READ, PROBE_READ_WAIT,
        CONFIG_WRITE, CONFIG_WAIT, SETTLE, COMPLETE, FAILED
    } state_e;
    state_e state_q;
    logic [WAIT_W-1:0] wait_q;
    logic [5:0] index_q;
    logic [7:0] attempt_q;
    logic cmd_valid, cmd_ready, cmd_read, rsp_valid, rsp_ready, rsp_error;
    logic [15:0] cmd_address;
    logic [7:0] cmd_data, rsp_data;
    logic [23:0] command;
    logic cmd_fire, rsp_fire, transaction_failed;

    function automatic logic [23:0] command_at(input logic [5:0] index);
        unique case (index)
            0: command_at = {16'h1281,8'h04};
            1: command_at = {16'h0016,8'h04};
            2: command_at = {16'h0009,8'h01};
            3: command_at = {16'h0007,8'h09};
            4: command_at = {16'h0008,8'hf0};
            5: command_at = {16'h000a,8'hf0};
            6: command_at = {16'h0006,8'h11};
            7: command_at = {16'h0531,8'h84};
            8: command_at = {16'h0900,8'h20};
            9: command_at = {16'h0901,8'h47};
            10: command_at = {16'h0904,8'h09};
            11: command_at = {16'h0923,8'h07};
            12: command_at = {16'h0924,8'h44};
            13: command_at = {16'h0925,8'h44};
            14: command_at = {16'h090f,8'h80};
            15: command_at = {16'h091f,8'h07};
            16: command_at = {16'h0920,8'h1e};
            17: command_at = {16'h0018,8'h20};
            18: command_at = {16'h05c0,8'hfe};
            19: command_at = {16'h000b,8'h00};
            20: command_at = {16'h0507,8'h06};
            21: command_at = {16'h0906,8'h04};
            22: command_at = {16'h0920,8'h5e};
            23: command_at = {16'h0926,8'hdd};
            24: command_at = {16'h0927,8'h0d};
            25: command_at = {16'h0928,8'h88};
            26: command_at = {16'h0929,8'h08};
            27: command_at = {16'h0910,8'h01};
            28: command_at = {16'h000b,8'h11};
            29: command_at = {16'h050e,8'h00};
            30: command_at = {16'h050a,8'h82};
            31: command_at = {16'h0509,8'h02};
            32: command_at = {16'h050b,8'h0d};
            33: command_at = {16'h050d,8'h06};
            34: command_at = {16'h050d,8'h11};
            35: command_at = {16'h050d,8'h58};
            36,37,38,39,40,41,42,43,44,45,46: command_at = {16'h050d,8'h00};
            47: command_at = {16'h050e,8'h40};
            48: command_at = {16'h0507,8'h00};
            default: command_at = '0;
        endcase
    endfunction
    assign command = command_at(index_q);
    assign cmd_valid = state_q == PROBE_WRITE || state_q == PROBE_READ || state_q == CONFIG_WRITE;
    assign cmd_read = state_q == PROBE_READ;
    assign cmd_address = state_q == CONFIG_WRITE ? command[23:8] : 16'h0003;
    assign cmd_data = state_q == CONFIG_WRITE ? command[7:0] : 8'h5a;
    assign rsp_ready = state_q == PROBE_WRITE_WAIT || state_q == PROBE_READ_WAIT || state_q == CONFIG_WAIT;
    assign cmd_fire = cmd_valid && cmd_ready;
    assign rsp_fire = rsp_valid && rsp_ready;
    // 0003写5A后读回用于验证通信；它不表示器件硅ID。
    assign transaction_failed = rsp_error || (state_q == PROBE_READ_WAIT && rsp_data != 8'h5a);
    assign reset_n = state_q != RESET_HOLD;
    assign done = state_q == COMPLETE;
    assign error = state_q == FAILED;
    video_i2c_master #(.PERIPH_HZ(PERIPH_HZ),.I2C_HZ(I2C_HZ)) u_i2c (
        .clk,.rst,.cmd_valid,.cmd_ready,.cmd_read,.cmd_address,.cmd_data,
        .rsp_valid,.rsp_ready,.rsp_data,.rsp_error,.sda_in,.scl,.sda_drive_low
    );

    always_ff @(posedge clk) begin
        if (rst) begin
            state_q <= RESET_HOLD;
            wait_q <= '0;
            index_q <= '0;
            attempt_q <= '0;
            retries <= '0;
            writes_done <= '0;
        end else begin
            if (state_q == RESET_HOLD) begin
                if (RESET_CYCLES == 0 || wait_q == WAIT_W'(RESET_CYCLES-1)) begin
                    wait_q <= '0;
                    state_q <= PROBE_WRITE;
                end else wait_q <= wait_q + 1'b1;
            end else if (state_q == SETTLE) begin
                if (SETTLE_CYCLES == 0 || wait_q == WAIT_W'(SETTLE_CYCLES-1)) begin
                    wait_q <= '0;
                    state_q <= CONFIG_WRITE;
                end else wait_q <= wait_q + 1'b1;
            end else if (cmd_fire) begin
                unique case (state_q)
                    PROBE_WRITE: state_q <= PROBE_WRITE_WAIT;
                    PROBE_READ: state_q <= PROBE_READ_WAIT;
                    default: state_q <= CONFIG_WAIT;
                endcase
            end else if (rsp_fire) begin
                if (transaction_failed) begin
                    // retries记录失败尝试总数；每笔事务最多MAX_RETRIES次总尝试。
                    if (retries != 8'hff) retries <= retries + 1'b1;
                    if (int'(attempt_q) + 1 >= MAX_RETRIES) state_q <= FAILED;
                    else begin
                        attempt_q <= attempt_q + 1'b1;
                        unique case (state_q)
                            PROBE_WRITE_WAIT: state_q <= PROBE_WRITE;
                            PROBE_READ_WAIT: state_q <= PROBE_READ;
                            default: state_q <= CONFIG_WRITE;
                        endcase
                    end
                end else begin
                    attempt_q <= '0;
                    unique case (state_q)
                        PROBE_WRITE_WAIT: state_q <= PROBE_READ;
                        PROBE_READ_WAIT: state_q <= CONFIG_WRITE;
                        default: begin
                            writes_done <= writes_done + 1'b1;
                            if (index_q == 48) state_q <= COMPLETE;
                            else begin
                                index_q <= index_q + 1'b1;
                                if (index_q == 18) begin
                                    wait_q <= '0;
                                    state_q <= SETTLE;
                                end else state_q <= CONFIG_WRITE;
                            end
                        end
                    endcase
                end
            end
        end
    end
`ifndef SYNTHESIS
    initial assert (MAX_RETRIES >= 1 && MAX_RETRIES <= 255)
        else $fatal(1,"MS7210 retry limit must be 1..255 total attempts");
`endif
endmodule
