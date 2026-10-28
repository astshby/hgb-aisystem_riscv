// Module: soc_reset_controller
// Description: Common asynchronous assertion, per-domain synchronous release and same-cycle SYS fanout copies.
module soc_reset_controller #(
    parameter int SYS_COPIES = 1
) (
    input logic reset_async,
    input logic clk_core, clk_sys, clk_ddr, clk_periph,
    output logic rst_core, rst_sys, rst_ddr, rst_periph,
    output logic [SYS_COPIES-1:0] rst_sys_local
);
    wire [3:0] clocks = {clk_periph, clk_ddr, clk_sys, clk_core};
    logic [3:0] resets;
    logic sys_release_d;
    for (genvar d = 0; d < 4; d++) begin : g_domain
        (* ASYNC_REG = "TRUE" *) logic [2:0] release_q;
        always_ff @(posedge clocks[d] or posedge reset_async) begin
            if (reset_async) release_q <= '1;
            else release_q <= {release_q[1:0], 1'b0};
        end
        assign resets[d] = release_q[2];
        if (d == 1) begin : g_sys_release
            assign sys_release_d = release_q[1];
        end
    end
    // 复制已有同步释放的最后一级，所有SYS簇仍在同一拍退出复位。
    // 不从rst_sys再串一级，避免FIFO两侧和fabric所属状态出现新的释放偏移。
    if (SYS_COPIES > 1) begin : g_sys_copies
        (* syn_preserve = 1, syn_allow_retiming = 0 *) logic [SYS_COPIES-1:0] sys_release_q;
        always_ff @(posedge clk_sys or posedge reset_async) begin
            if (reset_async) sys_release_q <= '1;
            else sys_release_q <= {SYS_COPIES{sys_release_d}};
        end
        assign rst_sys_local = sys_release_q;
    end else begin : g_single_sys
        assign rst_sys_local = rst_sys;
    end
    assign {rst_periph, rst_ddr, rst_sys, rst_core} = resets;
endmodule
