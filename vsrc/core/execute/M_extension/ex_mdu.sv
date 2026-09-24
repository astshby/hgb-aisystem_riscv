// Module: ex_mdu
// Description: Tracks EX request acceptance while registered MDU results are consumed by MEM.
module ex_mdu (
    input logic clk, rst, cancel, mdu_operands_ready, advance,
    input logic rsp_ready,
    input logic packet_valid, exception_valid,
    input core_types_pkg::uop_t uop,
    input core_types_pkg::xlen_t forwarded_rs1, forwarded_rs2,
    output logic selected, execution_stall, rsp_valid,
    output core_types_pkg::xlen_t result
);
    // 控制分工：cancel、mdu_operands_ready、advance 与 MEM 的 rsp_ready。
    // cancel：取消乘除法,wb重定向才需要启动
    // mdu_operands_ready：确认实际选中的前递操作数已经就绪
    // advance：EX 元数据是否进入 MEM；不再表示运算结果被消费
    // rsp_ready：MEM 可向 WB 交付本条指令时才消费结果
    import core_types_pkg::*;
    muldiv_req_t request;
    logic req_valid, req_ready, req_fire;
    logic issued_q;

    // 前递后的操作数只在请求握手时进入 MDU；依赖的较老结果尚未就绪时不启动运算。
    // EX 只等待请求接收；算法未完成时，由携带元数据的 MEM 阻塞年轻指令。
    always_comb begin
        selected = packet_valid && !exception_valid && (uop.fu == FU_MULDIV);
        // 按照上下文赋值
        request = '{operation:uop.muldiv_op, op_width:uop.op_width,
                    operand_a:forwarded_rs1, operand_b:forwarded_rs2};
        req_valid = selected && mdu_operands_ready && !issued_q;
        req_fire = req_valid && req_ready;
        execution_stall = selected && !(issued_q || req_fire);
    end

    // WB/MEM 反压期间可以先启动；这一位只记录仍留在 EX 的指令是否已发射。
    // 元数据推进后所有权交给 MEM，结果保持仍只由 muldiv_unit 管理。
    always_ff @(posedge clk) begin
        if (rst || cancel || advance)
            issued_q <= 1'b0;
        else if (req_fire)
            issued_q <= 1'b1;
    end

    // req_ready 统一决定后端能否接收，不再在外部重复判断 busy。
    muldiv_unit u_muldiv_unit (
        .clk, .rst, .cancel, .req_valid, .req_ready, .request, .rsp_valid, .busy(),
        .rsp_ready, .rsp_data(result)
    );
endmodule
