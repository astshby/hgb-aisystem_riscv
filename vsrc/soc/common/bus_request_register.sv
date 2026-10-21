// Module: bus_request_register
// Description: One-entry registered request boundary without combinational valid, data, or ready bypass.
module bus_request_register (
    input logic clk, rst,
    input logic in_req_valid,
    output logic in_req_ready,
    input bus_types_pkg::bus_req_t in_request,
    output logic out_req_valid,
    input logic out_req_ready,
    output bus_types_pkg::bus_req_t out_request
);
    import bus_types_pkg::*;

    logic valid_q;
    bus_req_t request_q;
    logic in_req_fire, out_req_fire;

    // 上游 ready 只由槽位状态决定，不从 DDR 桥反传组合 ready。
    assign in_req_ready = !rst && !valid_q;
    assign out_req_valid = !rst && valid_q;
    assign out_request = request_q;
    assign in_req_fire = in_req_valid && in_req_ready;
    assign out_req_fire = out_req_valid && out_req_ready;

    // 满槽期间保持地址、控制和写数据；发出后下一拍才能接纳后继请求。
    always_ff @(posedge clk) begin
        if (rst) begin
            valid_q <= 1'b0;
            request_q <= '0;
        end else if (in_req_fire) begin
            valid_q <= 1'b1;
            request_q <= in_request;
        end else if (out_req_fire) begin
            valid_q <= 1'b0;
        end
    end
endmodule
