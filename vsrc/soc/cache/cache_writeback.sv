// Module: cache_writeback
// Description: Synchronous-array line reader and serial writeback; stops on the first write error.
module cache_writeback #(
    parameter int LINE_BYTES = 32,
    parameter int WORD_W = $clog2(LINE_BYTES/core_config_pkg::DBUS_BYTES)
) (
    input logic clk, rst, start_valid,
    output logic start_ready,
    input core_types_pkg::xlen_t line_addr,
    output logic read_enable,
    output logic [WORD_W-1:0] read_word,
    input core_types_pkg::xlen_t read_data,
    output logic done_valid,
    input logic done_ready,
    output bus_types_pkg::bus_error_e error,
    output core_types_pkg::xlen_t fault_addr,
    output logic req_valid,
    input logic req_ready,
    output bus_types_pkg::bus_req_t request,
    input logic rsp_valid,
    input bus_types_pkg::bus_rsp_t response
);
    import core_config_pkg::*;
    import core_types_pkg::*;
    import bus_types_pkg::*;
    typedef enum logic [2:0] {IDLE, READ, CAPTURE, SEND, WAIT_RESPONSE, DONE} state_e;
    state_e state_q;
    xlen_t base_q, data_q;
    logic [WORD_W-1:0] word_q;
    assign start_ready = state_q == IDLE;
    assign done_valid = state_q == DONE;
    assign read_enable = state_q == READ;
    assign read_word = word_q;
    assign req_valid = !rst && state_q == SEND;
    always_comb begin
        request = '0;
        request.addr = base_q + (xlen_t'(word_q) << $clog2(DBUS_BYTES));
        request.write = 1'b1;
        request.size = mem_size_e'($clog2(DBUS_BYTES));
        request.wdata = data_q;
        request.wstrb = '1;
    end
    // READ 沿触发同步 RAM；CAPTURE 再锁存数据，SEND 反压时地址与数据都不能改变。
    always_ff @(posedge clk) begin
        if (rst) begin
            state_q <= IDLE;
            base_q <= '0;
            data_q <= '0;
            word_q <= '0;
            error <= BUS_OK;
            fault_addr <= '0;
        end else case (state_q)
            IDLE: if (start_valid) begin
                base_q <= line_addr;
                word_q <= '0;
                error <= BUS_OK;
                fault_addr <= '0;
                state_q <= READ;
            end
            READ: state_q <= CAPTURE;
            CAPTURE: begin data_q <= read_data; state_q <= SEND; end
            SEND: if (req_ready) state_q <= WAIT_RESPONSE;
            WAIT_RESPONSE: if (rsp_valid) begin
                if (response.error != BUS_OK) begin
                    error <= response.error;
                    fault_addr <= request.addr;
                    state_q <= DONE;
                end else if (word_q == WORD_W'(LINE_BYTES/DBUS_BYTES-1)) state_q <= DONE;
                else begin word_q <= word_q + 1'b1; state_q <= READ; end
            end
            DONE: if (done_ready) state_q <= IDLE;
            default: state_q <= IDLE;
        endcase
    end
endmodule
