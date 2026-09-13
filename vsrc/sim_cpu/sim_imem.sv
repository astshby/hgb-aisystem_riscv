// Module: sim_imem
// Description: Non-synthesizable one-cycle instruction memory model.
// 指令mem，包含简单的 ready/valid 请求与响应握手
module sim_imem #(
    parameter int unsigned DEPTH_WORDS = 4096
) (
    // req：请求，rsp：响应
    // valid & ready握手才表示成功（接收方valid，发送方ready）
    input  logic                              clk,
    input  logic                              rst,
    input  logic                              req_valid, //req_valid表示发送方有请求
    input  logic [core_config_pkg::XLEN-1:0]  req_addr,
    output logic                              req_ready, // req_ready表示接收方空闲
    output logic                              rsp_valid, // rsp_valid表示前一条指令有请求（时序延迟）
    output logic [31:0]                       rsp_data,  // 指令恒定为32位
    input  logic                              rsp_ready  // rsp_ready表示前一条指令有空闲
);
    logic [31:0] mem [0:DEPTH_WORDS-1];

    // 请求空闲：上一条发完无效/上一条发完有效且接收方空闲
    assign req_ready = !rsp_valid || rsp_ready;

    always_ff @(posedge clk) begin
        if (rst) begin
            rsp_valid <= 1'b0;
        end
        else begin
            // 上一条握手成功，valid清零
            if (rsp_valid && rsp_ready)
                rsp_valid <= 1'b0;
            // 本次握手成功，可以发送，rsp_valid赋值
            if (req_valid && req_ready) begin
                rsp_valid <= 1'b1;
                rsp_data <= mem[req_addr[2 +: $clog2(DEPTH_WORDS)]];
                // 语法解析：req_addr[2 +: $clog2(DEPTH_WORDS)]，表示从req_addr的第2位开始，取$clog2(DEPTH_WORDS)位作为索引，访问mem数组。
                // 4096下，就包含了省去了低两位的地址+映射(req_addr[13：2])
            end
        end
    end
endmodule
