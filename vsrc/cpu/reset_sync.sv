// Module: reset_sync
// Description: Two-flop synchronous release for an active-low board reset.
// 硬件rst_n处理，每次按下按钮后多处理一个周期，防止需要rst没有接收信号
module reset_sync (
    input  logic clk,
    input  logic reset_n,
    output logic rst
);
    logic sync_q;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            sync_q <= 1'b1;
            rst <= 1'b1;
        end else begin
            sync_q <= 1'b0;
            rst <= sync_q;
        end
    end
endmodule
