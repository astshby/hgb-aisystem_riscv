// Module: ex_mdu
// Description: Tracks a single EX request transfer to the independently completing MDU.
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
    // cancel：同步 WB 异常/MRET/FENCE 取消乘除法；排空后的 IRQ 不取消空闲单元
    // mdu_operands_ready：确认实际选中的前递操作数已经就绪
    // advance：EX 指令是否离开；正常 M 不再复制元数据到 MEM
    import core_types_pkg::*;
    logic req_fire;
    logic issued_q;

    // 前递后的操作数只在请求握手时进入 MDU；依赖的较老结果尚未就绪时不启动运算。
    // EX 只等待请求接收；结果由独立完成口交队列，年轻普通 ALU 可继续执行。
    always_comb begin
        // 当前 EX 的有效正常 M 指令才可转交独立运算单元。
        selected = packet_valid && !exception_valid && (uop.fu == FU_MULDIV);
        // 按照上下文赋值
        request = '{operation:uop.muldiv_op, op_width:uop.op_width,
                    operand_a:forwarded_rs1, operand_b:forwarded_rs2};
        req_valid = selected && mdu_operands_ready && !issued_q;
        req_fire = req_valid && req_ready;
        execution_stall = selected && !(issued_q || req_fire);
    end

    // issued_q表示EX阶段是否已经被接收
    // 旧 WB/MEM 阻塞时可提前发射，直到 EX 真正离开才释放，避免 RESULT 已消费后重复请求。
    always_ff @(posedge clk) begin
        if (rst || cancel || advance)
            issued_q <= 1'b0;
        else if (req_fire)
            issued_q <= 1'b1;
    end

endmodule
