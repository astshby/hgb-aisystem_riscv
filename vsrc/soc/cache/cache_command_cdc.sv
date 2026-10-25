// Module: cache_command_cdc
// Description: Coherent cache-maintenance command and status crossing with local pending ownership.
module cache_command_cdc (
    input logic clk_core, rst_core, clk_periph, rst_periph,
    input logic command_valid,
    output logic command_ready,
    input cache_pkg::cache_maint_op_e command,
    output logic busy, fatal,
    output cache_pkg::cache_maint_error_e error,
    output core_types_pkg::xlen_t fault_addr,
    output logic core_command_valid,
    input logic core_command_ready,
    output cache_pkg::cache_maint_op_e core_command,
    input logic core_busy, core_fatal,
    input cache_pkg::cache_maint_error_e core_error,
    input core_types_pkg::xlen_t core_fault_addr
);
    typedef struct packed {
        logic complete, busy, fatal;
        cache_pkg::cache_maint_error_e error;
        core_types_pkg::xlen_t addr;
    } status_t;
    status_t status_in, status_out, last_status_q, status_q;
    logic pending_q, core_pending_q, cmd_ready, cmd_valid;
    logic status_valid, status_ready, status_send;
    logic ack_send;
    // ADS 不允许 FIFO logic 输出直接驱动 enum；先落 logic 再显式转换。
    logic [$bits(cache_pkg::cache_maint_op_e)-1:0] command_data;
    assign core_command = cache_pkg::cache_maint_op_e'(command_data);
    assign command_ready = !rst_periph && !pending_q && cmd_ready;
    async_fifo #(.WIDTH($bits(cache_pkg::cache_maint_op_e)), .DEPTH(2)) u_command (
        .s_clk(clk_periph),.s_rst(rst_periph),.m_clk(clk_core),.m_rst(rst_core),
        .in_valid(command_valid && command_ready),.in_ready(cmd_ready),.in_data(command),
        .out_valid(cmd_valid),.out_ready(core_command_ready && !core_pending_q),.out_data(command_data));
    assign core_command_valid = cmd_valid && !core_pending_q;
    assign ack_send = core_pending_q && !core_busy;
    assign status_in = '{complete:ack_send,busy:core_busy,fatal:core_fatal,error:core_error,addr:core_fault_addr};
    assign status_send = ack_send || status_in != last_status_q;
    async_fifo #(.WIDTH($bits(status_t)),.DEPTH(2)) u_status (
        .s_clk(clk_core),.s_rst(rst_core),.m_clk(clk_periph),.m_rst(rst_periph),
        .in_valid(status_send),.in_ready(status_ready),.in_data(status_in),
        .out_valid(status_valid),.out_ready(1'b1),.out_data(status_out));
    always_ff @(posedge clk_core) begin
        if (rst_core) begin core_pending_q <= 0; last_status_q <= '0; end
        else begin
            if (core_command_valid && core_command_ready) core_pending_q <= 1;
            if (ack_send && status_ready) core_pending_q <= 0;
            if (status_send && status_ready) last_status_q <= status_in;
        end
    end
    always_ff @(posedge clk_periph) begin
        if (rst_periph) begin pending_q <= 0; status_q <= '0; end
        else begin
            if (command_valid && command_ready) pending_q <= 1;
            if (status_valid && status_out.complete) pending_q <= 0;
            if (status_valid) status_q <= status_out;
        end
    end
    assign busy = pending_q || status_q.busy;
    assign fatal = status_q.fatal;
    assign error = status_q.error;
    assign fault_addr = status_q.addr;
endmodule
