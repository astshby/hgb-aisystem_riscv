// Module: sim_dmem
// Description: Non-synthesizable one-cycle byte-write data memory model.
// 数据存储模型支持字节写；读写都具有请求和完成响应，响应必须保持到接收。
module sim_dmem #(
    parameter int unsigned DEPTH_WORDS = 4096
) (
    input  logic                              clk,
    input  logic                              rst,
    input  logic                              req_valid,
    input  logic                              req_write,
    input  logic [core_config_pkg::XLEN-1:0]  req_addr,
    input  logic [core_config_pkg::XLEN-1:0]  req_wdata,
    input  logic [core_config_pkg::DBUS_BYTES-1:0] req_wstrb,  //对于写入dmem的字节进行限制，例如1111就是全写入，传输掩码
    output logic                              req_ready,
    output logic                              rsp_valid,
    output logic [core_config_pkg::XLEN-1:0]  rsp_rdata,
    input  logic                              rsp_ready
);
    import core_config_pkg::*;
    logic [XLEN-1:0] mem [0:DEPTH_WORDS-1]; //非恒定32位
    integer byte_idx; //用于for循环

    assign req_ready = !rsp_valid || rsp_ready;

    always_ff @(posedge clk) begin
        if (rst) begin
            rsp_valid <= 1'b0;
        end
        else begin
            if (rsp_valid && rsp_ready)
                rsp_valid <= 1'b0;

            if (req_valid && req_ready) begin
                // 请求只执行一次；Store 在写入沿后给出完成响应，允许 WB 确认退休。
                rsp_valid <= 1'b1;
                rsp_rdata <= '0;
                if (req_write) begin
                    for (byte_idx = 0; byte_idx < DBUS_BYTES; byte_idx = byte_idx + 1) begin
                        if (req_wstrb[byte_idx])
                            mem[req_addr[$clog2(DBUS_BYTES) +: $clog2(DEPTH_WORDS)]][8*byte_idx +: 8]
                                <= req_wdata[8*byte_idx +: 8]; //按照字节扩展，下面不用是因为位数匹配
                    end
                end
                else begin
                    rsp_rdata <= mem[req_addr[$clog2(DBUS_BYTES) +: $clog2(DEPTH_WORDS)]]; //64/32的地址处理,给出的地址都是相对字节位
                end
            end
        end
    end
endmodule
