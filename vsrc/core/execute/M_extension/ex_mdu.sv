// Module: ex_mdu
// Description: Tracks EX request acceptance while registered MDU results are consumed by MEM.
// 乘除法处理的统一入口，通过req与muldiv_unit握手
module ex_mdu (
    input logic clk, rst, cancel, mdu_operands_ready, advance,
    input logic req_ready,
    input logic packet_valid, exception_valid,
    input core_types_pkg::uop_t uop,
    input core_types_pkg::xlen_t forwarded_rs1, forwarded_rs2,
    output logic selected, execution_stall, req_valid,
    output core_types_pkg::muldiv_req_t request
);
    // 控制分工：cancel、mdu_operands_ready、advance。
    // cancel：取消乘除法,wb重定向才需要启动
    // mdu_operands_ready：确认实际选中的前递操作数已经就绪
    // advance：EX 元数据是否进入 MEM；不再表示运算结果被消费
    import core_types_pkg::*;
    logic req_fire;
    logic issued_q;

    // 前递后的操作数只在请求握手时进入 MDU；依赖的较老结果尚未就绪时不启动运算。
    // EX 只等待请求接收；算法未完成时，由携带元数据的 MEM 阻塞年轻指令，结果经过融合直接交给MEM。
    always_comb begin
        // selected在不同阶段（EX，MEM）处理的指令不同
        selected = packet_valid && !exception_valid && (uop.fu == FU_MULDIV);
        // 按照上下文赋值
        request = '{operation:uop.muldiv_op, op_width:uop.op_width,
                    operand_a:forwarded_rs1, operand_b:forwarded_rs2};
        req_valid = selected && mdu_operands_ready && !issued_q;
        req_fire = req_valid && req_ready;
        execution_stall = selected && !(issued_q || req_fire);
    end

    // issued_q表示EX阶段是否已经被接收
    // 由于此处是主动入口，必须有接收确认缓存，被动出口（mem_mdu）没有类似的
    always_ff @(posedge clk) begin
        if (rst || cancel || advance) // 允许前进，意味着rsp已经被消费，EX阶段可以发起新的请求
            issued_q <= 1'b0;
        else if (req_fire)
            issued_q <= 1'b1;
    end

endmodule
