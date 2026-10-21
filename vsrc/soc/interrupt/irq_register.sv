// Module: irq_register
// Description: Samples same-clock device interrupt levels before the CPU interrupt boundary.
module irq_register (
    input logic clk, rst,
    input logic [2:0] device_pending,
    output logic [2:0] core_pending
);
    // 同域电平寄存，不是跨时钟同步器；置位和清除均晚一拍送到 Core。
    // 外部异步引脚仍由设备自己的同步器处理，软件须允许清源后短暂残留的 pending。
    always_ff @(posedge clk) begin
        if (rst)
            core_pending <= '0;
        else
            core_pending <= device_pending;
    end
endmodule
