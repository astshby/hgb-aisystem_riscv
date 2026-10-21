// Module: bus_transaction_register
// Description: Registers both directions of a local-bus transaction with one outstanding request.
module bus_transaction_register (
    input logic clk, rst,
    input logic s_req_valid,
    output logic s_req_ready,
    input bus_types_pkg::bus_req_t s_request,
    output logic s_rsp_valid,
    input logic s_rsp_ready,
    output bus_types_pkg::bus_rsp_t s_response,
    output logic m_req_valid,
    input logic m_req_ready,
    output bus_types_pkg::bus_req_t m_request,
    input logic m_rsp_valid,
    output logic m_rsp_ready,
    input bus_types_pkg::bus_rsp_t m_response
);
    import bus_types_pkg::*;
    typedef enum logic [1:0] {IDLE, SEND, WAIT_RESPONSE, REPLY} state_e;
    state_e state_q;
    bus_req_t request_q;
    bus_rsp_t response_q;
    logic s_req_fire, m_req_fire, m_rsp_fire, s_rsp_fire;

    // 请求/响应载荷仍各跨寄存边界，下游 ready/valid 不组合穿透到源端。
    // 源端消费旧响应时可同沿重装请求；反压期间仍由旧事务独占槽位。
    assign s_req_ready = !rst && (state_q == IDLE ||
                                (state_q == REPLY && s_rsp_ready));
    assign m_req_valid = !rst && state_q == SEND;
    assign m_request = request_q;
    assign m_rsp_ready = !rst && state_q == WAIT_RESPONSE;
    assign s_rsp_valid = !rst && state_q == REPLY;
    assign s_response = response_q;
    assign s_req_fire = s_req_valid && s_req_ready;
    assign m_req_fire = m_req_valid && m_req_ready;
    assign m_rsp_fire = m_rsp_valid && m_rsp_ready;
    assign s_rsp_fire = s_rsp_valid && s_rsp_ready;

    // REPLY 同沿释放/重装只省去 IDLE 空拍；新请求仍须到下一周期才能向下游发出。
    always_ff @(posedge clk) begin
        if (rst) begin
            state_q <= IDLE;
        end else begin
            unique case (state_q)
                IDLE:          if (s_req_fire) state_q <= SEND;
                SEND:          if (m_req_fire) state_q <= WAIT_RESPONSE;
                WAIT_RESPONSE: if (m_rsp_fire) state_q <= REPLY;
                REPLY:         if (s_rsp_fire) state_q <= s_req_fire ? SEND : IDLE;
                default:       state_q <= IDLE;
            endcase
        end
    end

    // 接受后载荷归本槽位所有：上游撤回或改地址不能取消已接受的取指/写操作。
    // 响应数据与错误码一起保存；协调复位只清控制状态，不撤销外部已完成的写。
    always_ff @(posedge clk) begin
        if (rst) begin
            request_q <= '0;
            response_q <= '0;
        end else begin
            if (s_req_fire) request_q <= s_request;
            if (m_rsp_fire) response_q <= m_response;
        end
    end
endmodule
