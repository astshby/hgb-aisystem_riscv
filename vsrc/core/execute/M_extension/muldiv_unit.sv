// Module: muldiv_unit
// Description: Sole request/response owner with registered results for selectable multiply/divide backends.
// EX 发射一次请求，完成适配器把已寄存结果与 ID 交退休队列；同步架构事件取消年轻运算。
module muldiv_unit #(
    parameter int MUL_IMPL = core_config_pkg::MUL_IMPL,
    parameter int DIV_IMPL = core_config_pkg::DIV_IMPL
) (
    input  logic clk, rst, cancel,
    input  logic req_valid,
    output logic req_ready,
    input core_types_pkg::muldiv_req_t request,
    output logic result_available, // 只表示寄存结果存在，不能据此消费或退休
    output logic rsp_valid,
    input  logic rsp_ready,
    output core_types_pkg::xlen_t rsp_data
);
    import core_types_pkg::*;
    typedef enum logic [1:0] { IDLE, RUN, RESULT } state_e;
    state_e state_q;
    logic divide_request, rsp_fire, req_fire, backend_done, backend_response;
    logic mul_done, div_done, div_special_case;
    logic divide_q;
    xlen_t mul_result, div_result, div_special_result, result_q;

    // 前递只查询已保存的状态，避免复位/取消经响应许可组合穿过 EX 宽算术。
    // 真正交付仍使用 rsp_valid/rsp_ready；取消沿清除状态，并由流水控制作废年轻元数据。
    assign result_available = (state_q == RESULT);

    // 一次只允许一条运算，以除法为标记。
    always_comb begin
        divide_request = (request.operation == MD_DIV) || (request.operation == MD_DIVU) ||
                         (request.operation == MD_REM) || (request.operation == MD_REMU);
        backend_done = divide_q ? div_done : mul_done;
        backend_response = (state_q == RUN) && backend_done;

        req_ready = !rst && !cancel && state_q == IDLE;
        rsp_valid = !rst && !cancel && result_available;
        req_fire = req_valid && req_ready;
        rsp_fire = rsp_valid && rsp_ready;
        // 完成值先经过统一结果寄存，避免后端算术/符号修正同拍穿过 MEM 前递和 EX 分支。
        rsp_data = result_q;
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
                RUN: if (backend_done) state_q <= RESULT;
                RESULT: if (rsp_fire) state_q <= IDLE;
                default: state_q <= IDLE;
            endcase
        end
    end
    // 结果寄存器归统一握手壳所有；普通计算完成后锁存，RESULT 反压期间保持。
    // 特殊除法已在请求沿寄存，不重复增加一个“完成到结果”的等待周期。
    always_ff @(posedge clk) begin
        if (!rst && !cancel) begin
            if (req_fire)
                divide_q <= divide_request;

            if (req_fire && divide_request && div_special_case)
                result_q <= div_special_result;
            else if (backend_response)
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
