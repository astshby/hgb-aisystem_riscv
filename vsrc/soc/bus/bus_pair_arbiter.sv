// Module: bus_pair_arbiter
// Description: Round-robin scalar bus arbitration with held offers and one response owner.
module bus_pair_arbiter (
    input logic clk, rst,
    input logic [1:0] c_req_valid,
    output logic [1:0] c_req_ready,
    input bus_types_pkg::bus_req_t c_request [2],
    output logic [1:0] c_rsp_valid,
    input logic [1:0] c_rsp_ready,
    output bus_types_pkg::bus_rsp_t c_response [2],
    output logic req_valid,
    input logic req_ready,
    output bus_types_pkg::bus_req_t request,
    input logic rsp_valid,
    output logic rsp_ready,
    input bus_types_pkg::bus_rsp_t response
);
    logic busy_q, locked_q, owner_q, next_q, selected;
    logic req_fire, rsp_fire;
    assign selected = locked_q ? owner_q :
                      (&c_req_valid ? next_q : c_req_valid[1]);
    assign req_valid = !rst && !busy_q && c_req_valid[selected];
    assign request = c_request[selected];
    assign rsp_ready = !rst && busy_q && c_rsp_ready[owner_q];
    assign req_fire = req_valid && req_ready;
    assign rsp_fire = rsp_valid && rsp_ready;
    always_comb begin
        c_req_ready = '0; c_rsp_valid = '0;
        c_response[0] = response; c_response[1] = response;
        if (!rst && !busy_q) c_req_ready[selected] = req_ready;
        if (!rst && busy_q) c_rsp_valid[owner_q] = rsp_valid;
    end
    // 展示后锁定请求；归属直到响应握手才释放，避免下一请求借用旧响应。
    always_ff @(posedge clk) begin
        if (rst) begin
            busy_q <= 0; locked_q <= 0; owner_q <= 0; next_q <= 0;
        end else begin
            if (req_valid && !req_ready) begin locked_q <= 1; owner_q <= selected; end
            if (req_fire) begin busy_q <= 1; locked_q <= 0; owner_q <= selected; end
            else if (rsp_fire) begin busy_q <= 0; next_q <= !owner_q; end
        end
    end
endmodule
