// Module: muldiv_unit
// Description: Sole request/response owner for single-outstanding selectable multiply/divide backends.
// 处理握手响应，组合mul与div块,使用类似总线的状态机（包括特殊情况，暂时保证乘法每次都有一个时延）
module muldiv_unit #(
    parameter int MUL_IMPL = core_config_pkg::MUL_IMPL,
    parameter int DIV_IMPL = core_config_pkg::DIV_IMPL
) (
    input  logic clk, rst, cancel,
    input  logic req_valid,
    output logic req_ready,
    input core_types_pkg::muldiv_req_t request,
    output logic rsp_valid,
    input  logic rsp_ready,
    output core_types_pkg::xlen_t rsp_data,
    output logic busy
);
    import core_types_pkg::*;
    typedef enum logic [1:0] { IDLE, RUN, RESULT } state_e;
    state_e state_q;
    logic divide_request, rsp_fire, req_fire, backend_done, backend_response;
    logic mul_done, div_done, div_special_case;
    logic divide_q;
    xlen_t mul_result, div_result, div_special_result, result_q;

    // 一次只允许一条运算，以除法为标记。
    always_comb begin
        divide_request = (request.operation == MD_DIV) || (request.operation == MD_DIVU) ||
                         (request.operation == MD_REM) || (request.operation == MD_REMU);
        busy = (state_q != IDLE);
        backend_done = divide_q ? div_done : mul_done;
        backend_response = (state_q == RUN) && backend_done;

        req_ready = !rst && !cancel && !busy;
        rsp_valid = !rst && !cancel && (backend_response || (state_q == RESULT));
        req_fire = req_valid && req_ready;
        rsp_fire = rsp_valid && rsp_ready;
        // 完成后直接尝试交付。
        rsp_data = backend_response ? (divide_q ? div_result : mul_result) : result_q;
    end

    mul_unit #(.IMPL(MUL_IMPL)) u_mul_unit (
        .clk, .rst, .cancel, .start(req_fire && !divide_request), .request,
        .done(mul_done), .result(mul_result)
    );
    div_unit #(.IMPL(DIV_IMPL)) u_div_unit (
        .clk, .rst, .cancel, .start(req_fire && divide_request), .request,
        .done(div_done), .result(div_result),
        .special_case(div_special_case), .special_result(div_special_result)
    );

    // 状态机：cancel 优先，除零与有符号溢出仍在请求握手时直接写入 RESULT。
    always_ff @(posedge clk) begin
        if (rst || cancel)
            state_q <= IDLE;
        else begin
            unique case (state_q)
                IDLE: if (req_fire)
                    state_q <= (divide_request && div_special_case) ? RESULT : RUN;
                RUN: if (backend_done) state_q <= rsp_ready ? IDLE : RESULT;
                RESULT: if (rsp_fire) state_q <= IDLE;
                default: state_q <= IDLE;
            endcase
        end
    end
    // 保留寄存器：除法可能需要多拍，每次都有一个时延。
    always_ff @(posedge clk) begin
        if (!rst && !cancel) begin
            if (req_fire)
                divide_q <= divide_request;

            if (req_fire && divide_request && div_special_case)
                result_q <= div_special_result;
            else if (backend_response && !rsp_fire)
                // 直通响应被返回时，才复制到保留寄存器。
                result_q <= divide_q ? div_result : mul_result;
        end
    end

`ifndef SYNTHESIS
    // 仿真确保单条协议
    always_ff @(posedge clk) begin
        if (!rst && !cancel)
            assert (!(req_ready && rsp_valid)) else $fatal(1, "MDU request and response overlap");
    end
`endif
endmodule
