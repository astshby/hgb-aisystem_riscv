// Module: sim_imem
// Description: Non-synthesizable one-cycle instruction memory model.
// 指令mem，包含简单的 ready/valid 请求与响应握手
module sim_imem #(
    parameter int unsigned DEPTH_WORDS = 4096,
    parameter int unsigned DATA_W = core_config_pkg::FETCH_DATA_W
) (
    // req：请求，rsp：响应
    // valid & ready握手才表示成功（接收方valid，发送方ready）
    input  logic                              clk,
    input  logic                              rst,
    input  logic                              req_valid, //req_valid表示发送方有请求
    input  logic [core_config_pkg::XLEN-1:0]  req_addr,
    output logic                              req_ready, // req_ready表示接收方空闲
    output logic                              rsp_valid, // rsp_valid表示前一条指令有请求（时序延迟）
    output logic [DATA_W-1:0]                 rsp_data,  // 每条指令仍是32位，双发射一次取相邻两条
    output logic                              rsp_error,
    output logic                              rsp_error_1,
    input  logic                              rsp_ready  // rsp_ready表示前一条指令有空闲
);
    logic [31:0] mem [0:DEPTH_WORDS-1];
    logic [DATA_W-1:0] read_data;
    logic [1:0] read_error;

    // 完整字节地址检查后才访问数组；不能截取低位把越界取指绕回镜像开头。
    // 相邻高字可以单独越界；它的错误不能污染仍然合法的低字。
    always_comb begin
        read_data = '0;
        read_error = '0;
        for (int lane = 0; lane < DATA_W/32; lane++) begin
            logic [64:0] byte_address;
            byte_address = 65'(req_addr) + 65'(lane * 4);
            read_error[lane] = byte_address[1:0] != 0 ||
                               byte_address + 65'd4 > 65'(DEPTH_WORDS) * 65'd4;
            if (!read_error[lane])
                read_data[lane*32 +: 32] = mem[int'(byte_address >> 2)];
        end
    end

    // 请求空闲：上一条发完无效/上一条发完有效且接收方空闲
    assign req_ready = !rsp_valid || rsp_ready;

    always_ff @(posedge clk) begin
        if (rst) begin
            rsp_valid <= 1'b0;
            rsp_data <= '0;
            rsp_error <= 1'b0;
            rsp_error_1 <= 1'b0;
        end
        else begin
            // 上一条握手成功，valid清零
            if (rsp_valid && rsp_ready)
                rsp_valid <= 1'b0;
            // 本次握手成功，可以发送，rsp_valid赋值
            if (req_valid && req_ready) begin
                rsp_valid <= 1'b1;
                rsp_data <= read_data;
                rsp_error <= read_error[0];
                rsp_error_1 <= read_error[1];
                // 地址右移2位得到32-bit字索引；DATA_W=64时同沿读取下一字，不串行模拟双字端口。
            end
        end
    end
`ifndef SYNTHESIS
    initial assert (DEPTH_WORDS > 0 && (DATA_W == 32 || DATA_W == 64))
        else $fatal(1, "sim_imem requires nonempty storage and 32/64-bit fetch data");
`endif
endmodule
