// Module: soc_memory_router
// Description: Owns one transaction across local TCM and registered slow paths, with a held hot response.
module soc_memory_router #(
    parameter bit ENABLE = 1'b0,
    parameter int unsigned DDR_BYTES = 0
) (
    input logic clk, rst,
    input logic s_req_valid,
    output logic s_req_ready,
    input bus_types_pkg::bus_req_t s_request,
    output logic s_rsp_valid,
    input logic s_rsp_ready,
    output bus_types_pkg::bus_rsp_t s_response,
    output logic hot_req_valid,
    input logic hot_req_ready,
    output bus_types_pkg::bus_req_t hot_request,
    output logic hot_bank,
    input logic hot_rsp_valid,
    output logic hot_rsp_ready,
    input bus_types_pkg::bus_rsp_t hot_response,
    output logic slow_req_valid,
    input logic slow_req_ready,
    output bus_types_pkg::bus_req_t slow_request,
    input logic slow_rsp_valid,
    output logic slow_rsp_ready,
    input bus_types_pkg::bus_rsp_t slow_response
);
    import bus_types_pkg::*;

    if (!ENABLE) begin
        // 对照配置不增加状态或拍数；所有请求仍由原事务寄存槽接收。
        assign slow_req_valid = s_req_valid;
        assign slow_request = s_request;
        assign s_req_ready = slow_req_ready;
        assign s_rsp_valid = slow_rsp_valid;
        assign s_response = slow_response;
        assign slow_rsp_ready = s_rsp_ready;
        assign hot_req_valid = 1'b0;
        assign hot_request = '0;
        assign hot_bank = 1'b0;
        assign hot_rsp_ready = 1'b0;
    end else begin
        typedef enum logic [1:0] {IDLE, HOT_WAIT, HOT_REPLY, SLOW_WAIT} state_e;
        state_e state_q;
        bus_rsp_t hot_response_q;
        bus_target_e target;
        bus_error_e access_error;
        logic select_hot, available, s_req_fire, s_rsp_fire, hot_rsp_fire;

        // 首版沿用完整权限/位宽/对齐校验；非法 TCM 访问仍交给慢端错误从机。
        address_decode #(.DDR_BYTES(DDR_BYTES)) u_decode (
            .request(s_request), .target, .error(access_error)
        );
        assign select_hot = access_error == BUS_OK &&
                            (target == TARGET_ITCM || target == TARGET_DTCM);
        assign hot_bank = target == TARGET_DTCM;
        assign available = state_q == IDLE || s_rsp_fire;
        assign s_req_ready = !rst && available && (select_hot ? hot_req_ready : slow_req_ready);
        assign hot_req_valid = !rst && available && s_req_valid && select_hot;
        assign slow_req_valid = !rst && available && s_req_valid && !select_hot;
        assign hot_request = s_request;
        assign slow_request = s_request;
        assign s_req_fire = s_req_valid && s_req_ready;

        // 旧响应只按已接受事务的状态选路，不受当前地址或后继请求影响。
        assign s_rsp_valid = !rst && (state_q == HOT_REPLY ||
                                    (state_q == SLOW_WAIT && slow_rsp_valid));
        assign s_response = state_q == HOT_REPLY ? hot_response_q : slow_response;
        assign s_rsp_fire = s_rsp_valid && s_rsp_ready;
        assign slow_rsp_ready = !rst && state_q == SLOW_WAIT && s_rsp_ready;
        // TCM 返回先进入本主端 FF；IF 输出反压不能经共享 bank 传到 D-ready。
        assign hot_rsp_ready = !rst && state_q == HOT_WAIT;
        assign hot_rsp_fire = hot_rsp_valid && hot_rsp_ready;

        // 两路合计只拥有一笔；释放旧响应与接收新请求同沿时，新归属优先。
        always_ff @(posedge clk) begin
            if (rst)
                state_q <= IDLE;
            else if (s_req_fire)
                state_q <= select_hot ? HOT_WAIT : SLOW_WAIT;
            else if (hot_rsp_fire)
                state_q <= HOT_REPLY;
            else if (s_rsp_fire)
                state_q <= IDLE;
        end
        // 数据与错误共同捕获，不能在反压期间重复采样已变化的 bank 输出。
        always_ff @(posedge clk) begin
            if (rst)
                hot_response_q <= '0;
            else if (hot_rsp_fire)
                hot_response_q <= hot_response;
        end
    end
endmodule
