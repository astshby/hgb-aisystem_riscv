// Module: ex_mdu
// Description: Stateless EX operand packaging and pipeline adaptation for the multi-cycle MDU.
module ex_mdu (
    input logic clk, rst, cancel, mdu_operands_ready, advance,
    input logic packet_valid, exception_valid,
    input core_types_pkg::uop_t uop,
    input core_types_pkg::xlen_t forwarded_rs1, forwarded_rs2,
    output logic selected, execution_stall,
    output core_types_pkg::xlen_t result
);
    // 3个信号：cancel、mdu_operands_ready、advance
    // cancel：取消乘除法,wb重定向才需要启动
    // mdu_operands_ready：确认 MDU 操作数不依赖尚未返回的 Load
    // advance：EX阶段计算完成后，是否允许下一级别接收
    import core_types_pkg::*;
    muldiv_req_t request;
    logic req_valid, req_ready, rsp_valid, rsp_ready, busy;

    // 前递后的操作数只在请求握手时进入 MDU；较老访存等待时不启动运算。
    // 未完成时阻塞 EX，已完成但下游暂停时保留响应，不重新采样旁路线。
    always_comb begin
        selected = packet_valid && !exception_valid && (uop.fu == FU_MULDIV);
        // 按照上下文赋值
        request = '{operation:uop.muldiv_op, op_width:uop.op_width,
                    operand_a:forwarded_rs1, operand_b:forwarded_rs2};
        req_valid = selected && mdu_operands_ready && !busy;
        rsp_ready = selected && advance;
        execution_stall = selected && !rsp_valid;
    end

    // 请求成功后由 MDU 的 busy 撤销 valid。
    muldiv_unit u_muldiv_unit (
        .clk, .rst, .cancel, .req_valid, .req_ready, .request, .rsp_valid, .busy,
        .rsp_ready, .rsp_data(result)
    );
endmodule
