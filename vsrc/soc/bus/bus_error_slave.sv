// Module: bus_error_slave
// Description: Returns a registered bus error exactly once for each accepted request.
// 未映射访问也必须结束握手，不能靠永久拉低 ready 使 CPU 挂起。
module bus_error_slave (
    input logic clk, rst,
    input logic req_valid,
    output logic req_ready,
    input bus_types_pkg::bus_error_e req_error,
    output logic rsp_valid,
    input logic rsp_ready,
    output bus_types_pkg::bus_rsp_t response
);
    assign req_ready = !rsp_valid || rsp_ready;

    // 错误载荷与有效位保持到响应接收；允许消费旧响应的同拍接收新请求。
    always_ff @(posedge clk) begin
        if (rst) begin
            rsp_valid <= 1'b0;
            response <= '0;
        end else begin
            if (rsp_valid && rsp_ready)
                rsp_valid <= 1'b0;
            if (req_valid && req_ready) begin
                rsp_valid <= 1'b1;
                response.rdata <= '0;
                response.error <= req_error;
            end
        end
    end
endmodule
